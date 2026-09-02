import SwiftUI

/// Relora's empty states are `ContentUnavailableView`, not a hand-built stack.
///
/// It is the native idiom, it centers and scales correctly at every Dynamic Type
/// size, and it already reads well to VoiceOver. This enum only supplies the
/// wording and the symbol, so a screen writes one line and every empty state in
/// the app keeps the same voice.
public enum ReloraEmptyState {
    /// A brand-new signed-in user with no contacts yet.
    public static func firstRun(onAddContact: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("No one here yet", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Add the people you want to remember, then record a note after you talk to them.")
        } actions: {
            Button("Add a contact", action: onAddContact)
                .buttonStyle(.reloraPrimary)
                .frame(maxWidth: 280)
        }
    }

    /// Home after sign-out. The user has an account somewhere; this device has
    /// nothing to show, and saying so is kinder than an empty list.
    public static func signedOut(onSignIn: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("Signed out", systemImage: "person.crop.circle")
        } description: {
            Text("Sign in to see your people and notes on this device.")
        } actions: {
            Button("Sign in", action: onSignIn)
                .buttonStyle(.reloraPrimary)
                .frame(maxWidth: 280)
        }
    }

    /// A search that matched nothing. `ContentUnavailableView.search(text:)` is
    /// the system's own, so it matches Mail and Messages word for word.
    public static func noSearchResults(query: String) -> some View {
        ContentUnavailableView.search(text: query)
    }

    /// An empty tab inside a contact — no memories, no key things, no reminders.
    /// Quieter than a screen-level empty state, because the screen around it is
    /// not empty.
    public static func section(_ title: String, message: String) -> some View {
        VStack(spacing: ReloraSpacing.xs) {
            Text(title)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.ink)
            Text(message)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ReloraSpacing.xl)
        .accessibilityElement(children: .combine)
    }
}
