import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign

/// Edit one memory or one key thing.
///
/// Modeled on `ContactEditView` down to the shape of the save path: a native
/// `Form`, Cancel/Save in the toolbar, the existing row loaded off the main
/// actor in a `.task`, and an inline error Section rather than an alert.
///
/// A memory also carries a date. It is `created_at` — the moment Relora
/// recorded the note — shown in full and editable, because the recording time
/// is only ever an approximation of when the conversation actually happened
/// (Andrew's 2026-09-07 QA call). A key thing has no date: it is a fact, not
/// an event.
public struct ContactItemEditView: View {
    @State private var draft = ContactItemDraft()
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// What the row said before this sheet opened, for the footer's "Relora
    /// recorded this on …" line and as the value written back when the stored
    /// timestamp did not parse — the one case where there is no picker to
    /// read a date from.
    @State private var originalCreatedAt: String?

    private let target: AppRouter.ContactItemEditTarget
    private let database: AppDatabase
    private let userIDProvider: () async -> String
    private let onCancel: () -> Void
    private let onSaved: () -> Void

    /// - Parameters:
    ///   - userIDProvider: Returns the id the row must belong to. The same
    ///     provider `ContactEditView` takes; an edit never mints an identity
    ///     in practice, since a row can only be edited if it already exists.
    ///   - onSaved: Called once the write lands. `ContactDetailViewModel`
    ///     picks the change up on its own through `observeContentChanges()`,
    ///     so this only has to close the sheet.
    public init(
        target: AppRouter.ContactItemEditTarget,
        database: AppDatabase,
        userIDProvider: @escaping () async -> String,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.target = target
        self.database = database
        self.userIDProvider = userIDProvider
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    private var isMemory: Bool {
        if case .memory = target { return true }
        return false
    }

    private var title: String {
        isMemory ? "Edit Memory" : "Edit Key Thing"
    }

    private var sectionHeader: String {
        isMemory ? "Memory" : "Key thing"
    }

    /// The picker needs a non-optional `Date`. Nothing renders the picker
    /// until the row has loaded and set a date, so the fallback below is only
    /// ever a type-level formality.
    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft.date ?? Date() },
            set: { draft.date = $0 }
        )
    }

    private var recordedFooter: String {
        guard let originalCreatedAt else { return "" }
        let when = ReloraRelativeTime.absoluteDateTime(originalCreatedAt, now: ReloraTimestamp.now())
        guard !when.isEmpty else { return "" }
        return "Relora recorded this on \(when). Change it if the conversation happened at a different time."
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $draft.text, axis: .vertical)
                        .lineLimit(3...12)
                } header: {
                    Text(sectionHeader)
                }

                if isMemory, draft.date != nil {
                    Section {
                        DatePicker(
                            "Date",
                            selection: dateBinding,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    } header: {
                        Text("When")
                    } footer: {
                        Text(recordedFooter)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!ContactItemEditForm.canSave(draft) || isSaving || !isLoaded)
                }
            }
            .task { await loadExisting() }
        }
    }

    private func loadExisting() async {
        guard !isLoaded else { return }

        let database = self.database
        let userID = await userIDProvider()

        switch target {
        case .memory(let id):
            let memory = await Task.detached(priority: .userInitiated) {
                try? MemoryRepository(database: database).get(id: id)
            }.value
            guard let memory, memory.userID == userID, memory.deletedAt == nil else {
                errorMessage = "This memory is no longer here."
                return
            }
            draft = ContactItemDraft(text: memory.text, date: ReloraTimestamp.parse(memory.createdAt))
            originalCreatedAt = memory.createdAt

        case .keyThing(let id):
            let keyThing = await Task.detached(priority: .userInitiated) {
                try? KeyThingRepository(database: database).get(id: id)
            }.value
            guard let keyThing, keyThing.userID == userID, keyThing.deletedAt == nil else {
                errorMessage = "This key thing is no longer here."
                return
            }
            draft = ContactItemDraft(text: keyThing.text, date: nil)
        }

        isLoaded = true
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let normalized = ContactItemEditForm.normalize(draft)
        guard ContactItemEditForm.canSave(normalized) else {
            errorMessage = isMemory
                ? "A memory needs some text, and a date that has already happened."
                : "A key thing needs some text."
            return
        }

        let database = self.database
        let userID = await userIDProvider()
        let text = normalized.text
        // Only strings cross into the detached task — the same discipline
        // `ContactEditView.save()` keeps.
        let saved: Bool
        switch target {
        case .memory(let id):
            let createdAt = normalized.date.map(ReloraTimestamp.from)
                ?? originalCreatedAt
                ?? ReloraTimestamp.now()
            saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try MemoryRepository(database: database)
                        .edit(id: id, text: text, createdAt: createdAt, userID: userID)
                    return true
                } catch {
                    return false
                }
            }.value

        case .keyThing(let id):
            saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try KeyThingRepository(database: database)
                        .edit(id: id, text: text, userID: userID)
                    return true
                } catch {
                    return false
                }
            }.value
        }

        guard saved else {
            errorMessage = isMemory
                ? "Could not save this memory. Try again."
                : "Could not save this key thing. Try again."
            return
        }

        onSaved()
    }
}
