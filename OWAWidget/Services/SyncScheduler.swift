import Foundation

actor SyncScheduler {
    private var task: Task<Void, Never>?

    func start(interval: TimeInterval, work: @Sendable @escaping () async -> Void) {
        stop()
        task = Task {
            // CalendarService.rebuildProviders() already performs the initial
            // sync. Running scheduler work immediately after that caused a
            // second OWA request almost back-to-back, which increased the
            // chance of hitting Exchange/OWA transient 500 faults.
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
