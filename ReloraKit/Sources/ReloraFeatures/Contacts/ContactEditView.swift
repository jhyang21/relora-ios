import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign

/// Add or edit a contact.
///
/// A native `Form` — grouped rows, system text fields, the keyboard types iOS
/// already knows for a phone number and an email. There is nothing here worth
/// hand-building, and a hand-built form is a form that gets Dynamic Type,
/// VoiceOver and the keyboard toolbar slightly wrong.
///
/// Presented as a sheet rather than pushed. The milestone brief listed contact
/// editing among the navigation routes, but the same brief asks for Cancel and
/// Save in the toolbar, and a Cancel button beside a back button is two ways out
/// of one screen. Apple's Contacts presents both new and edit modally; this
/// follows it. Recorded as a deviation in the M5 report.
public struct ContactEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ContactDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let target: AppRouter.ContactEditTarget
    private let database: AppDatabase
    private let toasts: ReloraToastCenter
    private let userIDProvider: () async -> String
    private let onSaved: (String) -> Void

    /// - Parameters:
    ///   - userIDProvider: Returns the id new rows belong to, minting a local
    ///     guest identity if there is none yet. Saving is a data-creating
    ///     action, and a fresh install has no identity until one is asked for.
    ///   - onSaved: Handed the contact id once the write lands.
    public init(
        target: AppRouter.ContactEditTarget,
        database: AppDatabase,
        toasts: ReloraToastCenter,
        userIDProvider: @escaping () async -> String,
        onSaved: @escaping (String) -> Void
    ) {
        self.target = target
        self.database = database
        self.toasts = toasts
        self.userIDProvider = userIDProvider
        self.onSaved = onSaved

        switch target {
        case .new(let prefill):
            _draft = State(initialValue: prefill ?? ContactDraft())
        case .existing:
            _draft = State(initialValue: ContactDraft())
        }
    }

    private var title: String {
        switch target {
        case .new: return "New Contact"
        case .existing: return "Edit Contact"
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The only thing Relora needs.")
                }

                Section {
                    TextField("Descriptors", text: $draft.descriptors, axis: .vertical)
                        .autocorrectionDisabled()
                } header: {
                    Text("Who they are")
                } footer: {
                    Text("Separate with commas — \"designer, climbs, Oakland\".")
                }

                Section("Reach them") {
                    TextField("Phone", text: $draft.phoneNumber)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    TextField("Email", text: $draft.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!ContactEditForm.canSave(draft) || isSaving)
                }
            }
            .task { await loadExisting() }
        }
    }

    private func loadExisting() async {
        guard case .existing(let contactID) = target else { return }

        let database = self.database
        let userID = await userIDProvider()
        let contact = await Task.detached(priority: .userInitiated) {
            try? ContactRepository(database: database)
                .getContactsByIDs([contactID], userID: userID)
                .first
        }.value

        if let contact {
            draft = ContactDraft(contact: contact)
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let normalized: NormalizedContactDraft
        do {
            // Trimming happens here, on the save path, not while typing. The
            // milestone notes make this binding: RN's schemas trim every
            // user-visible string, and a name stored with a trailing space
            // sorts and matches differently from the same name without one.
            normalized = try ContactEditForm.normalize(draft)
        } catch {
            errorMessage = "A name is required."
            return
        }

        let userID = await userIDProvider()
        let contactID: String
        switch target {
        case .new: contactID = ReloraID.new()
        case .existing(let id): contactID = id
        }

        let database = self.database
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try ContactRepository(database: database).upsert(
                    id: contactID,
                    userID: userID,
                    name: normalized.name,
                    descriptors: normalized.descriptors,
                    phoneNumber: normalized.phoneNumber,
                    email: normalized.email
                )
                return true
            } catch {
                return false
            }
        }.value

        guard saved else {
            errorMessage = "Could not save this contact. Try again."
            return
        }

        dismiss()
        onSaved(contactID)
        if case .new = target {
            toasts.show("\(normalized.name) added", variant: .success)
        }
    }
}
