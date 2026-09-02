import Foundation
import Testing
import ReloraCore
@testable import ReloraFeatures

// MARK: - defaultRemindAt

@Suite("AddReminderForm.defaultRemindAt")
struct AddReminderFormDefaultRemindAtTests {
    @Test("Tomorrow at 9:00 AM local time, ported from getDefaultRemindAt")
    func tomorrowAtNine() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31
        components.hour = 14
        components.minute = 30
        let now = Calendar.current.date(from: components)!

        let defaultRemindAt = AddReminderForm.defaultRemindAt(now: now)
        let resolved = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: defaultRemindAt)

        #expect(resolved.year == 2026)
        #expect(resolved.month == 9)
        #expect(resolved.day == 1)
        #expect(resolved.hour == 9)
        #expect(resolved.minute == 0)
        #expect(resolved.second == 0)
    }
}

// MARK: - canSave

@Suite("AddReminderForm.canSave")
struct AddReminderFormCanSaveTests {
    @Test("A non-empty, non-whitespace title can save")
    func nonEmptyTitleCanSave() {
        #expect(AddReminderForm.canSave(title: "Follow up"))
    }

    @Test("An empty or whitespace-only title cannot save")
    func emptyOrWhitespaceCannotSave() {
        #expect(!AddReminderForm.canSave(title: ""))
        #expect(!AddReminderForm.canSave(title: "   "))
    }
}

// MARK: - validate

@Suite("AddReminderForm.validate")
struct AddReminderFormValidateTests {
    private let now = Date(timeIntervalSince1970: 1_756_641_600) // 2026-08-31T12:00:00Z

    @Test("An empty title, after trimming, fails with missingTitle")
    func blankTitleFails() {
        #expect(throws: ReminderDraftError.missingTitle) {
            _ = try AddReminderForm.validate(title: "   ", remindAt: now.addingTimeInterval(3_600), now: now)
        }
    }

    @Test("A remindAt at or before now fails with notInFuture")
    func notInFutureFails() {
        #expect(throws: ReminderDraftError.notInFuture) {
            _ = try AddReminderForm.validate(title: "Follow up", remindAt: now, now: now)
        }
        #expect(throws: ReminderDraftError.notInFuture) {
            _ = try AddReminderForm.validate(title: "Follow up", remindAt: now.addingTimeInterval(-1), now: now)
        }
    }

    @Test("A valid draft trims the title and stamps the ISO remindAt")
    func validDraftTrimsAndStamps() throws {
        let remindAt = now.addingTimeInterval(3_600)
        let validated = try AddReminderForm.validate(title: "  Follow up  ", remindAt: remindAt, now: now)

        #expect(validated.title == "Follow up")
        #expect(validated.remindAtISO == ReloraTimestamp.from(remindAt))
    }
}
