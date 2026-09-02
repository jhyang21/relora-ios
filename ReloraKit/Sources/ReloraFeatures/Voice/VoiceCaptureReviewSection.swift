import SwiftUI
import ReloraCore
import ReloraDesign

/// The review body: contact, note, key things, reminder, transcript, exits.
///
/// Ports `components/VoiceCaptureReviewSection.tsx` together with the two cards
/// it composes (`ExtractedMemoryCard`, `TranscriptAccordion`). Save is not here
/// — it lives in the composer's sticky footer, one thumb-reach away however far
/// this scrolls, exactly as RN arranges it.
///
/// Everything on screen is a suggestion. The extraction guessed; this is where
/// the user overrules it, and nothing is written until they do or decline to.
struct VoiceCaptureReviewSection: View {
    @Bindable var model: VoiceCaptureViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
            heading
            contactRow

            if model.usedLocalGuestFallback {
                guestNotice
            }

            noteSection
            keyThingsSection

            if model.reminderSuggestion != nil {
                reminderCard
            }

            audioReplaySection
            transcriptDisclosure
            footerActions
        }
    }

    // MARK: Heading and contact

    private var heading: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
            Text(VoiceCaptureCopy.reviewTitle)
                .font(ReloraFont.title3)
                .foregroundStyle(ReloraColor.ink)
            Text(VoiceCaptureCopy.reviewSubtitle)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.mutedInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var contactRow: some View {
        ReloraCard(surface: ReloraColor.warmCard) {
            HStack(spacing: ReloraSpacing.md) {
                if let name = model.activeContactName {
                    ReloraAvatar(name: name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.ink)
                        Text(isNewContact ? "New contact" : "Existing contact")
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VoiceCaptureCopy.contactPrompt)
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.ink)
                        Text(VoiceCaptureCopy.contactPromptHelp)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }
                }

                Spacer(minLength: ReloraSpacing.sm)

                Button(model.activeContactName == nil ? "Pick" : "Change") {
                    model.isPickerPresented = true
                }
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.accentText)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(model.isSaving)
                .accessibilityLabel(
                    model.activeContactName == nil
                        ? "Pick the contact this note belongs to"
                        : "Change the contact this note belongs to"
                )
            }
        }
    }

    /// `.some(.new)` rather than `.new`: `selection` is optional, and an
    /// unlabelled case pattern will not match through the `Optional`.
    private var isNewContact: Bool {
        if case .some(.new) = model.selection { return true }
        return false
    }

    private var guestNotice: some View {
        ReloraCard(surface: ReloraColor.softHighlight) {
            VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                Text(VoiceCaptureCopy.guestNoticeTitle)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)
                Text(VoiceCaptureCopy.guestNoticeBody)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Items

    /// RN hides the whole "Note" heading when there are no memories; the key
    /// things heading always shows and carries an empty line under it. Both are
    /// reproduced — a heading with nothing beneath it reads as a loading state.
    @ViewBuilder
    private var noteSection: some View {
        let memories = model.sections.memories
        if !memories.isEmpty {
            VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                sectionLabel(VoiceCaptureCopy.memorySectionTitle)
                ForEach(memories) { item in
                    itemRow(item, placeholder: VoiceCaptureCopy.memoryPlaceholder)
                }
            }
        }
    }

    private var keyThingsSection: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
            sectionLabel(VoiceCaptureCopy.keyThingsSectionTitle)

            let keyThings = model.sections.keyThings
            if keyThings.isEmpty {
                Text(VoiceCaptureCopy.keyThingsEmpty)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
            } else {
                ForEach(keyThings) { item in
                    itemRow(item, placeholder: VoiceCaptureCopy.keyThingPlaceholder)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.mutedInk)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    /// One editable line and its keep switch.
    ///
    /// The field is always editable, where RN needs a tap to swap a `Text` for
    /// a `TextInput`. That dance exists to work around focus handling in React
    /// Native; a `TextField` here is already a tap away from the keyboard, and
    /// the extra state would only add a way to be looking at a field that will
    /// not take a keystroke.
    ///
    /// RN also stamps each card with a "Memory"/"Key thing" pill. The section
    /// heading above already says which is which, so the pill is dropped rather
    /// than repeated on every row.
    private func itemRow(_ item: VoiceReviewItem, placeholder: String) -> some View {
        ReloraCard {
            VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                TextField(
                    placeholder,
                    text: Binding(
                        get: { item.text },
                        set: { model.setItemText($0, for: item.id) }
                    ),
                    axis: .vertical
                )
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.ink)
                .lineLimit(2...8)
                .disabled(model.isSaving)
                .accessibilityLabel(
                    item.kind == .memory ? VoiceCaptureCopy.memorySectionTitle : "Key thing"
                )

                Toggle(
                    VoiceCaptureCopy.keepLabel(kind: item.kind),
                    isOn: Binding(
                        get: { item.keep },
                        set: { _ in model.toggleKeep(item.id) }
                    )
                )
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .tint(ReloraColor.accent)
                .disabled(model.isSaving)
            }
            // Dimmed, not hidden, when switched off: the user can still read
            // what they are declining and change their mind without recording
            // again. RN dims the whole card the same way.
            .opacity(item.keep ? 1 : 0.5)
        }
        .reloraAnimation(.quick, value: item.keep)
    }

    // MARK: Reminder

    @ViewBuilder
    private var reminderCard: some View {
        if let suggestion = model.reminderSuggestion {
            ReloraCard(surface: ReloraColor.warmTintStrong) {
                VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                    sectionLabel(VoiceCaptureCopy.reminderCardTitle)

                    Text(suggestion.title)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)

                    Toggle(VoiceCaptureCopy.reminderKeepLabel, isOn: $model.acceptReminder)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .tint(ReloraColor.accent)
                        .disabled(model.isSaving)

                    if model.acceptReminder {
                        // A date the user cannot move is a reminder they have to
                        // delete and recreate to fix. RN offers the suggested
                        // time or nothing; this offers the suggested time and a
                        // way to move it. Recorded as a deviation in the M6
                        // report.
                        DatePicker(
                            VoiceCaptureCopy.reminderDateLabel,
                            selection: $model.reminderDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .tint(ReloraColor.accent)
                        .disabled(model.isSaving)
                    } else {
                        // What is being declined, said in words. Once the
                        // reminder is kept the picker above states the same
                        // thing and this would only repeat it.
                        Text(
                            ReloraRelativeTime.friendlyDateTime(
                                suggestion.remindAt,
                                now: ReloraTimestamp.now()
                            )
                        )
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                    }
                }
            }
            .reloraAnimation(.gentle, value: model.acceptReminder)
        }
    }

    // MARK: Audio replay (M7)

    /// Ports RN's `AudioReplayButton` section — absent when there is no
    /// recording to replay (a guest's typed-only draft has none, since
    /// recording always happens before the review screen can even open,
    /// but a defensive check costs nothing here).
    @ViewBuilder
    private var audioReplaySection: some View {
        if let url = model.audioFileURL {
            ReloraCard {
                VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                    sectionLabel(VoiceCaptureCopy.audioReplayTitle)
                    Text(VoiceCaptureCopy.audioReplayBody)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                    AudioReplayPill(url: url)
                }
            }
        }
    }

    // MARK: Transcript

    /// Closed by default, and absent entirely without a transcript — a guest's
    /// capture and a failed extraction both arrive with an empty string, and a
    /// control that opens onto nothing is worse than no control.
    @ViewBuilder
    private var transcriptDisclosure: some View {
        if !model.transcript.trimmed.isEmpty {
            ReloraCard {
                DisclosureGroup(isExpanded: $model.isTranscriptExpanded) {
                    Text(model.transcript)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, ReloraSpacing.sm)
                } label: {
                    Text(VoiceCaptureCopy.transcriptDisclosure)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)
                }
                .tint(ReloraColor.accentText)
            }
            .reloraAnimation(.gentle, value: model.isTranscriptExpanded)
        }
    }

    // MARK: Footer

    private var footerActions: some View {
        VStack(spacing: ReloraSpacing.sm) {
            Button(VoiceCaptureCopy.recordAgain) {
                Task { await model.beginCapture() }
            }
            .buttonStyle(.reloraSecondary)
            .disabled(model.isSaving)

            Button(VoiceCaptureCopy.discardAction, role: .destructive) {
                model.requestClose()
            }
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.danger)
            .frame(minHeight: 44)
            .disabled(model.isSaving)
            .accessibilityLabel("Discard this note")
            .accessibilityHint("Asks first, then closes without saving")
        }
    }
}
