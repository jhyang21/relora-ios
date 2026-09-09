import Foundation

/// What the app does to an email address before it sends one.
///
/// Two jobs, and deliberately not a third. It trims surrounding whitespace,
/// because a pasted address routinely arrives with a leading space and the
/// server rejects it with a message nobody can act on. It checks the shape,
/// so an obvious typo fails in front of the user instead of after a round
/// trip.
///
/// It does **not** lowercase, strip dots, or drop `+tag` suffixes. The local
/// part of an address is case-sensitive by specification, plus-addressing is
/// how people file their mail, and an app that quietly rewrites a legitimate
/// address creates an account the user cannot sign back in to.
public enum EmailAddress {

    /// The address as it should be sent: the user's own text, minus the
    /// whitespace they did not mean to include.
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A shape check, not a proof of delivery.
    ///
    /// Nothing short of sending mail can tell you an address exists, so this
    /// aims only to catch what a person can see is wrong: a missing `@`, a
    /// domain with no dot, an empty half. It stays permissive on purpose —
    /// rejecting a valid but unusual address is worse than accepting an
    /// invalid one the server will bounce.
    public static func isValid(_ raw: String) -> Bool {
        let value = normalized(raw)

        // 254 is the RFC 5321 ceiling for a full address, 64 for the local
        // part. Anything longer cannot be delivered anywhere.
        guard !value.isEmpty, value.count <= 254 else { return false }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }

        let halves = value.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return false }

        let local = halves[0]
        let domain = halves[1]
        guard !local.isEmpty, local.count <= 64 else { return false }
        guard !domain.isEmpty, !domain.hasPrefix("-"), !domain.hasSuffix("-") else { return false }

        // A domain needs at least one dot and no empty label: `a@b` and
        // `a@b..com` are both unreachable.
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let topLevel = labels.last, topLevel.count >= 2 else { return false }

        return true
    }
}
