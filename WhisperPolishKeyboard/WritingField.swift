import UIKit

/// Whether a field holds the user's own writing, from the traits its app gives it.
/// Web and email addresses, searches, passwords, codes, and numbers aren't writing,
/// and an app that keeps autocorrect out of a field means its text isn't words to
/// fix. The keyboard doesn't learn from such fields or swap what's typed in them.
enum WritingField {
    private static let otherKeyboards: Set<UIKeyboardType> = [
        .URL, .emailAddress, .webSearch, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad, .numbersAndPunctuation,
    ]
    private static let searchReturnKeys: Set<UIReturnKeyType> = [.search, .google, .yahoo]
    private static let otherContent: Set<UITextContentType> = [
        .URL, .emailAddress, .username, .password, .newPassword, .oneTimeCode,
        .creditCardNumber, .telephoneNumber, .postalCode, .flightNumber, .shipmentTrackingNumber,
    ]

    static func holdsWriting(_ traits: UITextInputTraits) -> Bool {
        if traits.isSecureTextEntry == true || traits.autocorrectionType == .no { return false }
        if let keyboard = traits.keyboardType, otherKeyboards.contains(keyboard) { return false }
        if let returnKey = traits.returnKeyType, searchReturnKeys.contains(returnKey) { return false }
        if let content = traits.textContentType, let content, otherContent.contains(content) { return false }
        return true
    }
}
