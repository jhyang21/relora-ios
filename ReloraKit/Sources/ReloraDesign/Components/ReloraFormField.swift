import SwiftUI
import UIKit

// MARK: - Shared chrome

/// The border a field draws in each of its three states.
///
/// Focus uses `accent` rather than `accentTintBorder`. The tint token is the
/// accent at 20%, which lands at 1.14:1 on a card — right for a selected chip
/// that is already distinguished by other means, and invisible as the only
/// signal that the keyboard is pointed at this field. A focus ring has to be
/// seen, so it takes the solid fill at a wider stroke. The rule the palette
/// sets for `accent` is "never as text"; a 2pt stroke is not text.
private struct ReloraFieldChrome: ViewModifier {
    let fill: Color
    let isFocused: Bool
    let hasError: Bool

    func body(content: Content) -> some View {
        content
            .padding(ReloraSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: ReloraRadius.sm, style: .continuous)
                    .fill(fill)
            )
            .reloraBorder(borderColor, radius: ReloraRadius.sm, width: borderWidth)
            .reloraAnimation(.quick, value: isFocused)
    }

    private var borderColor: Color {
        if hasError { return ReloraColor.danger }
        return isFocused ? ReloraColor.accent : ReloraColor.hairline
    }

    private var borderWidth: CGFloat {
        hasError || isFocused ? 2 : 1
    }
}

// MARK: - Label

/// The field label. Hidden from VoiceOver because the field itself carries the
/// same string as its accessibility label — announcing it twice is noise.
private struct ReloraFieldLabel: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.mutedInk)
            .accessibilityHidden(true)
    }
}

// MARK: - Text field

/// One labelled text field, with its own error underneath it.
///
/// The label sits **above** the field and stays there. A placeholder standing
/// in for a label disappears the moment someone types, which is the moment they
/// most need it, and it leaves a half-filled form with no way to tell what any
/// box was for.
///
/// Focus belongs to the caller and arrives as a `FocusState` binding, because
/// the field cannot know what comes after it. That binding is what makes a
/// return key move to the next field instead of dismissing the keyboard.
public struct ReloraFormField<Field: Hashable>: View {
    private let title: String
    @Binding private var text: String
    private let focus: FocusState<Field?>.Binding
    private let field: Field
    private let error: String?
    private let placeholder: String
    private let fill: Color
    private let contentType: UITextContentType?
    private let keyboard: UIKeyboardType
    private let autocapitalization: TextInputAutocapitalization
    private let submitLabel: SubmitLabel
    private let onSubmit: () -> Void

    public init(
        _ title: String,
        text: Binding<String>,
        focus: FocusState<Field?>.Binding,
        equals field: Field,
        error: String? = nil,
        placeholder: String = "",
        fill: Color = ReloraColor.card,
        contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .never,
        submitLabel: SubmitLabel = .return,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.title = title
        self._text = text
        self.focus = focus
        self.field = field
        self.error = error
        self.placeholder = placeholder
        self.fill = fill
        self.contentType = contentType
        self.keyboard = keyboard
        self.autocapitalization = autocapitalization
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
            ReloraFieldLabel(title)

            TextField(placeholder, text: $text)
                .font(ReloraFont.listBody)
                .foregroundStyle(ReloraColor.ink)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .focused(focus, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .modifier(
                    ReloraFieldChrome(
                        fill: fill,
                        isFocused: focus.wrappedValue == field,
                        hasError: error != nil
                    )
                )
                .accessibilityLabel(title)

            if let error {
                ReloraInlineError(error)
            }
        }
    }
}

// MARK: - Secure field

/// A password field, with the reveal every password field should have.
///
/// The toggle is not a convenience. Typing a generated password into dots on a
/// phone keyboard is where sign-in attempts go to die, and the alternative to
/// showing it is a second failed attempt the user cannot explain.
///
/// Revealing swaps `SecureField` for `TextField` and puts focus straight back,
/// so the keyboard stays up and the caret does not jump to the front of the
/// string on the way through.
public struct ReloraSecureFormField<Field: Hashable>: View {
    private let title: String
    @Binding private var text: String
    private let focus: FocusState<Field?>.Binding
    private let field: Field
    private let error: String?
    private let placeholder: String
    private let fill: Color
    private let contentType: UITextContentType?
    private let submitLabel: SubmitLabel
    private let onSubmit: () -> Void

    @State private var isRevealed = false

    public init(
        _ title: String,
        text: Binding<String>,
        focus: FocusState<Field?>.Binding,
        equals field: Field,
        error: String? = nil,
        placeholder: String = "",
        fill: Color = ReloraColor.card,
        contentType: UITextContentType? = .password,
        submitLabel: SubmitLabel = .return,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.title = title
        self._text = text
        self.focus = focus
        self.field = field
        self.error = error
        self.placeholder = placeholder
        self.fill = fill
        self.contentType = contentType
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
            ReloraFieldLabel(title)

            HStack(spacing: ReloraSpacing.sm) {
                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .font(ReloraFont.listBody)
                .foregroundStyle(ReloraColor.ink)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focus, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .accessibilityLabel(title)

                Button {
                    isRevealed.toggle()
                    focus.wrappedValue = field
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
            }
            .modifier(
                ReloraFieldChrome(
                    fill: fill,
                    isFocused: focus.wrappedValue == field,
                    hasError: error != nil
                )
            )

            if let error {
                ReloraInlineError(error)
            }
        }
    }
}

#Preview {
    struct Harness: View {
        enum Field { case email, password }
        @FocusState var focus: Field?
        @State var email = ""
        @State var password = ""

        var body: some View {
            VStack(spacing: ReloraSpacing.md) {
                ReloraFormField(
                    "Email",
                    text: $email,
                    focus: $focus,
                    equals: .email,
                    placeholder: "you@example.com",
                    contentType: .username,
                    keyboard: .emailAddress,
                    submitLabel: .next,
                    onSubmit: { focus = .password }
                )
                ReloraSecureFormField(
                    "Password",
                    text: $password,
                    focus: $focus,
                    equals: .password,
                    error: "That email or password does not match.",
                    submitLabel: .go
                )
            }
            .padding(ReloraSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ReloraColor.background)
        }
    }
    return Harness()
}
