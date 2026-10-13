import ContactsUI
import UIKit

/// The system contact picker. It runs outside the app, so iOS asks for no
/// Contacts permission and the app only ever sees the card the user picks.
@MainActor
final class ContactCardPicker: NSObject, @preconcurrency CNContactPickerDelegate {
    private var onPick: ((CNContact) -> Void)?

    /// Presented from UIKit: wrapped in a SwiftUI sheet, the picker dismisses itself and leaves the sheet blank.
    func present(onPick: @escaping (CNContact) -> Void) {
        self.onPick = onPick
        let picker = CNContactPickerViewController()
        picker.delegate = self
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }!
        var top = scene.keyWindow!.rootViewController!
        while let presented = top.presentedViewController { top = presented }
        top.present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        onPick?(contact)
        onPick = nil
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onPick = nil
    }
}
