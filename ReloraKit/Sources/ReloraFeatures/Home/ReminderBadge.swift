import Foundation
import ReloraCore

/// The reminders bell in Home's toolbar.
///
/// Ports `classifyReminder`, `countOverdueReminders` and
/// `buildRemindersEntryLabel` from
/// `apps/mobile/src/features/reminders/reminderListModel.ts`. The reminders
/// screen itself is M8; the badge is here because Home has to show it now.
public enum ReminderBadge {
    /// Reminders that are past due and still scheduled.
    ///
    /// An unparseable `remindAt` is **not** counted. A reminder that cannot say
    /// when it is due has no business claiming to be late.
    public static func overdueCount(_ reminders: [Reminder], nowISO: String) -> Int {
        guard let now = ReloraTimestamp.parse(nowISO) else { return 0 }

        return reminders.filter { reminder in
            guard reminder.deletedAt == nil, reminder.status == .scheduled else { return false }
            guard let remindAt = ReloraTimestamp.parse(reminder.remindAt) else { return false }
            return remindAt <= now
        }.count
    }

    /// What the badge shows. Anything past 9 reads "9+" — the exact number
    /// stops being information and starts being a scolding.
    public static func badgeText(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1...9: return String(count)
        default: return "9+"
        }
    }

    /// The VoiceOver label, so the badge is announced rather than seen only.
    public static func accessibilityLabel(_ count: Int) -> String {
        count <= 0 ? "Open reminders" : "Open reminders, \(count) overdue"
    }
}
