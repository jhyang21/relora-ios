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
                        MemoryRow(memory: memory, nowISO: nowISO)
                            .swipeDelete(kind: .memory) {
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
                        ContactItemRow(
                            title: keyThing.text,
                            meta: ReloraRelativeTime.friendlyDateTime(keyThing.updatedAt, now: nowISO)
                        )
                        .swipeDelete(kind: .keyThing) {
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
                        ContactItemRow(
                            title: reminder.title,
                            meta: ContactDetailModel.reminderMeta(reminder, nowISO: nowISO)
                        )
                        .swipeDelete(kind: .reminder) {
                            model.deleteItem(id: reminder.id, kind: .reminder)
                        }
                    }
                }
            }
        }
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
        .accessibilityElement(children: .combine)
    }
}

/// One memory in the timeline: what was written down and when, the transcript
/// it came from behind a disclosure, and the replay control if there is audio.
///
/// One root view, because `.swipeDelete` swipes whatever it is attached to —
/// the disclosure and the pill have to sit inside this `VStack` rather than
/// beside the row in the `ForEach`, or only the row above them would swipe.
/// Expansion is per-row `@State`, so opening one transcript redraws that row
/// alone, and `ForEach(id: \.id)` keeps each row's identity across a reload so
/// an open transcript stays open. No `ReloraCard` — a list row is already a
/// surface — and deliberately no `.accessibilityElement(children: .combine)`,
/// which would swallow the disclosure button; `ContactItemRow` already
/// combines its own two texts.
struct MemoryRow: View {
    let memory: Memory
    let nowISO: String

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
            ContactItemRow(
                title: memory.text,
                meta: ReloraRelativeTime.friendlyDateTime(memory.createdAt, now: nowISO)
            )

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

            if let audioLocalURI = memory.audioLocalURI, let url = URL(string: audioLocalURI) {
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
    /// The swipe action every deletable row uses, labelled per kind so
    /// VoiceOver's actions rotor says what it would delete.
    func swipeDelete(kind: ContactItemKind, perform: @escaping () -> Void) -> some View {
        let copy = ContactDetailModel.itemDeleteCopy(kind)
        return swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: perform) {
                Label(copy.deleteLabel, systemImage: "trash")
            }
        }
    }
}
