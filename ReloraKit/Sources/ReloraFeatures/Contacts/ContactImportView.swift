import SwiftUI
import UIKit
import ReloraCore
import ReloraData
import ReloraDesign

// MARK: - Single contact

/// "Import from Phone" for one person.
///
/// Picks through the system picker, then opens the normal New Contact form
/// prefilled. Ports the single-import path in `contactImport.ts`: the imported
/// values are a starting point, and the last screen before a contact exists is
/// always the form the user can correct.
public struct ContactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let onPicked: (ContactDraft) -> Void

    public init(onPicked: @escaping (ContactDraft) -> Void) {
        self.onPicked = onPicked
    }

    public var body: some View {
        SystemContactPicker(
            onPick: { contact in
                onPicked(ContactImportModel.draft(from: contact))
            },
            onFinish: { dismiss() }
        )
        .ignoresSafeArea()
    }
}

// MARK: - Bulk import

@MainActor
@Observable
public final class ContactImportViewModel {
    public enum Stage: Equatable {
        case loading
        case denied
        case select
        case review
        case importing
    }

    public private(set) var stage: Stage = .loading
    public private(set) var access: PhoneContactStore.Access = .denied
    public private(set) var phoneContacts: [ImportablePhoneContact] = []
    public private(set) var reviewItems: [BulkImportReviewItem] = []
    public private(set) var skippedInvalidCount = 0
    public var query = ""
    public var selectedIDs: Set<String> = []
    public var decisions: [String: BulkImportDecision] = [:]
    public var summary: BulkImportSummary?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let store = PhoneContactStore()
    @ObservationIgnored private let toasts: ReloraToastCenter
    @ObservationIgnored private let userIDProvider: () async -> String
    /// Built once per load, so filtering a large address book on every keystroke
    /// stays a string scan rather than a rebuild of every row's index.
    @ObservationIgnored private var searchIndex: [String: String] = [:]

    public init(
        database: AppDatabase,
        toasts: ReloraToastCenter,
        userIDProvider: @escaping () async -> String
    ) {
        self.database = database
        self.toasts = toasts
        self.userIDProvider = userIDProvider
    }

    public var maxSelectable: Int { ContactImportModel.maxBulkImportContacts }

    public var selectionLabel: String {
        "\(selectedIDs.count) of \(maxSelectable) selected"
    }

    public var filteredContacts: [ImportablePhoneContact] {
        let needle = query.trimmed.lowercased()
        guard !needle.isEmpty else { return phoneContacts }
        return phoneContacts.filter { (searchIndex[$0.id] ?? "").contains(needle) }
    }

    // MARK: Load

    public func load() async {
        stage = .loading
        access = await store.requestAccess()

        guard access != .denied else {
            stage = .denied
            return
        }

        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? store.fetchAll()) ?? []
        }.value

        phoneContacts = loaded
        searchIndex = Dictionary(
            uniqueKeysWithValues: loaded.map { ($0.id, PhoneContactStore.searchIndex($0)) }
        )
        stage = .select
    }

    // MARK: Selection

    public func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// Enforces the cap at the moment of selection rather than at import.
    ///
    /// Telling someone their 51st choice was dropped after they pressed Import
    /// is a worse experience than refusing the 51st tap and saying why.
    public func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return
        }
        guard selectedIDs.count < maxSelectable else {
            toasts.showError(
                "That's the limit",
                message: "You can import \(maxSelectable) contacts at a time."
            )
            return
        }
        selectedIDs.insert(id)
    }

    // MARK: Review

    public func prepareReview() async {
        let selected = phoneContacts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        let database = self.database
        let userID = await userIDProvider()
        let preparation = await Task.detached(priority: .userInitiated) {
            let existing = (try? ContactRepository(database: database).list(userID: userID)) ?? []
            return ContactImportModel.prepare(selected: selected, existing: existing)
        }.value

        reviewItems = preparation.reviewItems
        skippedInvalidCount = preparation.skippedInvalidCount
        decisions = Dictionary(
            uniqueKeysWithValues: preparation.reviewItems.map { ($0.sourceContactID, $0.defaultDecision) }
        )
        stage = .review
    }

    public func decision(for item: BulkImportReviewItem) -> BulkImportDecision {
        decisions[item.sourceContactID] ?? item.defaultDecision
    }

    public func setDecision(_ decision: BulkImportDecision, for item: BulkImportReviewItem) {
        decisions[item.sourceContactID] = decision
    }

    public var importCount: Int {
        reviewItems.filter { decision(for: $0) == .importAsNew }.count
    }

    // MARK: Execute

    public func runImport() async {
        stage = .importing

        let userID = await userIDProvider()
        let database = self.database
        let toImport = reviewItems.filter { decision(for: $0) == .importAsNew }.map(\.draft)
        let skippedDuplicates = reviewItems.count - toImport.count
        let skippedInvalid = skippedInvalidCount

        let result = await Task.detached(priority: .userInitiated) { () -> BulkImportSummary in
            var summary = BulkImportSummary(
                skippedDuplicateCount: skippedDuplicates,
                skippedInvalidCount: skippedInvalid
            )
            let repository = ContactRepository(database: database)

            // One write per contact, not one transaction for all of them. A
            // single bad row should cost that row, not the other forty-nine —
            // ports the per-contact try/catch in `runBulkContactImport`.
            for draft in toImport {
                do {
                    try repository.upsert(
                        id: ReloraID.new(),
                        userID: userID,
                        name: draft.name,
                        descriptors: draft.descriptors,
                        phoneNumber: draft.phoneNumber,
                        email: draft.email
                    )
                    summary.importedCount += 1
                } catch {
                    summary.failedCount += 1
                }
            }
            return summary
        }.value

        summary = result
    }
}

/// Bring several people over from the phone's address book.
///
/// Two steps, as in RN: choose, then review what Relora thinks it already has.
/// The review step is the whole point — a bulk import that quietly created a
/// second copy of half your contacts would be worse than no import at all.
public struct ContactImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var model: ContactImportViewModel

    public init(
        database: AppDatabase,
        toasts: ReloraToastCenter,
        userIDProvider: @escaping () async -> String
    ) {
        _model = State(
            initialValue: ContactImportViewModel(
                database: database,
                toasts: toasts,
                userIDProvider: userIDProvider
            )
        )
    }

    public var body: some View {
        NavigationStack {
            content
                .background(ReloraColor.background)
                .navigationTitle(model.stage == .review ? "Review" : "Import Contacts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .task { await model.load() }
                .alert(
                    "Import complete",
                    isPresented: Binding(
                        get: { model.summary != nil },
                        set: { if !$0 { dismiss() } }
                    ),
                    presenting: model.summary
                ) { _ in
                    Button("Done") { dismiss() }
                } message: { summary in
                    Text(ContactImportModel.summaryLines(summary).joined(separator: "\n"))
                }
        }
    }

    // MARK: Stages

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading:
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .denied:
            deniedState

        case .select:
            selectList

        case .review:
            reviewList

        case .importing:
            ProgressView("Importing…").controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deniedState: some View {
        ContentUnavailableView {
            Label("Contacts are off", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Relora needs access to your contacts to import them. You can turn it on in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.reloraPrimary)
        }
    }

    @ViewBuilder
    private var selectList: some View {
        @Bindable var model = model

        if model.phoneContacts.isEmpty {
            ContentUnavailableView {
                Label("No contacts to show", systemImage: "person.2")
            } description: {
                // Limited access is the difference between "your address book is
                // empty" and "you chose to share these". Saying so is the only
                // way the user knows there is something to change.
                Text(model.access == .limited
                     ? "You shared only some contacts with Relora. Choose more in Settings to import them."
                     : "There are no contacts on this phone yet.")
            }
        } else {
            List {
                Section {
                    ForEach(model.filteredContacts) { contact in
                        SelectableContactRow(
                            contact: contact,
                            isSelected: model.isSelected(contact.id)
                        ) {
                            model.toggle(contact.id)
                        }
                    }
                } header: {
                    Text("Select up to \(model.maxSelectable) phone contacts to bring into Relora.")
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $model.query, prompt: "Search contacts")
        }
    }

    private var reviewList: some View {
        List {
            if model.skippedInvalidCount > 0 {
                Section {
                    Text("\(model.skippedInvalidCount) selected contacts have no name and cannot be imported.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }

            Section {
                ForEach(model.reviewItems) { item in
                    ReviewRow(
                        item: item,
                        decision: model.decision(for: item)
                    ) { decision in
                        model.setDecision(decision, for: item)
                    }
                }
            } header: {
                Text("Choose what to do with each contact.")
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }

        if model.stage == .select {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") { Task { await model.prepareReview() } }
                    .disabled(model.selectedIDs.isEmpty)
            }
            ToolbarItem(placement: .status) {
                Text(model.selectionLabel)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
            }
        }

        if model.stage == .review {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import \(model.importCount)") { Task { await model.runImport() } }
                    .disabled(model.importCount == 0)
            }
        }
    }
}

// MARK: - Rows

struct SelectableContactRow: View {
    let contact: ImportablePhoneContact
    let isSelected: Bool
    let onToggle: () -> Void

    private var detail: String? {
        let descriptors = ContactImportModel.draft(from: contact).descriptors
        if !descriptors.isEmpty { return descriptors }
        if let phone = contact.phoneNumbers.first { return phone }
        return contact.emails.first
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: ReloraSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                            // Two, like Home's contact rows: one line is a
                            // single word once the text scales up, and the
                            // descriptors are how you tell two people with
                            // the same name apart.
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: ReloraSpacing.sm)
                if isSelected {
                    // The `.isSelected` trait below already says this. Left
                    // audible, VoiceOver reads the row and then "checkmark".
                    Image(systemName: "checkmark")
                        .foregroundStyle(ReloraColor.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, ReloraSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ReviewRow: View {
    let item: BulkImportReviewItem
    let decision: BulkImportDecision
    let onChange: (BulkImportDecision) -> Void

    private var duplicateNote: String? {
        guard let match = item.duplicateMatch, let reason = item.duplicateReason else { return nil }
        return "Possible duplicate via \(reason.phrase) match: \(match.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.draft.name)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)
                if !item.draft.descriptors.isEmpty {
                    Text(item.draft.descriptors.joined(separator: " · "))
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
                if let duplicateNote {
                    Text(duplicateNote)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.accentText)
                }
            }
            .accessibilityElement(children: .combine)

            Picker(
                "What to do with \(item.draft.name)",
                selection: Binding(get: { decision }, set: onChange)
            ) {
                Text("Skip").tag(BulkImportDecision.skip)
                Text("Import as new").tag(BulkImportDecision.importAsNew)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // `labelsHidden` leaves the control with nothing naming the person
            // it decides about — every row's picker would announce alike.
            .accessibilityLabel("What to do with \(item.draft.name)")
        }
        .padding(.vertical, ReloraSpacing.xs)
    }
}
