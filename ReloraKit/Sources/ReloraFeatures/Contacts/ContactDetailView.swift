import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// One person: who they are, and everything Relora remembers about them.
///
/// Deletes here are immediate and undoable. A row swipes away, a toast says what
/// went and offers Undo for four seconds, and no dialog stands between the
/// gesture and the result. The single exception is deleting a contact who
/// carries memories or key things — see `requestDeleteContact()`.
public struct ContactDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var model: ContactDetailViewModel

    public init(
        contactID: String,
        userID: String,
        database: AppDatabase,
        toasts: ReloraToastCenter,
        hooks: ReminderNotificationHooks = .noop
    ) {
        _model = State(
            initialValue: ContactDetailViewModel(
                contactID: contactID,
                userID: userID,
                database: database,
                toasts: toasts,
                hooks: hooks
            )
        )
    }

    private var nowISO: String { ReloraTimestamp.now() }

    public var body: some View {
        @Bindable var model = model

        List {
            if let contact = model.snapshot.contact {
                Section {
                    ContactDetailHeader(contact: contact, nowISO: nowISO)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    Picker("View", selection: $model.tab) {
                        ForEach(ContactDetailTab.allCases) { tab in
                            Text(tabLabel(tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                tabContent
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ReloraColor.background)
        .navigationTitle(model.snapshot.contact?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .reloraFloatingActions {
            ReloraRecordButton {
                router.present(.voiceComposer(contactID: model.contactID))
            }
        }
        .alert(
            model.pendingDeleteConfirmation?.title ?? "",
            isPresented: Binding(
                get: { model.pendingDeleteConfirmation != nil },
                set: { if !$0 { model.pendingDeleteConfirmation = nil } }
            ),
            presenting: model.pendingDeleteConfirmation
        ) { confirmation in
            Button(confirmation.confirmLabel, role: .destructive) { model.deleteContact() }
            Button("Cancel", role: .cancel) { model.pendingDeleteConfirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .task { model.start() }
        .onChange(of: model.contactWasDeleted) { _, deleted in
            // Leaving is part of the delete, not a consequence of it: staying on
            // a screen about someone who is gone would be the strange thing. The
            // Undo toast survives the pop — it lives above the navigator.
            if deleted { dismiss() }
        }
    }

    private func tabLabel(_ tab: ContactDetailTab) -> String {
        switch tab {
        case .memories: return "\(tab.title) (\(model.snapshot.memories.count))"
        case .keyThings: return "\(tab.title) (\(model.snapshot.keyThings.count))"
        case .reminders: return "\(tab.title) (\(model.snapshot.reminders.count))"
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .memories:
            if model.snapshot.memories.isEmpty {
                emptySection("No memories yet", "Record a note after your next conversation.")
            } else {
                Section {
                    ForEach(model.snapshot.memories, id: \.id) { memory in
                        MemoryRow(
                            memory: memory,
                            onEdit: { editMemory(memory.id) }
                        )
                        .rowActions(kind: .memory) {
                            editMemory(memory.id)
                        } delete: {
                            model.deleteItem(id: memory.id, kind: .memory)
                        }
                    }
                }
            }

        case .keyThings:
            if model.snapshot.keyThings.isEmpty {
                emptySection("Nothing noted yet", "Key things are the facts worth keeping.")
            } else {
                Section {
                    ForEach(model.snapshot.keyThings, id: \.id) { keyThing in
                        Button {
                            editKeyThing(keyThing.id)
                        } label: {
                            ContactItemRow(
                                title: keyThing.text,
                                meta: ReloraRelativeTime.friendlyDateTime(keyThing.updatedAt, now: nowISO)
                            )
                        }
                        .buttonStyle(.plain)
                        .rowActions(kind: .keyThing) {
                            editKeyThing(keyThing.id)
                        } delete: {
                            model.deleteItem(id: keyThing.id, kind: .keyThing)
                        }
                    }
                }
            }

        case .reminders:
            if model.snapshot.reminders.isEmpty {
                emptySection("No reminders", "Reminders come from your notes, or you can add one.")
            } else {
                Section {
                    ForEach(model.snapshot.reminders, id: \.id) { reminder in
                        Button {
                            editReminder(reminder.id)
                        } label: {
                            ContactItemRow(
                                title: reminder.title,
                                meta: ContactDetailModel.reminderMeta(reminder, nowISO: nowISO)
                            )
                        }
                        .buttonStyle(.plain)
                        .rowActions(kind: .reminder) {
                            editReminder(reminder.id)
                        } delete: {
                            model.deleteItem(id: reminder.id, kind: .reminder)
                        }
                    }
                }
            }
        }
    }

    // MARK: Editing one item

    private func editMemory(_ id: String) {
        router.present(.contactItemEdit(.memory(id: id)))
    }

    private func editKeyThing(_ id: String) {
        router.present(.contactItemEdit(.keyThing(id: id)))
    }

    private func editReminder(_ id: String) {
        router.present(.addReminder(
            contactID: model.contactID,
            contactName: model.snapshot.contact?.name ?? "",
            reminderID: id
        ))
    }

    private func emptySection(_ title: String, _ message: String) -> some View {
        Section {
            ReloraEmptyState.section(title, message: message)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    router.present(.addReminder(
                        contactID: model.contactID,
                        contactName: model.snapshot.contact?.name ?? ""
                    ))
                } label: {
                    Label("Add reminder", systemImage: "bell.badge.plus")
                }
                Button {
                    router.present(.contactEdit(.existing(contactID: model.contactID)))
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    model.requestDeleteContact()
                } label: {
                    Label("Delete contact", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Contact actions")
        }
    }
}

// MARK: - Pieces

struct ContactDetailHeader: View {
    let contact: Contact
    let nowISO: String

    /// The imported number, in the shape a person reads it. Import already
    /// copies phone and email off the system contact; until 2.5.0 the detail
    /// screen simply never showed either, which made the import look like it
    /// had dropped them.
    private var phone: String? {
        guard let raw = contact.phoneNumber?.trimmed, !raw.isEmpty else { return nil }
        return raw
    }

    private var email: String? {
        guard let raw = contact.email?.trimmed, !raw.isEmpty else { return nil }
        return raw
    }

    private var phoneURL: URL? {
        guard let phone, let dialable = PhoneNumberFormat.dialable(phone) else { return nil }
        return URL(string: "tel:\(dialable)")
    }

    /// Percent-encoded, because an address is user-entered text and a `mailto:`
    /// built from a raw string with a space in it does not parse.
    private var emailURL: URL? {
        guard let email,
              let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "mailto:\(encoded)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
            HStack(spacing: ReloraSpacing.md) {
                ReloraAvatar(name: contact.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(ReloraFont.title3)
                        .foregroundStyle(ReloraColor.ink)
                    if !contact.descriptors.isEmpty {
                        Text(contact.descriptors.joined(separator: " · "))
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            // Each link stays its own VoiceOver control. The header used to
            // combine into a single element, which would now swallow two
            // buttons into one label; the combine moved up to the identity
            // block instead, where it was always doing the useful half of
            // the job.
            if let phone, let phoneURL {
                Link(destination: phoneURL) {
                    Label(PhoneNumberFormat.display(phone), systemImage: "phone")
                }
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.accentText)
                .accessibilityHint("Calls this number")
            }

            if let email, let emailURL {
                Link(destination: emailURL) {
                    Label(email, systemImage: "envelope")
                }
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.accentText)
                .accessibilityHint("Opens Mail")
            }

            if let lastInteractionAt = contact.lastInteractionAt {
                let relative = ReloraRelativeTime.relative(lastInteractionAt, now: nowISO)
                if !relative.isEmpty {
                    Text("Last note \(relative)")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ReloraSpacing.sm)
    }
}

/// One memory in the timeline: what was written down and when, the transcript
/// it came from behind a disclosure, and the replay control if there is audio.
///
/// One root view, because `.rowActions` swipes whatever it is attached to —
/// the disclosure and the pill have to sit inside this `VStack` rather than
/// beside the row in the `ForEach`, or only the row above them would swipe.
/// Expansion is per-row `@State`, so opening one transcript redraws that row
/// alone, and `ForEach(id: \.id)` keeps each row's identity across a reload so
/// an open transcript stays open. No `ReloraCard` — a list row is already a
/// surface — and deliberately no `.accessibilityElement(children: .combine)`,
/// which would swallow the disclosure button; `ContactItemRow` already
/// combines its own two texts.
///
/// **Only the title-and-date part opens the editor.** The row holds three
/// controls already — the disclosure, the replay pill, and now the tap that
/// edits — and a `Button` wrapped around all of them would put two tappable
/// things inside a third. Rather than gamble on SwiftUI routing the inner
/// taps correctly, the button wraps the `ContactItemRow` alone; the
/// disclosure and the pill keep the hit areas they already had, and the
/// swipe action carries Edit for anyone who taps the transcript instead.
struct MemoryRow: View {
    let memory: Memory
    let onEdit: () -> Void

    @State private var isTranscriptExpanded = false

    /// Absent rather than empty: a guest's capture and a dropped extraction
    /// both arrive as blank text, and a control that opens onto nothing is
    /// worse than no control.
    private var transcript: String? {
        guard let text = memory.transcript?.trimmed, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
            Button(action: onEdit) {
                ContactItemRow(
                    title: memory.text,
                    // Absolute, not relative. A memory's date is the one the
                    // user can now correct, and "2 days ago" is not something
                    // anyone can check against the conversation they remember.
                    meta: ReloraRelativeTime.absoluteDate(memory.createdAt)
                )
            }
            .buttonStyle(.plain)

            if let transcript {
                DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                    Text(transcript)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, ReloraSpacing.xs)
                } label: {
                    Text(VoiceCaptureCopy.transcriptDisclosure)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.accentText)
                }
                .tint(ReloraColor.accentText)
                .reloraAnimation(.gentle, value: isTranscriptExpanded)
            }

            // Gated here rather than inside `AudioReplayPill`, because the
            // pill's other caller — the review screen, showing the recording
            // just made — must show it whatever the disk says. And the check
            // belongs to the store: whether a stored value is a legacy
            // absolute `file://` string or a bare file name is storage
            // knowledge, and only the store knows where the names resolve.
            if let url = RecordingStore.shared.existingURL(for: memory.audioLocalURI ?? "") {
                AudioReplayPill(url: url)
            }
        }
    }
}

struct ContactItemRow: View {
    let title: String
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.ink)
            if !meta.isEmpty {
                Text(meta)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
            }
        }
        .padding(.vertical, ReloraSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The trailing swipe every editable row carries: Delete, then Edit.
    ///
    /// Delete is declared first because the action nearest the edge is the
    /// one a full swipe performs, and Delete-on-full-swipe is the gesture
    /// this list has always had — an Edit that stole it would be a
    /// regression dressed as a feature. Delete is labelled per kind so
    /// VoiceOver's actions rotor says what it would delete; both actions
    /// reach the rotor on their own.
    func rowActions(
        kind: ContactItemKind,
        edit: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        let copy = ContactDetailModel.itemDeleteCopy(kind)
        return swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: delete) {
                Label(copy.deleteLabel, systemImage: "trash")
            }
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(ReloraColor.accent)
        }
    }
}
