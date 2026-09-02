import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// Add a reminder for one contact. Ports `AddReminderScreen.tsx` — the one
/// place RN lets someone create a reminder by hand (voice capture can also
/// produce one, out of this milestone). RN has no edit screen for a
/// reminder, so this form has no edit mode either.
///
/// Presented as a sheet from `ContactDetailView`'s toolbar menu, the same
/// slot `contactEdit` uses. A local `.sheet` for the notification pre-prompt
/// nests inside it — precedented by `VoiceContactPickerSheet` inside
/// `VoiceCaptureComposerView` — because the router's one-slot rule is about
/// its own `Sheet` enum, not a ban on a screen presenting its own child
/// sheet.
public struct AddReminderView: View {
    @State private var model: AddReminderViewModel

    private let onCancel: () -> Void

    public init(
        contactID: String,
        contactName: String,
        database: AppDatabase,
        notifications: NotificationEnvironment,
        userIDProvider: @escaping () async -> String,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        _model = State(
            initialValue: AddReminderViewModel(
                contactID: contactID,
                contactName: contactName,
                database: database,
                notifications: notifications,
                userIDProvider: userIDProvider,
                onSaved: onSaved
            )
        )
        self.onCancel = onCancel
    }

    public var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    TextField("Reminder title", text: $model.draft.title)
                } footer: {
                    Text("For \(model.contactName).")
                }

                Section {
                    DatePicker(
                        "Reminder time",
                        selection: $model.draft.remindAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ReloraColor.background)
            .navigationTitle("Add Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "Saving…" : "Save") {
                        model.save()
                    }
                    .disabled(!AddReminderForm.canSave(title: model.draft.title) || model.isSaving)
                    // The visible text reports progress; the label stays put,
                    // so the control does not appear to rename itself
                    // mid-action. Same rule as the voice composer's save bar.
                    .accessibilityLabel("Save")
                }
            }
        }
        .sheet(isPresented: $model.showingPriming) {
            ReminderNotificationPrimingSheet(
                onAllow: { model.respondToPrimingAllow() },
                onNotNow: { model.respondToPrimingDecline() }
            )
        }
    }
}
