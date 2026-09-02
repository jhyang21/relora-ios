import Foundation
import ReloraCore

/// Ports `buildGetStartedCopy` exactly. Picks the closing copy: a user who
/// skipped the sample step has no example, so the "your example is ready"
/// line would be a lie — that branch is gated on the tutorial actually
/// having run.
public struct GetStartedCopy: Equatable, Sendable {
    public let heading: String
    public let body: String
}

public enum GetStartedCopyBuilder {
    public static func build(
        audience: [String],
        exampleContactName: String,
        tutorialCompleted: Bool
    ) -> GetStartedCopy {
        if tutorialCompleted {
            return GetStartedCopy(
                heading: "Your example is ready",
                body: "We saved a \(exampleContactName) example on this device. You still have all \(QuotaPolicy.freeNoteLimit) free voice notes waiting."
            )
        }

        if !audience.isEmpty {
            let named = audience.prefix(2).joined(separator: " & ")
            return GetStartedCopy(
                heading: "Ready to remember your \(named)",
                body: "Enter the app and start capturing voice notes whenever something matters."
            )
        }

        return GetStartedCopy(
            heading: "You're all set",
            body: "Enter the app and record a note whenever something matters. All \(QuotaPolicy.freeNoteLimit) free notes are waiting."
        )
    }
}
