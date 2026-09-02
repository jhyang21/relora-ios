import SwiftUI

/// The input meter shown while recording.
///
/// ## What it draws, and what it refuses to draw
///
/// A row of bars, one per recent level sample, oldest on the left. It is a
/// record of what the microphone actually heard over the last few seconds —
/// silence draws flat, speech draws tall, and nothing moves when nothing is
/// said. The alternative, and the thing this deliberately is not, is an
/// ornament that oscillates on a timer so the screen looks alive: that tells
/// the user the app is listening when it may not be, which is exactly the
/// moment they most need the truth.
///
/// ## Reduce Motion
///
/// This is one of the few places allowed to read the trait directly. The rest
/// of the app names a `ReloraAnimation` and lets `Motion.swift` handle it, but
/// here the motion *is* the content — there is no curve to drop. With Reduce
/// Motion on it draws a single level bar instead of a scrolling history: the
/// same information, arriving without anything sliding across the screen.
///
/// ## VoiceOver
///
/// A meter of forty bars is forty meaningless elements to a screen reader, so
/// the whole row is one element that reports loudness in words. A blind user
/// running this flow needs to know the microphone is hearing them; they do not
/// need the shape of the last five seconds.
public struct VoiceLevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let levels: [Float]
    private let isActive: Bool

    /// - Parameters:
    ///   - levels: recent samples, 0…1, oldest first.
    ///   - isActive: whether audio is being captured right now. A stopped
    ///     meter dims rather than disappearing, so the layout does not jump
    ///     between recording and processing.
    public init(levels: [Float], isActive: Bool) {
        self.levels = levels
        self.isActive = isActive
    }

    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3
    private static let height: CGFloat = 72
    /// Even silence draws a thin line. A row that vanishes reads as a broken
    /// microphone rather than a quiet room.
    private static let minimumBarFraction: CGFloat = 0.06

    private var current: Float {
        levels.last ?? 0
    }

    public var body: some View {
        meter
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .opacity(isActive ? 1 : 0.45)
            .reloraAnimation(.quick, value: isActive)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
            .accessibilityValue(Self.loudnessDescription(current, isActive: isActive))
    }

    @ViewBuilder
    private var meter: some View {
        if reduceMotion {
            singleBar
        } else {
            history
        }
    }

    private var history: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule(style: .continuous)
                    .fill(ReloraColor.accent)
                    .frame(
                        width: Self.barWidth,
                        height: Self.height * Self.fraction(level)
                    )
                    // Older samples fade out, so the eye lands on the present
                    // without the row needing to scroll or slide.
                    .opacity(Self.recencyOpacity(index: index, count: levels.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // The row grows from the right as samples arrive; clipping keeps the
        // oldest bars from spilling past the card edge on a narrow screen.
        .clipped()
    }

    /// The Reduce Motion form: one bar that reports the current level.
    private var singleBar: some View {
        ZStack(alignment: .bottom) {
            Capsule(style: .continuous)
                .fill(ReloraColor.accentTintFill)
            Capsule(style: .continuous)
                .fill(ReloraColor.accent)
                .frame(height: Self.height * Self.fraction(current))
        }
        .frame(width: 10)
    }

    private static func fraction(_ level: Float) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return minimumBarFraction + clamped * (1 - minimumBarFraction)
    }

    private static func recencyOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let age = Double(count - 1 - index) / Double(count - 1)
        return 1 - age * 0.65
    }

    /// Loudness in words. Four steps, not a percentage: "38 percent" is a
    /// number nobody can act on, while "hearing you clearly" answers the only
    /// question the meter is there to answer.
    static func loudnessDescription(_ level: Float, isActive: Bool) -> String {
        guard isActive else { return "Not recording" }
        switch level {
        case ..<0.08: return "Silent"
        case ..<0.2: return "Quiet"
        case ..<0.5: return "Hearing you clearly"
        default: return "Loud"
        }
    }
}
