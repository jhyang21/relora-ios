import SwiftUI
import ReloraData
import ReloraDesign
import ReloraServices

/// "Your People" — the hub.
///
/// ## What changed from RN, and why
///
/// - **One floating action.** RN floated a coral button that expanded into a
///   speed dial. Voice Memos floats one button; so does this. "Add contact"
///   moved to the toolbar `+`, where a second, rarer action belongs.
/// - **Native search.** `.searchable` replaces a hand-built search bar, so the
///   keyboard, the cancel button, the scroll-to-reveal behaviour and the
///   VoiceOver rotor all come for free.
/// - **`ContentUnavailableView` for every empty state**, including the system's
///   own no-results view for search.
///
/// ## While signed out
///
/// Home renders with no identity — that is the state a sign-out lands in, and
/// restarting onboarding from there was the bug this rebuild fixes. Nothing here
/// reads `identity.ownerUserID`, which traps when unresolved; `HomeViewModel`
/// gates every read behind an optional user id and every write behind
/// `prepareForWrite()`.
public struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(IdentityController.self) private var identity
    @Environment(SyncOrchestrator.self) private var sync

    @State private var model: HomeViewModel

    public init(database: AppDatabase, identity: IdentityController) {
        _model = State(initialValue: HomeViewModel(database: database, identity: identity))
    }

    private var banner: HomeBanner? {
        HomeBannerState.banner(
            ownershipMigrationPending: identity.ownershipMigrationPending,
            isOnline: sync.isOnline,
            syncStatus: sync.status
        )
    }

    public var body: some View {
        @Bindable var model = model

        content
            .navigationTitle("Your People")
            .navigationBarTitleDisplayMode(.large)
            .background(ReloraColor.background)
            .searchable(
                text: $model.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search name, descriptors, key things"
            )
            .refreshable {
                await sync.sync(reason: "pull-to-refresh")
                // Always reload, sync or no sync. Ports `runPullToRefresh`: the
                // gesture's job is to show the freshest local truth, and the
                // banner is the only place a sync failure is reported.
                model.reload()
            }
            .toolbar { toolbarContent }
            .reloraFloatingActions {
                ReloraRecordButton {
                    Task {
                        _ = await model.prepareForWrite()
                        router.present(.voiceComposer(contactID: nil))
                    }
                }
            }
            .task { model.start() }
            .onChange(of: identity.identity) { _, _ in model.identityChanged() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isSignedOut {
            ReloraEmptyState.signedOut { router.present(.authGate) }
        } else if model.isSearching {
            searchContent
        } else if model.snapshot.sections.isEmpty && !model.snapshot.hasAnyContacts {
            ReloraEmptyState.firstRun { router.present(.contactEdit(.new(prefill: nil))) }
        } else {
            restingList
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if let section = model.searchSection, !section.rows.isEmpty {
            List {
                bannerRow
                Section(section.title) {
                    ForEach(section.rows) { row in
                        ContactRowLink(row: row)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else if model.searchPending || model.searchSection == nil {
            // Nothing at all while a query is in flight. RN is explicit about
            // this: flashing "no matches" between keystrokes reads as a wrong
            // answer arriving before the right one.
            Color.clear
        } else {
            ReloraEmptyState.noSearchResults(query: model.searchQuery)
        }
    }

    private var restingList: some View {
        List {
            bannerRow

            if let card = model.snapshot.contextCard {
                Section {
                    ContextCardView(
                        content: card,
                        contactName: model.snapshot.contextCardContactName
                    ) {
                        router.openContact(card.contactID)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(model.snapshot.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        ContactRowLink(row: row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var bannerRow: some View {
        if let banner {
            ReloraBanner(
                tone: banner.tone == .system ? .system : .warning,
                title: banner.title,
                message: banner.message,
                onRetry: banner.isRetryable ? { retry(banner) } : nil
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func retry(_ banner: HomeBanner) {
        switch banner {
        case .migrationPending:
            Task { await identity.retryOwnershipMigration() }
        case .syncFailed:
            sync.requestSync(reason: "banner-retry")
        case .offline:
            break
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                router.present(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }

        ToolbarItem(placement: .topBarTrailing) {
            RemindersBellButton(count: model.snapshot.overdueReminderCount) {
                router.openReminders()
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    router.present(.contactEdit(.new(prefill: nil)))
                } label: {
                    Label("New Contact", systemImage: "person.badge.plus")
                }
                Button {
                    router.present(.contactImport)
                } label: {
                    Label("Import from Phone", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add a contact")
        }
    }
}

// MARK: - Rows

struct ContactRowLink: View {
    let row: HomeContactRow

    var body: some View {
        NavigationLink(value: AppRouter.Route.contactDetail(contactID: row.contact.id)) {
            HStack(spacing: ReloraSpacing.md) {
                ReloraAvatar(name: row.contact.name)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.contact.name)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.ink)
                    if let subtitle = row.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, ReloraSpacing.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens the contact's details")
    }
}

/// The bell, with its overdue count.
struct RemindersBellButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if let text = ReminderBadge.badgeText(count) {
                        Text(text)
                            // Deliberately unscaled, like the system's own
                            // badges: it is pinned to a fixed-size toolbar
                            // glyph and would grow off the bar. Nothing is
                            // lost — the count is spoken in full by the
                            // button's accessibility label below.
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ReloraColor.onAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(ReloraColor.accent))
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .accessibilityLabel(ReminderBadge.accessibilityLabel(count))
    }
}

// MARK: - Context card

/// The glance-before-a-conversation card.
///
/// Reads its own `contactID` from the content it was handed, never from a
/// separate piece of state. RN carried the same pairing for the same reason:
/// the one thing this card must never do is put one person's notes under
/// another person's name.
struct ContextCardView: View {
    let content: ContextCardContent
    let contactName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                Text(contactName)
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)

                if let nextReminder = content.nextReminder {
                    Label(nextReminder, systemImage: "bell")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.accentText)
                }

                ForEach(content.highlights, id: \.self) { highlight in
                    HStack(alignment: .firstTextBaseline, spacing: ReloraSpacing.xs) {
                        // VoiceOver says "bullet" out loud otherwise, once per
                        // highlight, inside a card that is read as one phrase.
                        Text("•")
                            .accessibilityHidden(true)
                        Text(highlight)
                    }
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)
                }

                if let snippet = content.memorySnippet {
                    Text(snippet)
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ReloraSpacing.md)
            .reloraSurface(ReloraColor.warmCard, radius: ReloraRadius.lg)
            .reloraBorder(radius: ReloraRadius.lg)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(contactName)'s details")
    }
}
