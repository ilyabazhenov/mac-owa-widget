import Foundation

actor SyncScheduler {
    private var task: Task<Void, Never>?

    func start(interval: TimeInterval, work: @Sendable @escaping () async -> Void) {
        stop()
        task = Task {
            // Run immediately on start, then on interval
            await work()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await work()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
