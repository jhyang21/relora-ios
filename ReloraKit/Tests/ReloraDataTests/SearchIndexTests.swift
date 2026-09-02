import Testing
@testable import ReloraData
import ReloraCore
import GRDB

/// Serialized because `SearchIndexState.shared` is process-wide singleton
/// state — running these tests concurrently would let one test's induced FTS
/// failure leak into another's assertions. `init()` resets the flag before
/// every test in this suite (Swift Testing gives each `@Test` its own struct
/// instance, so this is the "beforeEach" idiom).
@Suite("ContactSearchIndex", .serialized)
struct SearchIndexTests {
    init() {
        SearchIndexState.shared.resetForTesting()
    }

    private func makeContact(_ database: AppDatabase, name: String = "Ada Lovelace") throws -> Contact {
        let contactRepo = ContactRepository(database: database)
        let contact = Fixtures.makeContact(name: name)
        try contactRepo.upsert(id: contact.id, userID: contact.userID, name: contact.name, createdAt: contact.createdAt)
        return contact
    }

    // MARK: - buildMatchExpression

    @Test("buildMatchExpression turns each whitespace token into a quoted prefix query")
    func buildMatchExpressionTokenizes() {
        let expression = ContactSearchIndex.buildMatchExpression("ada lovelace")
        #expect(expression == "\"ada\"* \"lovelace\"*")
    }

    @Test("buildMatchExpression escapes embedded quotes")
    func buildMatchExpressionEscapesQuotes() {
        let expression = ContactSearchIndex.buildMatchExpression("say \"hi\"")
        // The token `"hi"` has each embedded quote doubled before the whole
        // token is wrapped in its own pair of quotes.
        #expect(expression == "\"say\"* \"\"\"hi\"\"\"*")
    }

    @Test("buildMatchExpression neutralizes FTS5 operator characters like AND/OR/NOT/-/:")
    func buildMatchExpressionNeutralizesOperators() {
        let expression = ContactSearchIndex.buildMatchExpression("NOT ada -lovelace")
        // Every token is quoted, so raw FTS5 syntax characters are inert text
        // inside the quotes rather than parsed as query operators.
        #expect(expression == "\"NOT\"* \"ada\"* \"-lovelace\"*")
    }

    @Test("buildMatchExpression returns nil for input with no searchable tokens")
    func buildMatchExpressionReturnsNilForBlankInput() {
        #expect(ContactSearchIndex.buildMatchExpression("   ") == nil)
        #expect(ContactSearchIndex.buildMatchExpression("") == nil)
    }

    // MARK: - FTS round trip

    @Test("a contact upserted through the repository is findable by name via FTS")
    func upsertMakesContactFindableByName() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Grace Hopper")
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Grace").contains(contact.id))
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Hopper").contains(contact.id))
    }

    @Test("a contact is findable by a key thing's text")
    func upsertMakesContactFindableByKeyThingText() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        try keyThingRepo.upsert(Fixtures.makeKeyThing(contactID: contact.id, text: "Allergic to shellfish"))

        #expect(try ContactSearchIndex.searchContactIDs(database, query: "shellfish").contains(contact.id))
    }

    @Test("a contact is findable by a memory's text")
    func upsertMakesContactFindableByMemoryText() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let memoryRepo = MemoryRepository(database: database)
        try memoryRepo.upsert(Fixtures.makeMemory(contactID: contact.id, text: "Went hiking together in Joshua Tree"))

        #expect(try ContactSearchIndex.searchContactIDs(database, query: "hiking").contains(contact.id))
    }

    @Test("soft-deleting the contact removes it from search results")
    func softDeleteRemovesFromSearchResults() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Findable Person")
        let contactRepo = ContactRepository(database: database)

        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Findable").contains(contact.id))
        try contactRepo.softDelete(contactID: contact.id, userID: contact.userID)
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Findable").contains(contact.id) == false)
    }

    @Test("markNeedsRebuild forces the next search to rebuild the index first")
    func markNeedsRebuildForcesRebuildOnNextSearch() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Rebuild Target")

        // Directly corrupt the FTS row without going through refreshRow, then
        // flag a rebuild — the next search must recover.
        try database.write { db in
            try db.execute(sql: "DELETE FROM contact_search WHERE contact_id = ?", arguments: [contact.id])
        }
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Rebuild").contains(contact.id) == false)

        try ContactSearchIndex.markNeedsRebuild(database)
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Rebuild").contains(contact.id))
    }

    // MARK: - LIKE fallback

    @Test("when the index is disabled, search falls back to LIKE and still finds matches")
    func likeFallbackFindsMatchesWhenIndexDisabled() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Fallback Person")

        SearchIndexState.shared.disable()
        #expect(try ContactSearchIndex.searchContactIDs(database, query: "Fallback").contains(contact.id))
    }

    @Test("a per-call MATCH failure does not disable the index for later calls")
    func perCallMatchFailureDoesNotLatchFlagOff() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Still Usable")

        // Drop the FTS table out from under a single call, forcing the MATCH
        // query to throw. searchContactIDs's own catch block falls back to
        // LIKE without touching SearchIndexState — unlike refreshRow/rebuild/
        // initialize, whose failures do latch the flag off.
        try database.write { db in
            try db.execute(sql: "DROP TABLE contact_search")
        }
        let results = try ContactSearchIndex.searchContactIDs(database, query: "Still")
        #expect(results.contains(contact.id))
        #expect(SearchIndexState.shared.isUsable())
    }

    // MARK: - Snippets

    @Test("matchSnippets extracts a window of roughly 20 chars before and 40 after the match")
    func matchSnippetsExtractsWindow() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        let text = "This is a long fact about how they are allergic to shellfish and also love hiking on weekends."
        try keyThingRepo.upsert(Fixtures.makeKeyThing(contactID: contact.id, text: text))

        let snippets = try database.read { db in
            try ContactSearchIndex.matchSnippets(db, contactIDs: [contact.id], query: "allergic")
        }
        let snippet = try #require(snippets[contact.id])
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("allergic"))
        #expect(snippet.count <= 82) // 80 chars + up to 2 ellipses
    }

    @Test("matchSnippets returns the whole text with no ellipsis when it fits under the max length")
    func matchSnippetsReturnsWholeShortText() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        try keyThingRepo.upsert(Fixtures.makeKeyThing(contactID: contact.id, text: "Short allergic note"))

        let snippets = try database.read { db in
            try ContactSearchIndex.matchSnippets(db, contactIDs: [contact.id], query: "allergic")
        }
        #expect(snippets[contact.id] == "Short allergic note")
    }

    @Test("matchSnippets is omitted for a contact whose match came from name alone")
    func matchSnippetsOmitsNameOnlyMatches() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database, name: "Uniquely Findable")

        let snippets = try database.read { db in
            try ContactSearchIndex.matchSnippets(db, contactIDs: [contact.id], query: "Uniquely")
        }
        #expect(snippets[contact.id] == nil)
    }

    @Test("matchSnippets prefers key_things over memories when both match")
    func matchSnippetsPrefersKeyThingsOverMemories() throws {
        let database = try Fixtures.makeDatabase()
        let contact = try makeContact(database)
        let keyThingRepo = KeyThingRepository(database: database)
        let memoryRepo = MemoryRepository(database: database)
        try keyThingRepo.upsert(Fixtures.makeKeyThing(contactID: contact.id, text: "keyword from key thing"))
        try memoryRepo.upsert(Fixtures.makeMemory(contactID: contact.id, text: "keyword from memory"))

        let snippets = try database.read { db in
            try ContactSearchIndex.matchSnippets(db, contactIDs: [contact.id], query: "keyword")
        }
        #expect(snippets[contact.id]?.contains("key thing") == true)
    }
}
