import SwiftUI
import UIKit
import ReloraData
import ReloraDesign
import ReloraServices

/// Everything about this install and this account, in one native `Form`.
///
/// Rows are single lines: a title, and a value or a control on the right.
/// The explanation a row needs goes in its section footer rather than
/// under the title, so no row grows a paragraph and the eye can run down
/// one column of titles.
///
/// Sub-screens (paywall, sign-in, contact import, the export share sheet)
/// open as a sheet owned here, not through the router. Closing one comes
/// back to Settings, which is the only sensible place to land.
public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteRecordingsConfirm = false

    private let database: AppDatabase
    private let identity: IdentityController
    private let billing: BillingService
    private let toasts: ReloraToastCenter
    private let userIDProvider: () async -> String
    private let router: AppRouter

    public init(
        database: AppDatabase,
        identity: IdentityController,
        sync: SyncOrchestrator,
        billing: BillingService,
        voiceAccess: any VoiceAccessProviding,
        notifications: NotificationEnvironment,
        toasts: ReloraToastCenter,
        userIDProvider: @escaping () async -> String,
        router: AppRouter
    ) {
        _viewModel = State(wrappedValue: SettingsViewModel(
            database: database,
            identity: identity,
            sync: sync,
            billing: billing,
            voiceAccess: voiceAccess,
            notifications: notifications,
            toasts: toasts,
            router: router
        ))
        self.database = database
        self.identity = identity
        self.billing = billing
        self.toasts = toasts
        self.userIDProvider = userIDProvider
        self.router = router
    }

    public var body: some View {
        NavigationStack {
            Form {
                accountSection
                subscriptionSection
                notificationsSection
                voiceSection
                dataSection
                supportSection
                if viewModel.isAccount {
                    signOutSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            // Button rows read their color from here. Setting
            // `foregroundStyle` on a row instead would also paint it while
            // disabled, which is the one time it must not.
            .tint(ReloraColor.accentText)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { router.dismissSheet() }
                }
            }
        }
        .task { await viewModel.load() }
        .alert("Notifications Are Off", isPresented: $viewModel.showNotificationPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Turn on notifications for Relora to get reminder alerts.")
        }
        .confirmationDialog(
            SettingsConfirmation.signOut.title,
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button(SettingsConfirmation.signOut.confirmLabel, role: .destructive) {
                Task { await viewModel.confirmSignOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsConfirmation.signOut.message)
        }
        .confirmationDialog(
            SettingsConfirmation.deleteAccount.title,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(SettingsConfirmation.deleteAccount.confirmLabel, role: .destructive) {
                Task { await viewModel.confirmDeleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsConfirmation.deleteAccount.message)
        }
        .confirmationDialog(
            SettingsConfirmation.deleteAllRecordings.title,
            isPresented: $showDeleteRecordingsConfirm,
            titleVisibility: .visible
        ) {
            Button(SettingsConfirmation.deleteAllRecordings.confirmLabel, role: .destructive) {
                Task { await viewModel.deleteAllRecordings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsConfirmation.deleteAllRecordings.message)
        }
        .sheet(item: $viewModel.presentedSheet, onDismiss: { Task { await viewModel.load() } }) { sheet in
            sheetView(sheet)
        }
    }

    // MARK: - Sub-screens

    @ViewBuilder
    private func sheetView(_ sheet: SettingsSheet) -> some View {
        switch sheet {
        case .paywall(let reason):
            PaywallView(reason: reason, billing: billing, identity: identity, toasts: toasts)

        case .authGate(let context):
            AuthGateView(context: context, identity: identity, toasts: toasts)

        case .contactImport:
            ContactImportView(database: database, toasts: toasts, userIDProvider: userIDProvider)

        case .export(let url):
            ExportShareSheet(fileURL: url)
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if viewModel.isAccount {
            Section {
                Label {
                    Text(viewModel.accountEmail ?? "Signed in")
                        .font(ReloraFont.listBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(ReloraColor.mutedInk)
                }

                actionRow("Sync Now", running: viewModel.syncing) {
                    Task { await viewModel.syncNow() }
                }
                .accessibilityValue(Text(viewModel.syncing ? "Syncing" : ""))
            } footer: {
                footerText(viewModel.syncFooter)
            }
            .listRowBackground(ReloraColor.card)
        } else {
            Section {
                actionRow("Create Account or Sign In") { viewModel.openAccountAuth() }
            } footer: {
                footerText("Your notes are only on this iPhone until you create an account.")
            }
            .listRowBackground(ReloraColor.card)
        }
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        Section {
            LabeledContent {
                Text(viewModel.planName)
                    .font(ReloraFont.listBody)
                    .foregroundStyle(ReloraColor.mutedInk)
            } label: {
                Text("Plan").font(ReloraFont.listBody)
            }

            if viewModel.showsSeePlans {
                actionRow("See Plans") { viewModel.openUpgrade() }
            }

            if viewModel.showsManageSubscription {
                linkRow("Manage Subscription", hint: "Opens the App Store") {
                    open(
                        SettingsLegal.manageSubscriptionsURL,
                        failureTitle: "Could not open subscriptions",
                        failureFallback: "Manage your subscription in Settings, under your Apple Account."
                    )
                }
            }

            actionRow("Restore Purchases", running: viewModel.restoring) {
                Task { await viewModel.restorePurchases() }
            }
        } header: {
            headerText("Subscription")
        } footer: {
            footerText(viewModel.usageFooter)
        }
        .listRowBackground(ReloraColor.card)
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Reminder Notifications", isOn: reminderNotificationsBinding)
                .font(ReloraFont.listBody)
                .tint(ReloraColor.accent)
                .disabled(viewModel.togglingReminders)
        } header: {
            headerText("Notifications")
        } footer: {
            footerText("Get a notification when a reminder is due.")
        }
        .listRowBackground(ReloraColor.card)
    }

    private var reminderNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.reminderNotificationsEnabled },
            set: { value in Task { await viewModel.toggleReminderNotifications(value) } }
        )
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Toggle("Save Transcripts", isOn: saveTranscriptsBinding)
                .font(ReloraFont.listBody)
                .tint(ReloraColor.accent)

            LabeledContent {
                Text(viewModel.recordingsValue)
                    .font(ReloraFont.listBody)
                    .foregroundStyle(ReloraColor.mutedInk)
            } label: {
                Text("Recordings").font(ReloraFont.listBody)
            }

            actionRow(
                "Delete All Recordings",
                running: viewModel.deletingRecordings,
                role: .destructive
            ) {
                showDeleteRecordingsConfirm = true
            }
            .disabled(viewModel.recordingsCount == 0)
            .accessibilityHint("Stops replay for saved voice notes. Notes and transcripts stay.")
            .accessibilityValue(Text(viewModel.deletingRecordings ? "Deleting" : ""))
        } header: {
            headerText("Voice")
        } footer: {
            footerText(SettingsVoiceCopy.footer)
        }
        .listRowBackground(ReloraColor.card)
    }

    private var saveTranscriptsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.saveVoiceTranscriptsEnabled },
            set: { value in Task { await viewModel.toggleSaveVoiceTranscripts(value) } }
        )
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            actionRow("Import from Contacts") { viewModel.openContactImport() }

            if viewModel.canExport {
                actionRow("Export Data") { viewModel.exportData() }
            }
        } header: {
            headerText("Data")
        } footer: {
            if viewModel.canExport {
                footerText("Export creates a JSON file of everything stored on this iPhone.")
            }
        }
        .listRowBackground(ReloraColor.card)
    }

    // MARK: - Support

    private var supportSection: some View {
        Section {
            linkRow("Contact Support", hint: "Opens Mail", action: openSupportEmail)

            linkRow("Terms of Use", hint: "Opens in Safari") {
                open(
                    SettingsLegal.termsOfUseURL,
                    failureTitle: "Could not open terms of use",
                    failureFallback: "Open \(SettingsLegal.termsOfUseURL.absoluteString) in your browser."
                )
            }

            linkRow("Privacy Policy", hint: "Opens in Safari") {
                open(
                    SettingsLegal.privacyPolicyURL,
                    failureTitle: "Could not open privacy policy",
                    failureFallback: "Open \(SettingsLegal.privacyPolicyURL.absoluteString) in your browser."
                )
            }

            LabeledContent {
                Text(Self.versionLabel)
                    .font(ReloraFont.listBody)
                    .foregroundStyle(ReloraColor.mutedInk)
            } label: {
                Text("Version").font(ReloraFont.listBody)
            }
        } header: {
            headerText("Support")
        }
        .listRowBackground(ReloraColor.card)
    }

    private func openSupportEmail() {
        let context = SettingsLegal.SupportEmailContext(
            appName: Self.appName,
            appVersion: Self.rawAppVersion,
            platform: "iOS",
            signedIn: viewModel.isAccount
        )
        guard let url = SettingsLegal.supportEmailURL(context) else { return }
        open(url, failureTitle: "Could not open mail app", failureFallback: "Email \(SettingsLegal.supportEmail) for support.")
    }

    private func open(_ url: URL, failureTitle: String, failureFallback: String) {
        openURL(url) { accepted in
            guard !accepted else { return }
            Task { @MainActor in
                viewModel.reportLinkOpenFailure(failureTitle, failureFallback)
            }
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        Section {
            actionRow("Sign Out") { showSignOutConfirm = true }

            actionRow("Delete Account", running: viewModel.deletingAccount, role: .destructive) {
                showDeleteConfirm = true
            }
        } footer: {
            footerText("Deleting your account removes everything synced to it and every note on this iPhone.")
        }
        .listRowBackground(ReloraColor.card)
    }

    // MARK: - Row helpers

    private func actionRow(
        _ title: String,
        running: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(title).font(ReloraFont.listBody)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(running)
    }

    private func linkRow(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(ReloraFont.listBody)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .imageScale(.small)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint(hint)
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.mutedInk)
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(ReloraFont.footnote)
            .foregroundStyle(ReloraColor.mutedInk)
    }

    // MARK: - Bundle

    private static func infoString(_ key: String) -> String {
        let value = (Bundle.main.infoDictionary?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : "unknown"
    }

    private static var rawAppVersion: String {
        infoString("CFBundleShortVersionString")
    }

    private static var versionLabel: String {
        "\(rawAppVersion) (\(infoString("CFBundleVersion")))"
    }

    private static var appName: String {
        let name = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Relora" : trimmed
    }
}
