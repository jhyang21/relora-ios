import Foundation

/// Wire-format timestamp helpers matching SQLite's
/// `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')` (apps/mobile/src/db/schema.ts)
/// and JavaScript's `Date.prototype.toISOString()`, which both produce the
/// same shape: `2026-08-31T12:34:56.789Z` — always UTC, always a literal
/// `Z`, and always exactly three fractional-second digits.
///
/// IMPORTANT: this is the sync/handle format. Every timestamp column in the
/// local store, every dirty-at marker, and the sync cursor compare as
/// Strings, not as parsed dates — lexicographic order on this exact format
/// matches chronological order. Never round-trip a stored timestamp through
/// `Date` and back to produce a new wire string; re-deriving it from a
/// `Date` elsewhere (e.g. a different formatter, or truncating sub-ms
/// precision) can silently break that string comparison. Parse only when
/// arithmetic on the instant is required, and always re-emit through
/// `ReloraTimestamp.from` / `.now()`.
public enum ReloraTimestamp {
    // DateFormatter is not documented as safe for concurrent use even when
    // its configuration is never mutated after creation, so every access
    // below is serialized.
    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }()

    /// The current instant as a wire timestamp.
    public static func now() -> String {
        from(Date())
    }

    /// Formats `date` as a wire timestamp, truncated to millisecond
    /// precision.
    public static func from(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    /// Parses a wire timestamp into a `Date`. Returns `nil` for anything
    /// that does not match the exact wire format (wrong fractional-digit
    /// count, missing `Z`, an offset instead of `Z`, and so on).
    public static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}
