import ContactsUI
import SwiftUI
import UIKit

/// The system contact picker, for importing one person.
///
/// `CNContactPickerViewController` runs out of process. The app never sees the
/// address book, only the contact the user hands back, so this path needs no
/// permission prompt at all — which is why "Import from Phone" for a single
/// person should always come through here rather than through
/// `PhoneContactStore`.
///
/// It is wrapped in a plain host controller and presented from there, rather
/// than returned directly from `makeUIViewController`. The picker is a remote
/// view controller and does not behave as a sheet's root view; presenting it is
/// the documented way to use it.
struct SystemContactPicker: UIViewControllerRepresentable {
    /// Handed the picked contact. Never called with a nameless contact —
    /// `PhoneContactStore.map` drops those, and there is nothing to import from
    /// a row with no name.
    var onPick: @MainActor (ImportablePhoneContact) -> Void
    var onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        PickerHost(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPick: @MainActor (ImportablePhoneContact) -> Void
        private let onFinish: @MainActor () -> Void

        init(
            onPick: @escaping @MainActor (ImportablePhoneContact) -> Void,
            onFinish: @escaping @MainActor () -> Void
        ) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            MainActor.assumeIsolated {
                if let mapped = PhoneContactStore.map(contact) {
                    onPick(mapped)
                }
                onFinish()
            }
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            MainActor.assumeIsolated { onFinish() }
        }
    }

    /// Presents the picker once and reports the dismissal back up.
    private final class PickerHost: UIViewController {
        private let coordinator: Coordinator
        private var hasPresented = false

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasPresented else { return }
            hasPresented = true

            let picker = CNContactPickerViewController()
            picker.delegate = coordinator
            picker.displayedPropertyKeys = [
                CNContactPhoneNumbersKey,
                CNContactEmailAddressesKey,
                CNContactOrganizationNameKey,
                CNContactJobTitleKey
            ]
            present(picker, animated: animated)
        }
    }
}
