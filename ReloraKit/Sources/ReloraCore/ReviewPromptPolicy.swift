import Foundation

/// When to ask for an App Store review: once per install, after the third
/// saved voice note. Pure so the rule can be tested without StoreKit; the
/// ask itself happens in `RootView` (ReloraFeatures).
public enum ReviewPromptPolicy {
    public static let threshold = 3

    public static func shouldPrompt(savedNoteCount: Int, alreadyShown: Bool) -> Bool {
        !alreadyShown && savedNoteCount >= threshold
    }
}
