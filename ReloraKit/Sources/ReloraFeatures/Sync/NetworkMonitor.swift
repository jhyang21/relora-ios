import Foundation
import Network
import os

/// Whether the device thinks it has a network.
///
/// `SyncEngine` takes an `isOnline` closure and skips a run when it returns
/// false, and Home shows an offline banner from the same signal — so both read
/// this one object rather than each guessing.
///
/// This is a reachability *hint*, not a guarantee. A satisfied path still fails
/// against a captive portal, which is why a failed sync has its own banner and
/// its own retry: "online" here only means "worth attempting".
public final class NetworkMonitor: Sendable {
    // NWPathMonitor is a reference type this class owns exclusively and only
    // ever touches from its own serial queue.
    nonisolated(unsafe) private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.immform.relora.network-monitor")
    private let online = OSAllocatedUnfairLock(initialState: true)

    public init() {}

    public var isOnline: Bool {
        online.withLock { $0 }
    }

    /// - Parameter onChange: Called on every transition, off the main actor.
    ///
    /// The handler belongs to `start` rather than to `init` so a composition
    /// root can build the monitor first — the sync engine reads `isOnline` at
    /// construction — and only then hand it the object it should notify.
    public func start(onChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        monitor.pathUpdateHandler = { [online] path in
            let isOnline = path.status == .satisfied
            let changed = online.withLock { current -> Bool in
                guard current != isOnline else { return false }
                current = isOnline
                return true
            }
            if changed {
                onChange(isOnline)
            }
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
