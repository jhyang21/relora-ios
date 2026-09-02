import Foundation

/// Errors this module throws that have no natural GRDB/SQLite representation.
/// Storage-layer failures (constraint violations, I/O errors) surface as
/// whatever `GRDB.DatabaseError` GRDB itself throws — this type only covers
/// checks the repositories perform themselves, ported from the `throw new
/// Error('SOME_CODE')` calls in apps/mobile/src/db/repositories.ts.
public enum ReloraDataError: Error, Equatable, Sendable {
    /// Mirrors `throw new Error('REMINDER_MEMORY_MISMATCH')` in
    /// `upsertReminder` (repositories.ts): thrown when a reminder names a
    /// `memory_id` that does not identify a row under the same
    /// `contact_id`/`user_id`. A tombstoned memory still satisfies the
    /// check — the row only needs to exist, not be live — so completing or
    /// editing a reminder never fails just because its source memory was
    /// later deleted.
    case reminderMemoryMismatch

    /// A row fetched from a CHECK-constrained column (`source`, `status`)
    /// held a value outside its declared domain. Unreachable against a
    /// schema-conformant database; carries the column's dotted path for
    /// diagnostics if it ever fires.
    case invalidRow(String)
}
