import Darwin
import Foundation
import OWAWidgetMCPShared

/// Listening Unix domain socket for MCP bridge connections.
///
/// Plain POSIX on dedicated threads: the traffic is a handful of short lines per minute, and
/// blocking `accept`/`read` keeps the code obvious. Everything above this layer is async.
final class MCPSocketListener: @unchecked Sendable {
    enum ListenerError: Error, LocalizedError {
        case pathTooLong(String)
        case alreadyInUse
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): "Socket path is too long for sockaddr_un: \(path)"
            case .alreadyInUse: "Another copy of OWA Widget is already serving MCP"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    let path: String
    private let onConnection: @Sendable (MCPSocketChannel) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundInode: ino_t = 0

    init(path: String, onConnection: @escaping @Sendable (MCPSocketChannel) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    /// Creates the directory (0700), replaces a stale socket file, binds (0600) and starts accepting.
    func start() throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)

        guard var address = MCPUnixSocket.address(path: path) else {
            throw ListenerError.pathTooLong(path)
        }
        // A file that still answers belongs to a live copy of this build (two copies of the same
        // bundle id): unlinking it would steal its clients, and both watchdogs would then keep
        // taking the socket back from each other. Only a dead file is stale.
        if let probe = MCPUnixSocket.connect(path: path) {
            close(probe)
            throw ListenerError.alreadyInUse
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.system("socket", errno) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ListenerError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ListenerError.system("listen", code)
        }

        var info = stat()
        stat(path, &info)

        lock.lock()
        listenFD = fd
        boundInode = info.st_ino
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "owawidget.mcp.accept"
        thread.start()
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        let inode = boundInode
        listenFD = -1
        boundInode = 0
        lock.unlock()
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        // Only remove the file if it is still ours: a newer listener may already have replaced it.
        var info = stat()
        if stat(path, &info) == 0, info.st_ino == inode {
            unlink(path)
        }
    }

    /// `false` when the socket file was deleted or replaced behind our back (cache cleaners,
    /// a second instance). The caller then restarts the listener.
    var isSocketFileIntact: Bool {
        lock.lock()
        let inode = boundInode
        let running = listenFD >= 0
        lock.unlock()
        guard running else { return false }
        var info = stat()
        return stat(path, &info) == 0 && info.st_ino == inode
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            MCPUnixSocket.disableSigPipe(client)
            onConnection(MCPSocketChannel(fd: client))
        }
    }
}

/// One accepted connection: newline-delimited lines in, lines out.
final class MCPSocketChannel: @unchecked Sendable {
    /// Lines longer than this are a broken or hostile peer; the connection is dropped.
    static let maxLineBytes = 4 * 1024 * 1024

    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Who connected, from the kernel. Read it before the peer has a chance to exit.
    func peerCredentials() -> MCPPeerCredentials? {
        MCPPeerCredentials.read(fd: fd)
    }

    /// Starts the reader thread. Call once.
    func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread { [fd] in
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                reading: while true {
                    let count = read(fd, &chunk, chunk.count)
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<count])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if !line.isEmpty { continuation.yield(line) }
                    }
                    if buffer.count > Self.maxLineBytes { break reading }
                }
                continuation.finish()
            }
            thread.name = "owawidget.mcp.read"
            thread.start()
        }
    }

    func send(_ line: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        MCPUnixSocket.writeAll(fd, line + Data([0x0A]))
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
