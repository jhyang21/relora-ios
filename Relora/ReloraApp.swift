import SwiftUI
import ReloraDesign
import ReloraFeatures

@main
struct ReloraApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let bootstrap: AppBootstrap?
    private let launchFailure: String?

    /// Covers the whole window whenever the scene is not active, so the
    /// snapshot iOS takes for the app switcher shows the app's background
    /// and nothing else. Notes are the entire content of this app; the
    /// switcher is the one place they get shown without anyone asking.
    @State private var isCovered = false

    init() {
        do {
            bootstrap = try AppBootstrap()
            launchFailure = nil
        } catch {
            // Opening the database is the one thing that must work before there
            // is an app. Failing visibly beats an empty screen nobody can
            // explain — see `LaunchFailureView`.
            bootstrap = nil
            launchFailure = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let bootstrap {
                RootView(database: bootstrap.database, voice: bootstrap.voice, notifications: bootstrap.notifications, billing: bootstrap.billing)
                    .environment(bootstrap.router)
                    .environment(bootstrap.identity)
                    .environment(bootstrap.sync)
                    .environment(bootstrap.toasts)
                    .task { await bootstrap.start() }
                    .overlay {
                        if isCovered {
                            ReloraColor.background
                                .ignoresSafeArea()
                                .accessibilityHidden(true)
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // No animation on the way in: the snapshot is taken
                        // during `.inactive`, and a fading cover would be
                        // caught half-drawn.
                        isCovered = phase != .active
                        // Coming back to the foreground is one of the three
                        // moments a sync runs (the others: an identity arriving,
                        // and a pull-to-refresh).
                        if phase == .active { bootstrap.enterForeground() }
                    }
            } else {
                LaunchFailureView(message: launchFailure ?? "Relora could not start.")
            }
        }
    }
}

/// Shown when the local database cannot be opened.
///
/// Rare, and unrecoverable from inside the app: there is nothing to retry that
/// launching again would not do better. It says what happened and stops there,
/// rather than offering a button that cannot help.
struct LaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Relora could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .background(ReloraColor.background)
    }
}
