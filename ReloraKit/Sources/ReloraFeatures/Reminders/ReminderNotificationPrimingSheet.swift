import SwiftUI
import ReloraData
import ReloraDesign
import ReloraServices

/// The pre-prompt shown before iOS's own permission dialog — RN shows this
/// bottom sheet ahead of ever calling `requestNotificationPermission`, so the
/// system dialog a user sees is one they were already told is coming.
///
/// Wired to one live call site, same as RN: the add-reminder save action
/// (`AddReminderViewModel`, added in M8b — RN's trigger is
/// `AddReminderScreen.tsx`'s `onSave`). The save suspends behind this sheet
/// when `shouldPrime` answers true and resumes on either button.
public struct ReminderNotificationPrimingSheet: View {
    let onAllow: () -> Void
    let onNotNow: () -> Void

    /// Scaled rather than fixed: a hero glyph that stays 40pt beside 40pt copy
    /// reads as an icon that failed to load.
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 40

    public init(onAllow: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(spacing: ReloraSpacing.lg) {
            Spacer()

            Image(systemName: "bell.badge")
                .font(.system(size: glyphSize))
                .foregroundStyle(ReloraColor.accentText)
                // Ornamental; the heading below says the same thing in words.
                .accessibilityHidden(true)

            VStack(spacing: ReloraSpacing.sm) {
                Text("Stay on top of your reminders")
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)
                    .multilineTextAlignment(.center)
                Text("Relora can notify you when it's time to follow up with someone.")
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: ReloraSpacing.sm) {
                Button("Turn on notifications", action: onAllow)
                    .buttonStyle(.reloraPrimary)
                Button("Not now", action: onNotNow)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .frame(minHeight: 44)
                    // Without this the tap target is the text, not the 44pt row.
                    .contentShape(Rectangle())
            }
        }
        .padding(ReloraSpacing.lg)
        .presentationDetents([.medium])
    }
}

/// Ties the pure decision (`ReminderNotificationPriming`), the OS prompt, and
/// the decline counter together. A call site asks `shouldPrime` before
/// saving a new reminder; if it answers true, present
/// `ReminderNotificationPrimingSheet` and call `respondAllow`/
/// `respondDecline` from its two buttons. The result is never awaited by the
/// save itself — priming (or skipping it) never blocks a reminder from being
/// written, matching RN.
@MainActor
public struct ReminderNotificationPrimingCoordinator {
    let notifications: NotificationEnvironment
    let settings: AppSettingsStore

    public init(notifications: NotificationEnvironment, settings: AppSettingsStore) {
        self.notifications = notifications
        self.settings = settings
    }

    public func shouldPrime(primedThisSession: Bool) async -> Bool {
        let context = ReminderNotificationPrimingContext(
            notificationsEnabled: (try? settings.reminderNotificationsEnabled()) ?? true,
            authorizationStatus: await notifications.center.authorizationStatus(),
            primedThisSession: primedThisSession,
            declineCount: notifications.primingStore.declineCount()
        )
        return ReminderNotificationPriming.decide(context) == .prime
    }

    /// "Turn on notifications": asks the OS. On a grant, resets the decline
    /// counter and runs a reconciliation pass right away — reminders saved
    /// while permission was missing hold `notification_id = NULL`, and RN
    /// repairs them at this exact moment rather than waiting for the next
    /// cold launch. On an OS-dialog deny, deliberately nothing: RN records a
    /// decline only for the pre-prompt's "Not now" — the OS's own `denied`
    /// status already stops every future prompt, so the counter stays
    /// untouched.
    public func respondAllow(userID: String?) async {
        let granted = await notifications.center.requestAuthorization()
        guard granted else { return }
        notifications.primingStore.reset()
        if let userID {
            await notifications.reconciler.rescheduleAll(userID: userID, trigger: .permissionGranted)
        }
    }

    /// "Not now": counts as a decline, same as RN.
    public func respondDecline() {
        notifications.primingStore.recordDecline()
    }
}
