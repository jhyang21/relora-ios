import Foundation
import Testing
import ReloraCore
import ReloraData
@testable import ReloraFeatures

@Suite("DataExport.buildJSON")
struct DataExportTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    @Test("Produces the four owned tables as top-level keys, scoped to one user")
    func producesFourTablesScopedToUser() throws {
        let database = try makeDatabase()
        let now = ReloraTimestamp.now()

        try ContactRepository(database: database).upsert(id: "contact-mine", userID: "user-1", name: "Ada Lovelace", createdAt: now)
        try ContactRepository(database: database).upsert(id: "contact-theirs", userID: "user-2", name: "Not Mine", createdAt: now)

        try MemoryRepository(database: database).upsert(Memory(
            id: "memory-1",
            contactID: "contact-mine",
            userID: "user-1",
            text: "Caught up over coffee.",
            labels: ["voice"],
            createdAt: now,
            updatedAt: now,
            transcript: "Caught up over coffee.",
            source: .voice
        ))

        try KeyThingRepository(database: database).upsert(KeyThing(
            id: "keything-1",
            contactID: "contact-mine",
            userID: "user-1",
            text: "Prefers email over calls",
            source: .manual,
            createdAt: now,
            updatedAt: now
        ))

        try ReminderRepository(database: database).upsert(Reminder(
            id: "reminder-1",
            contactID: "contact-mine",
            userID: "user-1",
            title: "Follow up",
            remindAt: now,
            status: .scheduled,
            createdAt: now,
            updatedAt: now
        ))

        let json = try DataExport.buildJSON(userID: "user-1", database: database)
        let data = try #require(json.data(using: .utf8))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(payload.keys) == Set(["contacts", "keyThings", "memories", "reminders"]))

        let contacts = try #require(payload["contacts"] as? [[String: Any]])
        #expect(contacts.count == 1)
        #expect(contacts.first?["id"] as? String == "contact-mine")

        let memories = try #require(payload["memories"] as? [[String: Any]])
        #expect(memories.count == 1)
        #expect(memories.first?["id"] as? String == "memory-1")

        let keyThings = try #require(payload["keyThings"] as? [[String: Any]])
        #expect(keyThings.count == 1)

        let reminders = try #require(payload["reminders"] as? [[String: Any]])
        #expect(reminders.count == 1)
    }

    @Test("A user with no data at all gets four empty arrays, not an error")
    func emptyUserGetsEmptyArrays() throws {
        let database = try makeDatabase()
        let json = try DataExport.buildJSON(userID: "nobody-here", database: database)
        let data = try #require(json.data(using: .utf8))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["contacts", "keyThings", "memories", "reminders"] {
            let array = try #require(payload[key] as? [[String: Any]])
            #expect(array.isEmpty)
        }
    }

    @Test("Row values round-trip through the raw SQLite columns — snake_case and all")
    func rowsKeepRawColumnNames() throws {
        let database = try makeDatabase()
        let now = ReloraTimestamp.now()
        try ContactRepository(database: database).upsert(id: "contact-1", userID: "user-1", name: "Ada Lovelace", createdAt: now)

        let json = try DataExport.buildJSON(userID: "user-1", database: database)
        let data = try #require(json.data(using: .utf8))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contacts = try #require(payload["contacts"] as? [[String: Any]])
        let row = try #require(contacts.first)

        #expect(row["user_id"] as? String == "user-1")
        #expect(row["name"] as? String == "Ada Lovelace")
    }
}
