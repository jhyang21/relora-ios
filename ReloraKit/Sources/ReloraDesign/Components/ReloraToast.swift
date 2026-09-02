import SwiftUI

/// One toast.
///
/// Ports the shape of `apps/mobile/src/components/toast/toastController.ts`.
/// `action` is what carries Undo, which is the reason this whole layer exists:
/// Relora deletes immediately and offers a few seconds to take it back, instead
/// of asking "are you sure?" first.
///
/// Not `Sendable` — `action` is a main-actor closure and a toast never leaves
/// the main actor.
public struct ReloraToast: Identifiable {
    public enum Variant {
        case success
        case error
        case info
    }

    /// 4 seconds, matching RN's `DEFAULT_DURATION_MS`. Long enough to read a
    /// line and reach for Undo, short enough not to sit on the screen.
    public static let defaultDuration: TimeInterval = 4

    public let id = UUID()
    public var title: String
    public var message: String?
    public var variant: Variant
    public var duration: TimeInterval
    public var actionLabel: String?
    public var action: (@MainActor () -> Void)?

    public init(
        title: String,
        message: String? = nil,
        variant: Variant = .info,
        duration: TimeInterval = ReloraToast.defaultDuration,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.variant = variant
        self.duration = duration
        self.actionLabel = actionLabel
        self.action = action
    }
}

/// The app's one toast slot.
///
/// Rules ported from `toastController.ts`, all four of which are the difference
/// between a toast layer and a bug:
///
/// 1. **One at a time, replace semantics.** A second toast replaces the first
///    rather than queueing behind it. The newest message is the true one.
/// 2. **A stale timer never dismisses a replacement.** Each auto-dismiss checks
///    the id it was started for, so the four seconds belonging to a toast that
///    has already been replaced expire against nothing.
/// 3. **An action fires at most once**, and dismisses before it runs — a
///    double-tapped Undo must not restore twice.
/// 4. **Zero or negative duration means sticky.** No timer at all.
@MainActor
@Observable
public final class ReloraToastCenter {
    public private(set) var current: ReloraToast?

    private var dismissTask: Task<Void, Never>?
    private var handledActionIDs: Set<UUID> = []

    public init() {}

    public func show(_ toast: ReloraToast) {
        dismissTask?.cancel()
        withReloraAnimation(.gentle) {
            current = toast
        }

        guard toast.duration > 0 else {
            dismissTask = nil
            return
        }

        let id = toast.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(ifShowing: id)
        }
    }

    /// Convenience for the common `showToast(title, message)` call shape.
    public func show(
        _ title: String,
        message: String? = nil,
        variant: ReloraToast.Variant = .info,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        show(
            ReloraToast(
                title: title,
                message: message,
                variant: variant,
                actionLabel: actionLabel,
                action: action
            )
        )
    }

    /// RN's `showError` — an error-variant toast, same slot.
    public func showError(_ title: String, message: String? = nil) {
        show(title, message: message, variant: .error)
    }

    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withReloraAnimation(.gentle) {
            current = nil
        }
    }

    /// Runs the current toast's action, once, after dismissing it.
    public func performAction() {
        guard let toast = current, let action = toast.action else { return }
        guard handledActionIDs.insert(toast.id).inserted else { return }
        dismiss()
        action()
    }

    private func dismiss(ifShowing id: UUID) {
        guard current?.id == id else { return }
        dismiss()
    }
}

// MARK: - The capsule

/// The restrained capsule the design direction asks for: one surface, one line
/// of wording, an optional Undo. No icon zoo, no progress bar, no stacking.
struct ReloraToastCapsule: View {
    let toast: ReloraToast
    let onAction: () -> Void
    let onDismiss: () -> Void

    private var accentColor: Color {
        switch toast.variant {
        case .success: return ReloraColor.success
        case .error: return ReloraColor.danger
        case .info: return ReloraColor.accentText
        }
    }

    private var symbolName: String {
        switch toast.variant {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    /// One label for the whole capsule. VoiceOver reads a toast as a single
    /// announcement; splitting it into three elements makes the user swipe
    /// through a message that is about to disappear.
    private var accessibilityLabel: String {
        [toast.title, toast.message].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ReloraSpacing.sm) {
            Image(systemName: symbolName)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)
                if let message = toast.message {
                    Text(message)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)

            if let actionLabel = toast.actionLabel, toast.action != nil {
                Button(actionLabel, action: onAction)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.accentText)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, ReloraSpacing.md)
        .padding(.vertical, ReloraSpacing.sm)
        .frame(maxWidth: ReloraLayout.contentMaxWidth)
        .reloraSurface(ReloraColor.card, radius: ReloraRadius.lg, shadow: .floating)
        .reloraBorder(radius: ReloraRadius.lg)
        .onTapGesture(perform: onDismiss)
    }
}

// MARK: - Host

private struct ReloraToastLayer: ViewModifier {
    let center: ReloraToastCenter
    let clearance: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    ReloraToastCapsule(
                        toast: toast,
                        onAction: { center.performAction() },
                        onDismiss: { center.dismiss() }
                    )
                    .padding(.horizontal, ReloraLayout.screenHPadding)
                    .padding(.bottom, clearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .reloraAnimation(.gentle, value: center.current?.id)
    }
}

public extension View {
    /// Mounts the toast layer above this view.
    ///
    /// `clearance` is the gap kept below the capsule. It defaults to clearing a
    /// floating action row, because the screens that delete things are the
    /// screens that float a record button — and a toast under the record button
    /// is an Undo nobody can tap. A screen with no floating action passes
    /// `ReloraFloatingLayout.toastGap`.
    func reloraToastLayer(
        _ center: ReloraToastCenter,
        clearance: CGFloat = ReloraFloatingLayout.toastClearanceOverActions
    ) -> some View {
        modifier(ReloraToastLayer(center: center, clearance: clearance))
    }
}
