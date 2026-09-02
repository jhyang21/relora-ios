import Foundation
import ReloraCore

/// Hand-rolled relative-time wording, ported 1:1 from
/// `apps/mobile/src/utils/relativeTime.ts`.
///
/// Deliberately not `RelativeDateTimeFormatter`. The RN copy is what every
/// screenshot, test and screen in the product already says, and the system
/// formatter phrases several of these differently ("1 mo. ago", "in 2 wk.").
/// Matching the existing product beats matching the system here — the wording is
/// part of the voice, and the two clients have to agree while both ship.
///
/// Every function takes `now` as a string so callers stay deterministic and
/// tests stay clock-independent, exactly as RN does.
public enum ReloraRelativeTime {
    private static let second: TimeInterval = 1
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * 60 * 60
    private static let week: TimeInterval = 7 * 24 * 60 * 60
    private static let justNowThreshold: TimeInterval = 45

    private static func pluralize(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    private static func describe(_ elapsed: TimeInterval) -> (text: String, days: Int) {
        if elapsed < hour {
            return (pluralize(max(1, Int(elapsed / minute)), "minute"), 0)
        }
        if elapsed < day {
            return (pluralize(Int(elapsed / hour), "hour"), 0)
        }
        let days = Int(elapsed / day)
        if days < 7 {
            return (pluralize(days, "day"), days)
        }
        return (pluralize(Int(elapsed / week), "week"), days)
    }

    /// "just now", "5 minutes ago", "yesterday", "in 3 days", "8 weeks ago".
    /// An unparseable timestamp yields an empty string, as in RN — a subtitle
    /// that cannot be built is omitted, never guessed at.
    public static func relative(_ targetISO: String, now nowISO: String) -> String {
        guard let target = ReloraTimestamp.parse(targetISO),
              let now = ReloraTimestamp.parse(nowISO) else {
            return ""
        }

        let delta = target.timeIntervalSince(now)
        let elapsed = abs(delta)
        if elapsed < justNowThreshold {
            return "just now"
        }

        let isFuture = delta > 0
        let described = describe(elapsed)
        if described.days == 1 {
            return isFuture ? "tomorrow" : "yesterday"
        }
        return isFuture ? "in \(described.text)" : "\(described.text) ago"
    }

    /// Bare elapsed duration, for "No contact in 8 weeks".
    public static func duration(from fromISO: String, to toISO: String) -> String {
        guard let from = ReloraTimestamp.parse(fromISO),
              let to = ReloraTimestamp.parse(toISO) else {
            return ""
        }
        return describe(abs(to.timeIntervalSince(from))).text
    }

    /// A timestamp the way a person would say it: relative inside a week, then
    /// the calendar date, gaining the year once it is not this one. Seconds
    /// never appear.
    ///
    /// The calendar half uses the user's locale and time zone through
    /// `Date.FormatStyle`, where RN hand-assembled "Aug 3 at 4:25 PM" from
    /// `getMonth()`/`getDate()`. That is a deliberate divergence: a hand-rolled
    /// English date is the one piece of RN's formatting that a native app has no
    /// excuse for, and unlike the relative wording it carries no product voice.
    public static func friendlyDateTime(_ targetISO: String, now nowISO: String) -> String {
        guard let target = ReloraTimestamp.parse(targetISO),
              let now = ReloraTimestamp.parse(nowISO) else {
            return ""
        }

        if abs(target.timeIntervalSince(now)) < week {
            return relative(targetISO, now: nowISO)
        }

        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: target) == calendar.component(.year, from: now)

        // A year is omitted by leaving `.year()` off the style, not by asking
        // for an "omitted" year — there is no such symbol.
        var style = Date.FormatStyle()
            .month(.abbreviated)
            .day()
            .hour()
            .minute()
        if !sameYear {
            style = style.year()
        }
        return target.formatted(style)
    }
}
