import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// Ports `SettingsScreen.tsx`. A native `Form`/`Section` layout rather than
/// RN's hand-styled cards — `AddReminderView` already sets that idiom for a
/// settings-shaped screen in this codebase, and `Form` gets the
/// grouped-list chrome, dividers, and safe-area handling RN builds by hand,
/// for free.
///
/// Contacts' bulk-import row does not reproduce RN's five-state permission
/// copy (`loading`/`unavailable`/`undetermined`/`denied`/`granted`): the
/// `.contactImport` sheet (`ContactImportView`, M?) already requests and
/// reports `CNContactStore` access itself once opened, so this is a single
/// entry point into it rather than a second permission state machine kept
/// in sync with the first.
public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false

    /// Read for one decision only: whether `actionRow` still fits a label and
    /// a button side by side. See the note there.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let router: AppRouter

    public init(
        database: AppDatabase,
        identity: IdentityController,
        sync: SyncOrchestrator,
        billing: BillingService,
        voiceAccess: any VoiceAccessProviding,
        notifications: NotificationEnvironment,
        toasts: ReloraToastCenter,
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
        self.router = router
    }

    public var body: some View {
        NavigationStack {
            Form {
                contactsSection
                remindersSection
                voicePrivacySection
                supportLegalSection
                syncDataSection
                planSection
                accountSection

                Section {
                    HStack {
                        Spacer()
                        Text(Self.appVersionLabel)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { router.dismissSheet() }
                }
            }
        }
        .task { await viewModel.load() }
        .alert("Notifications permission needed", isPresented: $viewModel.showNotificationPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications to turn reminder notifications on.")
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
        .sheet(isPresented: exportSheetBinding) {
            if let exportedFileURL = viewModel.exportedFileURL {
                ExportShareSheet(fileURL: exportedFileURL)
            }
        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.exportedFileURL != nil },
            set: { isPresented in if !isPresented { viewModel.clearExportedFile() } }
        )
    }

    // MARK: - Contacts

    private var contactsSection: some View {
        Section("Contacts") {
            actionRow(
                title: "Bulk import from phone",
                description: "Choose contacts from your phone to import into Relora.",
                actionLabel: "Import contacts",
                action: viewModel.openContactImport
            )
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        Section("Reminders") {
            Toggle(isOn: reminderNotificationsBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reminder notifications").font(ReloraFont.body).foregroundStyle(ReloraColor.ink)
                    Text("Schedule local notifications for future reminders when this is on.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }
            .disabled(viewModel.activeSetting != nil)
            .tint(ReloraColor.accent)
        }
    }

    private var reminderNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.reminderNotificationsEnabled },
            set: { value in Task { await viewModel.toggleReminderNotifications(value) } }
        )
    }

    // MARK: - Voice & Privacy

    private var voicePrivacySection: some View {
        Section {
            Toggle(isOn: saveTranscriptsBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save voice transcripts").font(ReloraFont.body).foregroundStyle(ReloraColor.ink)
                    Text("Keep the transcript text in saved voice memories for future context.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }
            .disabled(viewModel.activeSetting != nil)
            .tint(ReloraColor.accent)

            Text("Voice recordings are sent through Relora's backend to OpenAI for transcription and transcript-based extraction. Relora does not retain raw audio after processing. Saved transcript text is optional and controlled by this setting.")
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
        } header: {
            Text("Voice & Privacy")
        }
    }

    private var saveTranscriptsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.saveVoiceTranscriptsEnabled },
            set: { value in Task { await viewModel.toggleSaveVoiceTranscripts(value) } }
        )
    }

    // MARK: - Support & Legal

    private var supportLegalSection: some View {
        Section("Support & Legal") {
            actionRow(
                title: "Terms of Use",
                description: "Review the terms that govern use of Relora and its paid plans.",
                actionLabel: "Open",
                spokenActionLabel: "Open Terms of Use",
                action: { open(SettingsLegal.termsOfUseURL, failureTitle: "Could not open terms of use", failureFallback: "Open \(SettingsLegal.termsOfUseURL.absoluteString) in your browser.") }
            )
            actionRow(
                title: "Privacy Policy",
                description: "See how Relora collects, uses, shares, and deletes your information.",
                actionLabel: "Open",
                spokenActionLabel: "Open Privacy Policy",
                action: { open(SettingsLegal.privacyPolicyURL, failureTitle: "Could not open privacy policy", failureFallback: "Open \(SettingsLegal.privacyPolicyURL.absoluteString) in your browser.") }
            )
            actionRow(
                title: "Contact Support",
                description: "Email \(SettingsLegal.supportEmail) for help with Relora, billing, or privacy requests.",
                actionLabel: "Email",
                spokenActionLabel: "Email support",
                action: openSupportEmail
            )
        }
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

    // MARK: - Sync & Data

    private var syncDataSection: some View {
        Section("Sync & Data") {
            if viewModel.isAccount {
                actionRow(
                    title: "Sync now",
                    description: viewModel.syncStatusLabel,
                    actionLabel: viewModel.syncing ? "Syncing..." : "Sync now",
                    disabled: viewModel.syncing,
                    action: { Task { await viewModel.syncNow() } }
                )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync").font(ReloraFont.body).foregroundStyle(ReloraColor.ink)
                    Text("Nothing is backed up yet. Syncing starts when you create an account.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }
            }

            actionRow(
                title: "Export data",
                description: "Export your local Relora data as a JSON file.",
                actionLabel: "Export JSON",
                action: viewModel.exportData
            )
        }
    }

    // MARK: - Plan

    private var planSection: some View {
        Section("Plan") {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.planSummary.title).font(ReloraFont.body).foregroundStyle(ReloraColor.ink)
                Text(viewModel.planSummary.description).font(ReloraFont.footnote).foregroundStyle(ReloraColor.mutedInk)
            }

            if viewModel.planID != .pro {
                actionRow(
                    title: "Upgrade your plan",
                    description: "Unlock more notes, longer captures, and smarter organization.",
                    actionLabel: "See plans",
                    action: viewModel.openUpgrade
                )
            }

            actionRow(
                title: "Restore purchases",
                description: viewModel.isAccount
                    ? "Already subscribed? Bring back a purchase made with your App Store account."
                    : "Sign in to restore a purchase made with your App Store account.",
                actionLabel: viewModel.isAccount ? (viewModel.restoring ? "Restoring..." : "Restore") : "Sign in",
                disabled: viewModel.restoring,
                action: { Task { await viewModel.restorePurchases() } }
            )

            Text("Manage or cancel anytime in your App Store subscription settings.")
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if viewModel.isAccount {
            Section("Account") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed in").font(ReloraFont.body).foregroundStyle(ReloraColor.ink)
                    Text(viewModel.accountEmail ?? "You are signed in to a Relora account.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)
                }

                actionRow(
                    title: "Sign out",
                    description: "Stops syncing on this device and hides your notes until you sign back in. Nothing is deleted.",
                    actionLabel: "Sign out",
                    action: { showSignOutConfirm = true }
                )

                actionRow(
                    title: "Delete account and data",
                    description: "Permanently deletes your account, everything synced to it, and every note stored on this device. This cannot be undone.",
                    actionLabel: viewModel.deletingAccount ? "Deleting..." : "Delete",
                    danger: true,
                    disabled: viewModel.deletingAccount,
                    action: { showDeleteConfirm = true }
                )
            }
        } else {
            Section("Account") {
                actionRow(
                    title: "Back up your notes",
                    description: "Your notes live only on this phone. If you lose it or delete the app, they're gone. Create an account to back them up, or sign in if you already have one.",
                    actionLabel: "Create account",
                    action: viewModel.openAccountAuth
                )
            }
        }
    }

    // MARK: - Row helpers

    // Not `@ViewBuilder`: the body builds its two halves as locals and returns
    // one arrangement of them, and a result builder is skipped the moment a
    // body returns explicitly anyway.
    private func actionRow(
        title: String,
        description: String,
        actionLabel: String,
        // Spoken name for the button when `actionLabel` alone is ambiguous.
        // VoiceOver can land on the button without ever reading the title
        // beside it, and two rows that both offer "Open" are identical there.
        spokenActionLabel: String? = nil,
        danger: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ReloraFont.body)
                .foregroundStyle(danger ? ReloraColor.danger : ReloraColor.ink)
            Text(description)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
        }
        .accessibilityElement(children: .combine)

        let button = Button(actionLabel, action: action)
            .buttonStyle(.bordered)
            .tint(danger ? ReloraColor.danger : ReloraColor.accent)
            .disabled(disabled)
            .accessibilityLabel(spokenActionLabel ?? actionLabel)

        // Side by side until the text stops leaving room for it. "Delete
        // account and data" beside a "Deleting..." button squeezes both into
        // a column of syllables at accessibility sizes, so past that
        // threshold the button drops below the text and takes the full width.
        //
        // Chosen over `ViewThatFits` on purpose: these labels wrap, so the
        // horizontal arrangement technically "fits" at any size — it just
        // fits badly, which is the one thing `ViewThatFits` cannot see.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                    label
                    button
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: ReloraSpacing.md) {
                    label
                    Spacer()
                    button
                }
            }
        }
    }

    private static var rawAppVersion: String {
        let value = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : "unknown"
    }

    private static var appVersionLabel: String {
        "Relora v\(rawAppVersion)"
    }

    private static var appName: String {
        let name = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Relora" : trimmed
    }
}
