import Foundation

/// One activation refresh and one cancellable foreground-only timer per app model.
@MainActor
final class ForegroundMailRefresh {
    static let interval: Duration = .seconds(10 * 60)

    private let refresh: @MainActor () async -> Void
    private let sleep: @MainActor (Duration) async throws -> Void
    private var active = false
    private var task: Task<Void, Never>?

    init(refresh: @escaping @MainActor () async -> Void,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.refresh = refresh
        self.sleep = sleep
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        let previous = task
        previous?.cancel()
        // Keep cancelled work until it exits: cancellation may still be awaiting a remote write.
        guard active else { return }
        // Capture callbacks, not self, so destroying the owner cancels rather than retains the timer.
        let refresh = refresh, sleep = sleep
        task = Task {
            // Reactivation must not lose its refresh to the cancelled task's refresh lock.
            await previous?.value
            guard !Task.isCancelled else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await sleep(Self.interval) } catch { return }
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    deinit { task?.cancel() }
}
