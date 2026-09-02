import Testing
@testable import ReloraCore

@Suite("Domain models")
struct ModelsTests {
    @Test("Contact applies its documented defaults")
    func contactAppliesDefaults() {
        let contact = Contact(
            id: "c1",
            userID: "u1",
            name: "Alex Johnson",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )

        #expect(contact.avatarURL == nil)
        #expect(contact.descriptors == [])
        #expect(contact.phoneNumber == nil)
        #expect(contact.email == nil)
        #expect(contact.isDirty == false)
        #expect(contact.dirtyAt == nil)
        #expect(contact.lastInteractionAt == nil)
        #expect(contact.deletedAt == nil)
    }

    @Test("Contact is Equatable by value")
    func contactEquatable() {
        let base = Contact(id: "c1", userID: "u1", name: "Alex", createdAt: "t", updatedAt: "t")
        let same = Contact(id: "c1", userID: "u1", name: "Alex", createdAt: "t", updatedAt: "t")
        let different = Contact(id: "c2", userID: "u1", name: "Alex", createdAt: "t", updatedAt: "t")

        #expect(base == same)
        #expect(base != different)
    }

    @Test("Memory applies its documented defaults")
    func memoryAppliesDefaults() {
        let memory = Memory(
            id: "m1",
            contactID: "c1",
            userID: "u1",
            text: "Had coffee",
            createdAt: "t",
            updatedAt: "t",
            source: .manual
        )

        #expect(memory.labels == [])
        #expect(memory.isDirty == false)
        #expect(memory.audioURL == nil)
        #expect(memory.audioLocalURI == nil)
        #expect(memory.transcript == nil)
        #expect(memory.deletedAt == nil)
    }

    @Test("KeyThing carries no labels field, unlike Memory")
    func keyThingHasNoLabelsField() {
        // This is a compile-time property of the struct's shape: KeyThing's
        // initializer has no `labels` parameter, matching the real
        // `key_things` table and the shared `KeyThing` contract type, both
        // of which have no labels column. There is nothing to assert at
        // runtime beyond construction succeeding with the actual shape.
        let keyThing = KeyThing(
            id: "k1",
            contactID: "c1",
            userID: "u1",
            text: "Vegetarian",
            source: .voice,
            createdAt: "t",
            updatedAt: "t"
        )

        #expect(keyThing.text == "Vegetarian")
        #expect(keyThing.source == .voice)
    }

    @Test("Reminder carries status and remindAt but no separate completedAt")
    func reminderHasStatusNotCompletedAt() {
        let reminder = Reminder(
            id: "r1",
            contactID: "c1",
            userID: "u1",
            title: "Follow up",
            remindAt: "2026-03-10T10:00:00.000Z",
            status: .scheduled,
            createdAt: "t",
            updatedAt: "t"
        )

        #expect(reminder.status == .scheduled)
        #expect(reminder.memoryID == nil)
        #expect(reminder.notificationID == nil)
    }

    @Test("ReminderStatus raw values match the SQLite CHECK constraint")
    func reminderStatusRawValues() {
        #expect(ReminderStatus.scheduled.rawValue == "scheduled")
        #expect(ReminderStatus.fired.rawValue == "fired")
        #expect(ReminderStatus.dismissed.rawValue == "dismissed")
    }

    @Test("EntrySource raw values match the SQLite CHECK constraint")
    func entrySourceRawValues() {
        #expect(EntrySource.manual.rawValue == "manual")
        #expect(EntrySource.voice.rawValue == "voice")
    }

    @Test("UsageEvent carries no dirty/deleted tracking, matching its append-only table")
    func usageEventHasNoSyncTracking() {
        let event = UsageEvent(
            id: "e1",
            userID: "u1",
            processedAt: "t",
            source: "voice_capture_review"
        )

        #expect(event.serverSyncedAt == nil)
        #expect(event.source == "voice_capture_review")
    }
}
