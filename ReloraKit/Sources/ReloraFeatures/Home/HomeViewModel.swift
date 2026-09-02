import Foundation
import Observation
import ReloraCore
import ReloraData
import ReloraServices

/// Everything Home draws, computed in one pass off the main actor.
///
/// One value rather than five published properties, so a render can never mix
/// the sections from one load with the context card from another.
public struct HomeSnapshot: Equatable, Sendable {
    public var sections: [HomeSection] = []
    public var contextCard: ContextCardContent?
    public var contextCardContactName: String = ""
    public var overdueReminderCount: Int = 0
    public var hasAnyContacts: Bool = false
}

/// The database side of Home, kept `Sendable` and free of view state so it can
/// run on a background task. Every read goes through a repository.
struct HomeDataLoader: Sendable {
    let database: AppDatabase

    func load(userID: String, nowISO: String) throws -> HomeSnapshot {
        let contacts = try ContactRepository(database: database).list(userID: userID)
        let reminders = try ReminderRepository(database: database).listByUser(userID: userID)

        let ranked = HomeRanking.dedupeHomeSections(
            recent: HomeRanking.rankRecent(contacts, nowISO: nowISO),
            upcoming: HomeRanking.rankUpcoming(contacts, reminders: reminders, nowISO: nowISO),
            reconnect: HomeRanking.rankReconnect(contacts, nowISO: nowISO)
        )

        var snapshot = HomeSnapshot(
            sections: HomeListModel.sections(from: ranked, nowISO: nowISO),
            overdueReminderCount: ReminderBadge.overdueCount(reminders, nowISO: nowISO),
            hasAnyContacts: !contacts.isEmpty
        )

        // Ports the selection in HomeScreen.tsx: the person a reminder is about
        // to fire for, else the person last spoken to, else anyone. The context
        // card is a glance before a conversation, so it guesses at which
        // conversation is next.
        if let subject = ranked.upcoming.first?.contact ?? ranked.recent.first ?? contacts.first {
            snapshot.contextCardContactName = subject.name
            snapshot.contextCard = ContextCardModel.build(
                contactID: subject.id,
                keyThings: try KeyThingRepository(database: database).list(contactID: subject.id),
                memories: try MemoryRepository(database: database).list(contactID: subject.id),
                reminders: try ReminderRepository(database: database).list(contactID: subject.id),
                limit: ContextCardModel.homeHighlightLimit,
                nowISO: nowISO
            )
        }

        return snapshot
    }

    func search(userID: String, query: String, nowISO: String) throws -> HomeSection {
        let ids = try ContactSearchIndex.searchContactIDs(database, query: query)
        let contacts = try ContactRepository(database: database).getContactsByIDs(ids, userID: userID)
        let snippets = (try? ContactSearchIndex.matchSnippets(
            database,
            contactIDs: contacts.map(\.id),
            query: query
        )) ?? [:]

        return HomeListModel.searchSection(results: contacts, snippets: snippets, nowISO: nowISO)
    }
}

/// Home's state.
///
/// ## Reading identity
///
/// `ownerUserID` **precondition-fails on `.unresolved`**. Home is rendered while
/// unresolved — that is exactly what the signed-out state is — so nothing here
/// touches it without going through `activeUserID`, which returns `nil` instead
/// of trapping. Any action that would create data calls `prepareForWrite()`
/// first, which mints the local guest identity the new row needs an owner from.
/// See `docs/milestone-notes.md`, "Identity rulings from the M3 review".
@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var snapshot = HomeSnapshot()
    public private(set) var searchSection: HomeSection?
    /// A search is typed but its results have not landed. Home shows nothing
    /// while this is true and there is no result yet — flashing "no matches"
    /// between keystrokes is worse than a blank moment.
    public private(set) var searchPending = false
    public var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleSearch()
        }
    }

    public var isSearching: Bool {
        !searchQuery.trimmed.isEmpty
    }

    /// True when there is no identity to read data for.
    public var isSignedOut: Bool {
        activeUserID == nil
    }

    @ObservationIgnored private let loader: HomeDataLoader
    @ObservationIgnored private let identity: IdentityController
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// 150ms, ported from `homeSearchController.ts`. Short enough that the list
    /// feels attached to the keyboard, long enough that a fast typist does not
    /// run one FTS query per letter.
    private static let searchDebounce = Duration.milliseconds(150)

    public init(database: AppDatabase, identity: IdentityController) {
        self.loader = HomeDataLoader(database: database)
        self.identity = identity
    }

    private var activeUserID: String? {
        if case .unresolved = identity.identity { return nil }
        return identity.identity.ownerUserID
    }

    // MARK: Lifecycle

    public func start() {
        guard observationTask == nil else { return }
        let changes = loader.database.observeContentChanges()
        observationTask = Task { [weak self] in
            for await _ in changes {
                self?.reload()
            }
        }
        reload()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        loadTask?.cancel()
        searchTask?.cancel()
    }

    /// Call when identity changes. Signing in and signing out both change which
    /// rows belong to this screen, and neither is a database write, so the
    /// content observation will not notice on its own.
    public func identityChanged() {
        reload()
        if isSearching {
            scheduleSearch()
        }
    }

    // MARK: Loading

    public func reload() {
        loadTask?.cancel()

        guard let userID = activeUserID else {
            snapshot = HomeSnapshot()
            searchSection = nil
            return
        }

        let loader = self.loader
        let nowISO = ReloraTimestamp.now()
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                try? loader.load(userID: userID, nowISO: nowISO)
            }.value

            guard !Task.isCancelled, let loaded else { return }
            self?.snapshot = loaded
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        // Cancelled on the keystroke, not when the timer next fires: an
        // in-flight query for "ann" must stop being able to land after the user
        // has typed "anna", or the older result overwrites the newer one.
        searchTask?.cancel()

        let query = searchQuery.trimmed
        guard !query.isEmpty else {
            searchPending = false
            searchSection = nil
            return
        }

        guard let userID = activeUserID else {
            searchPending = false
            searchSection = nil
            return
        }

        searchPending = true
        let loader = self.loader
        let nowISO = ReloraTimestamp.now()

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }

            let section = await Task.detached(priority: .userInitiated) {
                try? loader.search(userID: userID, query: query, nowISO: nowISO)
            }.value

            guard !Task.isCancelled else { return }
            self?.searchSection = section
            self?.searchPending = false
        }
    }

    // MARK: Writes

    /// Returns the user id a new row should belong to, minting a local guest
    /// identity first if there is none.
    ///
    /// Every data-creating action on this screen goes through here. Bootstrap is
    /// lazy by design — a fresh install that never finishes onboarding owns
    /// nothing — so identity appears at the moment something needs an owner.
    public func prepareForWrite() async -> String {
        if let userID = activeUserID {
            return userID
        }
        return await identity.ensureLocalGuestSession()
    }
}
