import SwiftUI
import ReloraCore
import ReloraDesign

/// Who is this note about?
///
/// Ports `components/VoiceContactPickerSheet.tsx`. It opens on its own when the
/// matcher had no confident answer, and by tap from the review's Change button
/// otherwise. Two ways out: pick someone who exists, or name someone who does
/// not.
///
/// ## Detents
///
/// `.medium` first, `.large` available. Confirming a suggested match is a
/// glance and a tap, and a full-screen sheet for that buries the review it came
/// from. Searching a long address book wants the room, so the sheet can be
/// dragged up — and the keyboard raises it on its own when the name field takes
/// focus.
struct VoiceContactPickerSheet: View {
    @Bindable var model: VoiceCaptureViewModel

    /// Focus starts here when the address book is empty. A first-run user has
    /// nothing to pick from, so the sheet opens on the one field that can move
    /// them forward instead of an empty list.
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            withSearch(list)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ReloraColor.background)
                .navigationTitle(VoiceCaptureCopy.pickerTitle(status: model.matchResult.status))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.dismissPicker() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    confirmBar
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            isNameFieldFocused = model.contacts.isEmpty
        }
    }

    private var list: some View {
        List {
            if !model.contacts.isEmpty {
                contactsSection
            }
            newContactSection
        }
    }

    /// A search field only when there is something to search. RN hides its
    /// input the same way, and a search bar over an empty address book asks a
    /// first-run user a question with no answers.
    ///
    /// The branch is safe because `contacts` is loaded once, before the
    /// composer starts recording, and does not change while this sheet is up —
    /// so the two view identities never swap under the user.
    ///
    /// Not named `searchable`: that would shadow the SwiftUI modifier of the
    /// same name at every unqualified call site in this file.
    @ViewBuilder
    private func withSearch(_ content: some View) -> some View {
        if model.contacts.isEmpty {
            content
        } else {
            content.searchable(
                text: $model.pickerQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: VoiceCaptureCopy.pickerSearchPlaceholder
            )
        }
    }

    // MARK: Existing contacts

    private var contactsSection: some View {
        Section {
            let options = model.pickerOptions
            if options.isEmpty {
                Text(VoiceCaptureCopy.pickerEmpty)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
            } else {
                ForEach(options) { option in
                    contactRow(option)
                }
            }
        } header: {
            Text(VoiceCaptureCopy.pickerSubtitle(status: model.matchResult.status))
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .textCase(nil)
        }
    }

    private func contactRow(_ option: VoiceContactChip) -> some View {
        Button {
            model.selectedChip = option.kind
        } label: {
            HStack(spacing: ReloraSpacing.md) {
                ReloraAvatar(name: option.name)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)

                    // The matcher already wrote this sentence ("Strong
                    // subject-name match, supported by transcript"), so it is
                    // shown rather than restated as a score.
                    if let reason = option.reason {
                        Text(reason)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }
                }

                Spacer(minLength: ReloraSpacing.sm)

                if isSelected(option.kind) {
                    // The `.isSelected` trait below carries this already.
                    Image(systemName: "checkmark")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.accentText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(ReloraColor.card)
        // One element, one announcement: the name, why it is offered, and
        // whether it is the current answer.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected(option.kind) ? [.isButton, .isSelected] : .isButton)
    }

    private func isSelected(_ kind: VoiceContactChip.Kind) -> Bool {
        model.selectedChip == kind
    }

    // MARK: New contact

    private var newContactSection: some View {
        Section {
            TextField(VoiceCaptureCopy.pickerNewNameLabel, text: $model.newContactName)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isNameFieldFocused)
                .onSubmit { selectNew() }
                .accessibilityLabel("New contact name")

            Button {
                selectNew()
            } label: {
                HStack {
                    Text(VoiceCaptureCopy.pickerUseNew)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.accentText)
                    Spacer(minLength: ReloraSpacing.sm)
                    if isSelected(.new) {
                        Image(systemName: "checkmark")
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.accentText)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Naming nobody is not a choice, so the row that would commit to
            // it stays inert until the field has something in it.
            .disabled(model.newContactName.trimmed.isEmpty)
            .accessibilityAddTraits(isSelected(.new) ? [.isButton, .isSelected] : .isButton)
        } header: {
            Text(VoiceCaptureCopy.pickerCreateNew)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .textCase(nil)
        }
        .listRowBackground(ReloraColor.card)
    }

    private func selectNew() {
        guard !model.newContactName.trimmed.isEmpty else { return }
        model.selectedChip = .new
        isNameFieldFocused = false
    }

    // MARK: Confirm

    private var confirmBar: some View {
        Button(VoiceCaptureCopy.pickerConfirm) {
            model.confirmPicker()
        }
        .buttonStyle(.reloraPrimary)
        .disabled(!model.canConfirmPicker)
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .padding(.vertical, ReloraSpacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
