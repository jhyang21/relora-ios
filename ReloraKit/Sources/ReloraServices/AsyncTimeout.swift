import Foundation

/// Thrown by `withTimeout` when `duration` passes before the operation
/// returns.
struct AsyncTimeoutError: Error, Sendable, Equatable {}

/// Runs `operation` and throws `AsyncTimeoutError` if it has not finished
/// within `duration`.
///
/// Same contract as the private helper in `IdentityController`, but it
/// races the operation against the timer through a continuation instead
/// of a task group. A task group waits for every child before it returns,
/// so an operation that ignores cancellation (a StoreKit or RevenueCat
/// call stuck on the network) would hold the caller past the deadline.
/// Here the caller resumes at the deadline and the operation is cancelled
/// and left to finish on its own; its late result is dropped.
///
/// Cancelling the calling task does not cancel `operation`; the deadline
/// still bounds the wait.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let race = TimeoutRace(continuation)
        let work = Task {
            do {
                let value = try await operation()
                race.finish(.success(value))
            } catch {
                race.finish(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            race.finish(.failure(AsyncTimeoutError()))
            work.cancel()
        }
        race.onFinish { timer.cancel() }
    }
}

/// Resumes a continuation exactly once, whichever side of the race
/// finishes first.
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var finishHandler: (@Sendable () -> Void)?
    private var isFinished = false

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, any Error>) {
        let pending: (CheckedContinuation<T, any Error>, (@Sendable () -> Void)?)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            isFinished = true
            defer { finishHandler = nil }
            return (continuation, finishHandler)
        }
        guard let pending else { return }
        pending.0.resume(with: result)
        pending.1?()
    }

    /// Runs `handler` once the race is decided, or at once if it already
    /// is.
    func onFinish(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if isFinished { return true }
            finishHandler = handler
            return false
        }
        if runNow { handler() }
    }
}
