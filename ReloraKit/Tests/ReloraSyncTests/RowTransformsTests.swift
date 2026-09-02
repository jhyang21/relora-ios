import Foundation
import GRDB
import Testing
import ReloraCore
@testable import ReloraSync

@Suite struct RowTransformsTests {

    // MARK: - Push: local-only stripping

    @Test func rowForPushStripsAllFourLocalOnlyColumnsRegardlessOfTable() {
        let local: JSONObject = [
            "id": .string("c1"),
            "user_id": .string("u1"),
            "name": .string("Ada"),
            "descriptors": .string("[]"),
            "is_dirty": .number(1),
            "dirty_at": .string("2026-01-01T00:00:00.000Z"),
            "notification_id": .string("n1"),
            "audio_local_uri": .string("file:///x.m4a")
        ]
        let pushed = RowTransforms.rowForPush(table: .contacts, localRow: local)
        #expect(pushed["is_dirty"] == nil)
        #expect(pushed["dirty_at"] == nil)
        #expect(pushed["notification_id"] == nil)
        #expect(pushed["audio_local_uri"] == nil)
        #expect(pushed["name"] == .string("Ada"))
        #expect(pushed["user_id"] == .string("u1"))
    }

    @Test func rowForPushStrippingIsANoOpWhenTheColumnIsAbsent() {
        // key_things carries no notification_id/audio_local_uri at all —
        // deleting an absent key must not throw or otherwise misbehave.
        let local: JSONObject = ["id": .string("k1"), "text": .string("likes tea"), "is_dirty": .number(1)]
        let pushed = RowTransforms.rowForPush(table: .keyThings, localRow: local)
        #expect(pushed == ["id": .string("k1"), "text": .string("likes tea")])
    }

    // MARK: - Push: array column decoding

    @Test func rowForPushDecodesContactsDescriptorsToJSONArray() {
        let local: JSONObject = ["id": .string("c1"), "descriptors": .string(#"["vip","tea"]"#)]
        let pushed = RowTransforms.rowForPush(table: .contacts, localRow: local)
        #expect(pushed["descriptors"] == .array([.string("vip"), .string("tea")]))
    }

    @Test func rowForPushDecodesMemoriesLabelsToJSONArray() {
        let local: JSONObject = ["id": .string("m1"), "labels": .string(#"["follow-up"]"#)]
        let pushed = RowTransforms.rowForPush(table: .memories, localRow: local)
        #expect(pushed["labels"] == .array([.string("follow-up")]))
    }

    @Test func rowForPushLeavesNonArrayColumnsOnKeyThingsAndRemindersUntouched() {
        let keyThing: JSONObject = ["id": .string("k1"), "text": .string("hi"), "source": .string("manual")]
        #expect(RowTransforms.rowForPush(table: .keyThings, localRow: keyThing) == keyThing)

        let reminder: JSONObject = ["id": .string("r1"), "title": .string("call"), "status": .string("scheduled")]
        #expect(RowTransforms.rowForPush(table: .reminders, localRow: reminder) == reminder)
    }

    @Test func rowForPushFallsBackToEmptyArrayOnCorruptTextJSON() {
        let local: JSONObject = ["id": .string("c1"), "descriptors": .string("not json")]
        let pushed = RowTransforms.rowForPush(table: .contacts, localRow: local)
        #expect(pushed["descriptors"] == .array([]))
    }

    @Test func rowForPushTreatsAMissingArrayColumnAsAbsent() {
        let local: JSONObject = ["id": .string("c1")]
        let pushed = RowTransforms.rowForPush(table: .contacts, localRow: local)
        #expect(pushed["descriptors"] == nil)
    }

    // MARK: - Pull: array column re-encoding

    @Test func localColumnsReEncodesServerArrayToTextJSON() {
        let server: JSONObject = ["id": .string("c1"), "descriptors": .array([.string("vip"), .string("tea")])]
        let local = RowTransforms.localColumns(table: .contacts, serverRow: server)
        #expect(local["descriptors"] == .string(#"["vip","tea"]"#))
    }

    @Test func localColumnsHandlesAnEmptyServerArray() {
        let server: JSONObject = ["id": .string("m1"), "labels": .array([])]
        let local = RowTransforms.localColumns(table: .memories, serverRow: server)
        #expect(local["labels"] == .string("[]"))
    }

    @Test func localColumnsLeavesNonArrayColumnsVerbatim() {
        let server: JSONObject = ["id": .string("r1"), "title": .string("call"), "deleted_at": .null]
        #expect(RowTransforms.localColumns(table: .reminders, serverRow: server) == server)
    }

    // MARK: - Pull never clobbers local-only columns

    @Test func localColumnsKeySetNeverContainsALocalOnlyColumn() {
        // A real server row never carries these keys (the server schema has
        // no such columns), so the transform's output — which becomes the
        // pull upsert's column list — can never name them. This is the
        // property that keeps a pull from nulling out an existing local
        // notification_id/audio_local_uri.
        let server: JSONObject = [
            "id": .string("r1"), "title": .string("call"), "status": .string("scheduled"),
            "contact_id": .string("c1"), "user_id": .string("u1"), "remind_at": .string("2026-01-01T00:00:00.000Z"),
            "created_at": .string("2026-01-01T00:00:00.000Z"), "updated_at": .string("2026-01-01T00:00:00.000Z"),
            "memory_id": .null, "deleted_at": .null
        ]
        let local = RowTransforms.localColumns(table: .reminders, serverRow: server)
        #expect(!local.keys.contains("notification_id"))
        #expect(!local.keys.contains("is_dirty"))
        #expect(!local.keys.contains("dirty_at"))
        #expect(!local.keys.contains("audio_local_uri"))
    }

    // MARK: - Round trip

    @Test func pushThenPullRoundTripsAnArrayColumn() {
        let originalLocalText = #"["vip","tea"]"#
        let local: JSONObject = ["id": .string("c1"), "descriptors": .string(originalLocalText)]
        let pushed = RowTransforms.rowForPush(table: .contacts, localRow: local)
        // The pushed shape is exactly what a server row of this contact
        // would look like coming back through a pull.
        let pulledBack = RowTransforms.localColumns(table: .contacts, serverRow: pushed)
        #expect(pulledBack["descriptors"] == .string(originalLocalText))
    }

    @Test func pushThenPullRoundTripsAnEmptyArrayColumn() {
        let local: JSONObject = ["id": .string("m1"), "labels": .string("[]")]
        let pushed = RowTransforms.rowForPush(table: .memories, localRow: local)
        let pulledBack = RowTransforms.localColumns(table: .memories, serverRow: pushed)
        #expect(pulledBack["labels"] == .string("[]"))
    }

    // MARK: - GRDB glue

    @Test func rowAsJSONObjectMapsSQLiteStorageClasses() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (a TEXT, b INTEGER, c REAL, d TEXT)")
            try db.execute(sql: "INSERT INTO t (a, b, c, d) VALUES (?, ?, ?, ?)", arguments: ["hi", 1, 2.5, nil])
        }
        let row = try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM t")! }
        let json = row.asJSONObject()
        #expect(json["a"] == .string("hi"))
        #expect(json["b"] == .number(1))
        #expect(json["c"] == .number(2.5))
        #expect(json["d"] == .null)
    }

    @Test func jsonValueAsSQLiteBindValueMapsBackToPrimitives() {
        #expect(JSONValue.null.asSQLiteBindValue() == nil)
        #expect(JSONValue.string("x").asSQLiteBindValue() as? String == "x")
        #expect(JSONValue.number(3).asSQLiteBindValue() as? Double == 3)
    }
}
