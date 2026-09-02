import Foundation
import SwiftUI
import UIKit

/// Relora's motion durations.
///
/// Motion here is short and unshowy. Nothing bounces for effect; the longest
/// token is under a quarter second. If an interaction seems to want a longer or
/// springier animation, the interaction is probably wrong.
///
/// Features should name a feeling with ``ReloraAnimation`` rather than reach for
/// a raw duration. These are exposed for the cases that need a bare number —
/// a `Task.sleep` sequenced against an animation, say.
public enum ReloraDuration {
    /// 0.12s — state that should feel instant: a press highlight, a checkbox.
    public static let quick: TimeInterval = 0.12

    /// 0.18s — the default. Most appearance and layout changes.
    public static let standard: TimeInterval = 0.18

    /// 0.22s — the longest token. Content arriving or leaving: a sheet, a toast,
    /// a card expanding.
    public static let gentle: TimeInterval = 0.22
}

/// A named animation. Features name the feeling, not the curve.
///
/// ## Reduce Motion is handled here, once
///
/// **Features must never read `accessibilityReduceMotion` themselves.** Both
/// entry points below already do. A feature that checks the setting is a feature
/// that will forget to check it somewhere else, and the first anyone hears about
/// it is a bug report from someone who gets motion sick.
///
/// Two entry points, matching the two ways SwiftUI animates:
///
/// - `.reloraAnimation(_:value:)` — the view modifier, for state-driven
///   animation. Reads the environment, so it also honors a preview or test
///   override of the trait.
/// - `withReloraAnimation(_:) { … }` — the imperative form, for animating a
///   change you are making right now (a tap handler, a completion block). Reads
///   `UIAccessibility` directly, because there is no environment at that point.
///
/// Both collapse to an instant, un-animated change when Reduce Motion is on. The
/// state change still happens — only the interpolation is dropped.
public enum ReloraAnimation {
    /// `easeOut` over `ReloraDuration.quick`. Immediate feedback.
    case quick

    /// `easeInOut` over `ReloraDuration.standard`. The default.
    case standard

    /// `easeInOut` over `ReloraDuration.gentle`. Arrivals and departures.
    case gentle

    /// The standard spring — a small settle with no visible overshoot.
    ///
    /// `response: 0.32, dampingFraction: 0.82`. Damping is high on purpose: the
    /// motion arrives and stops. Use it for anything a finger drives (a sheet
    /// following a drag, the record button responding to a press), where an
    /// eased duration reads as mechanical.
    case spring

    /// The underlying curve, ignoring Reduce Motion. Prefer the two entry points
    /// below, which respect it; this is exposed for the rare case of composing
    /// into a larger animation you are already gating.
    public var curve: Animation {
        switch self {
        case .quick:
            return .easeOut(duration: ReloraDuration.quick)
        case .standard:
            return .easeInOut(duration: ReloraDuration.standard)
        case .gentle:
            return .easeInOut(duration: ReloraDuration.gentle)
        case .spring:
            return .spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0)
        }
    }
}

private struct ReloraAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let token: ReloraAnimation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : token.curve, value: value)
    }
}

public extension View {
    /// Animates this view's changes to `value` with a Relora motion token,
    /// honoring Reduce Motion automatically.
    ///
    /// ```swift
    /// CardView(expanded: isExpanded)
    ///     .reloraAnimation(.gentle, value: isExpanded)
    /// ```
    ///
    /// With Reduce Motion on, the animation becomes `nil` and the view snaps to
    /// its new state. Do not add a second, "reduced" animation — no motion is the
    /// correct reduced motion here.
    func reloraAnimation<V: Equatable>(_ token: ReloraAnimation = .standard, value: V) -> some View {
        modifier(ReloraAnimationModifier(token: token, value: value))
    }
}

/// Applies a state change with a Relora motion token, honoring Reduce Motion.
///
/// The imperative counterpart to `.reloraAnimation(_:value:)`, for changes made
/// outside the view-update cycle:
///
/// ```swift
/// Button("Show details") {
///     withReloraAnimation(.gentle) { isExpanded = true }
/// }
/// ```
///
/// With Reduce Motion on, `body` runs unwrapped — the change lands immediately
/// and completely. This reads `UIAccessibility.isReduceMotionEnabled` rather than
/// the environment because a closure like this has no environment to read; the
/// difference matters only in previews and tests, where the modifier form honors
/// an injected trait and this one does not.
@MainActor
@discardableResult
public func withReloraAnimation<Result>(
    _ token: ReloraAnimation = .standard,
    _ body: () throws -> Result
) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled {
        return try body()
    }
    return try withAnimation(token.curve, body)
}
