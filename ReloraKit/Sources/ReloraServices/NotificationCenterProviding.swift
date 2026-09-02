import Foundation
import UserNotifications

/// The `UNUserNotificationCenter` surface `NotificationScheduler` and
/// `NotificationReconciler` need, behind a protocol so their tests use a fake
/// instead of the real OS center. This file and `SystemNotificationCenter`
/// are deliberately the only place in ReloraKit that name `UserNotifications`
/// types — the constraint the milestone brief carries forward from
/// `docs/milestone-notes.md`'s sync/notifications boundary: ReloraCore,
/// ReloraData and ReloraSync must never import it, and neither should
/// anything else in ReloraServices or ReloraFeatures.
public protocol NotificationCenterProviding: Sendable {
    /// Prompts the OS permission dialog if authorization is not yet
    /// determined. Never call this speculatively — `NotificationReconciler`
    /// only ever *checks* `authorizationStatus()`; this is reserved for the
    /// priming flow's "yes, ask" step.
    @discardableResult
    func requestAuthorization() async -> Bool

    func authorizationStatus() async -> NotificationAuthorizationStatus

    /// Schedules one notification for `date`, replacing any pending request
    /// already filed under `id`.
    func schedule(id: String, title: String, body: String, date: Date, userInfo: [String: String]) async throws

    func removePending(ids: [String]) async
    func removeAllPending() async

    /// The ids of every notification currently filed with the OS and not yet
    /// delivered. `NotificationReconciler` diffs this against the reminders
    /// that should still hold one, to cancel orphans.
    func pendingIdentifiers() async -> [String]
}

/// Mirrors `UNAuthorizationStatus` without exposing it outside this file —
/// callers elsewhere in the module compare against this instead of importing
/// UserNotifications themselves.
public enum NotificationAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

// MARK: - Production adapter

/// The real `UNUserNotificationCenter`, wrapped to conform to
/// `NotificationCenterProviding`.
///
/// `@unchecked Sendable`: `UNUserNotificationCenter.current()` is documented
/// thread-safe by Apple, but the compiler cannot see that through an
/// `NSObject` subclass — flagged in the M8 report as a first-build check.
public final class SystemNotificationCenter: NSObject, NotificationCenterProviding, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    public override init() {
        super.init()
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .denied:
            return .denied
        case .notDetermined, .ephemeral:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    public func schedule(id: String, title: String, body: String, date: Date, userInfo: [String: String]) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await center.add(request)
    }

    public func removePending(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeAllPending() async {
        center.removeAllPendingNotificationRequests()
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

// MARK: - Notification-tap delegate

/// Turns a tapped reminder notification into a URL, and lets a notification
/// still show while the app is in the foreground.
///
/// The only bridge between `UNUserNotificationCenterDelegate` and
/// `AppRouter` (ReloraFeatures, which must not import UserNotifications):
/// `onTap` is a plain closure, set once in `AppBootstrap`.
public final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let onTap: @Sendable (URL) -> Void

    public init(onTap: @escaping @Sendable (URL) -> Void) {
        self.onTap = onTap
        super.init()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            onTap(url)
        }
        completionHandler()
    }

    /// Matches Expo's default foreground handler (`shouldShowAlert: true`):
    /// a reminder notification still banners even while the app is open.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
