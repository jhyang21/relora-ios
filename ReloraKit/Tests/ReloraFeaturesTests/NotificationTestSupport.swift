import Foundation
import ReloraServices

/// A `NotificationCenterProviding` conformer with no OS behind it, shared by
/// `NotificationSchedulerTests` and `NotificationReconcilerTests`. An actor
/// rather than a lock-guarded class: every protocol requirement is already
/// `async`, so actor isolation is the plain way to make this `Sendable`
/// without inventing thread-safety `SystemNotificationCenter` gets from
/// `UNUserNotificationCenter` itself.
actor FakeNotificationCenter: NotificationCenterProviding {
    struct ScheduledRequest: Equatable, Sendable {
        var id: String
        var title: String
        var body: String
        var date: Date
        var userInfo: [String: String]
    }

    private(set) var status: NotificationAuthorizationStatus
    private(set) var scheduled: [ScheduledRequest] = []
    private(set) var removedIDCalls: [[String]] = []
    private(set) var requestAuthorizationCallCount = 0
    private var pending: [String]
    var scheduleShouldThrow = false

    init(status: NotificationAuthorizationStatus = .authorized, initialPending: [String] = []) {
        self.status = status
        self.pending = initialPending
    }

    func setStatus(_ status: NotificationAuthorizationStatus) {
        self.status = status
    }

    func setScheduleShouldThrow(_ value: Bool) {
        scheduleShouldThrow = value
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        return status == .authorized || status == .provisional
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        status
    }

    func schedule(id: String, title: String, body: String, date: Date, userInfo: [String: String]) async throws {
        if scheduleShouldThrow {
            throw FakeNotificationCenterError.scheduleFailed
        }
        scheduled.append(ScheduledRequest(id: id, title: title, body: body, date: date, userInfo: userInfo))
        pending.append(id)
    }

    func removePending(ids: [String]) async {
        removedIDCalls.append(ids)
        pending.removeAll { ids.contains($0) }
    }

    func removeAllPending() async {
        pending.removeAll()
    }

    func pendingIdentifiers() async -> [String] {
        pending
    }
}

enum FakeNotificationCenterError: Error, Sendable, Equatable {
    case scheduleFailed
}
