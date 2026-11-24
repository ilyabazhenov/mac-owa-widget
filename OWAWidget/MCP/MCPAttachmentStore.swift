import Foundation

/// The attachments MCP answers have named, and the bytes of the ones a client is reading.
///
/// `get_mail_attachment` takes only an `attachment_id`: what the file is (its account, name,
/// type, size, whether it is an attached message) comes from the message that named it. Exchange
/// sends a file whole (`GetFileAttachment`), while a client reads it in pieces, so the bytes stay
/// here for a few minutes: the next pieces cost no request. Memory only, bounded by bytes.
@MainActor
final class MCPAttachmentStore {
    struct Entry: Sendable, Equatable {
        /// The Exchange attachment id.
        let id: String
        let accountID: UUID
        let name: String
        let contentType: String
        /// As Exchange lists it; the downloaded file may be a little smaller.
        let size: Int
        let isItemAttachment: Bool
    }

    /// Bytes kept at most: two of the largest files (`OWAClient.mailAttachmentLimit`).
    nonisolated static let byteLimit = 2 * OWAClient.mailAttachmentLimit
    /// How long a file stays after it was last read.
    nonisolated static let lifetime: TimeInterval = 5 * 60
    /// Attachments remembered, as many as the short ids (`MCPMailTools.handleLimit`).
    static let entryLimit = MCPMailTools.handleLimit

    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []
    private var files: [String: (data: Data, used: Date)] = [:]
    /// Least recently read first.
    private var fileOrder: [String] = []
    /// A download several calls wait for: two pieces asked at once fetch the file once.
    private var downloads: [String: Task<Data, any Error>] = [:]
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func remember(_ entry: Entry) {
        if entries[entry.id] == nil {
            entryOrder.append(entry.id)
            if entryOrder.count > Self.entryLimit {
                entries[entryOrder.removeFirst()] = nil
            }
        }
        entries[entry.id] = entry
    }

    func entry(_ id: String) -> Entry? { entries[id] }

    var cachedBytes: Int { files.values.reduce(0) { $0 + $1.data.count } }

    /// The file's bytes: from memory, or from `download` once. A download outlives a call that
    /// gave up waiting for it (the client cancelled): its bytes are then here for the retry.
    func data(for id: String, download: @escaping @MainActor @Sendable () async throws -> Data) async throws -> Data {
        dropExpired()
        if let file = files[id] {
            touch(id, file.data)
            return file.data
        }
        if let running = downloads[id] { return try await running.value }
        let task = Task { @MainActor in try await download() }
        downloads[id] = task
        do {
            let data = try await task.value
            downloads[id] = nil
            if files[id] == nil { keep(id, data) }
            return data
        } catch {
            downloads[id] = nil
            throw error
        }
    }

    private func touch(_ id: String, _ data: Data) {
        files[id] = (data, clock())
        fileOrder.removeAll { $0 == id }
        fileOrder.append(id)
    }

    private func keep(_ id: String, _ data: Data) {
        guard data.count <= Self.byteLimit else { return }
        touch(id, data)
        var total = cachedBytes
        while total > Self.byteLimit, let oldest = fileOrder.first, oldest != id {
            fileOrder.removeFirst()
            total -= files.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    private func dropExpired() {
        let now = clock()
        for (id, file) in files where now.timeIntervalSince(file.used) >= Self.lifetime {
            files[id] = nil
            fileOrder.removeAll { $0 == id }
        }
    }
}
