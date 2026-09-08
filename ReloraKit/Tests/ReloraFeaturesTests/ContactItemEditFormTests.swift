import Foundation
import Testing
@testable import ReloraFeatures

@Suite("ContactItemEditForm")
struct ContactItemEditFormTests {
    private let now = Date(timeIntervalSince1970: 1_756_641_600) // 2026-08-31T12:00:00Z

    @Test("Text is required")
    func textRequired() {
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: ""), now: now) == false)
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "   \n "), now: now) == false)
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "Had coffee"), now: now))
    }

    /// A memory records a conversation that already happened. A note dated
    /// next Tuesday would sort above everything real, forever.
    @Test("A date in the future cannot be saved")
    func futureDateRejected() {
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "Had coffee", date: tomorrow), now: now) == false)

        let yesterday = now.addingTimeInterval(-86_400)
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "Had coffee", date: yesterday), now: now))
    }

    @Test("This moment is not the future")
    func nowIsAllowed() {
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "Had coffee", date: now), now: now))
    }

    /// A key thing has no date at all, so there is nothing to reject.
    @Test("No date is always fine")
    func nilDateAccepted() {
        #expect(ContactItemEditForm.canSave(ContactItemDraft(text: "Drinks oat milk", date: nil), now: now))
    }

    @Test("Saving trims the text and leaves the date alone")
    func normalizeTrims() {
        let date = now.addingTimeInterval(-3_600)
        let normalized = ContactItemEditForm.normalize(
            ContactItemDraft(text: "  Had coffee at Ape  ", date: date)
        )

        #expect(normalized.text == "Had coffee at Ape")
        #expect(normalized.date == date)
    }

    @Test("Trimming turns whitespace-only text into nothing savable")
    func normalizeOfBlankIsUnsavable() {
        let normalized = ContactItemEditForm.normalize(ContactItemDraft(text: "   "))
        #expect(normalized.text.isEmpty)
        #expect(ContactItemEditForm.canSave(normalized, now: now) == false)
    }
}
