import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// What Home's bell opens: every active reminder, bucketed Overdue / Upcoming
/// / Done. Ports `RemindersScreen.tsx`.
public struct RemindersView: View {
    @Environment(AppRouter.self) private var router
    @Environment(IdentityController.self) private var identity
    @Environment(SyncOrchestrator.self) private var sync

    @State private var model: RemindersViewModel

    public init(database: AppDatabase, identity: IdentityController, toasts: ReloraToastCenter, hooks: ReminderNotificationHooks) {
        _model = State(initialValue: RemindersViewModel(database: database, identity: identity, toasts: toasts, hooks: hooks))
    }

    public var body: some View {
        content
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.large)
            .background(ReloraColor.background)
            // Same contract as Home's: pull the server, then show the freshest
            // local truth whether or not the sync landed. A list Home can
            // refresh and this one cannot is a difference the user has to
            // discover by failing.
            .refreshable {
                await sync.sync(reason: "pull-to-refresh")
                model.reload()
            }
            .task { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: identity.identity) { _, _ in model.identityChanged() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isSignedOut {
            ReloraEmptyState.signedOut { router.present(.authGate) }
        } else if model.sections.isEmpty {
            ContentUnavailableView {
                Label("No reminders yet", systemImage: "bell")
            } description: {
                Text("Add a reminder from a contact and it will show up here until you mark it done.")
            }
            .background(ReloraColor.background)
        } else {
            List {
                ForEach(model.sections) { section in
                    Section(section.bucket.title) {
                        ForEach(section.rows) { row in
                            ReminderRowView(row: row)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        model.delete(row.reminder)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if row.reminder.status == .scheduled {
                                        Button {
                                            model.complete(row.reminder)
                                        } label: {
                                            Label("Done", systemImage: "checkmark")
                                        }
                                        .tint(ReloraColor.success)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// A row that pushes the contact, so it is the same `NavigationLink` Home's
/// `ContactRowLink` uses rather than a plain button. The difference is visible:
/// a link draws the disclosure chevron that tells the user the row goes
/// somewhere, and a tappable list row without one is the tell that this list
/// was drawn rather than built.
private struct ReminderRowView: View {
    let row: ReminderRow

    var body: some View {
        NavigationLink(value: AppRouter.Route.contactDetail(contactID: row.reminder.contactID)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.reminder.title)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)
                Text(row.metaLine)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                if let overdueNote = row.overdueNote {
                    Text(overdueNote)
                        .font(ReloraFont.footnote)
                        // Overdue is stated in words as well as coloured, so
                        // the red is confirmation and never the only signal.
                        .foregroundStyle(ReloraColor.danger)
                }
            }
            .padding(.vertical, ReloraSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the contact's details")
    }
}
