import Foundation
import UIKit

/// A detail the keyboard can fill into a form field.
enum ProfileField: String, Codable, CaseIterable, Identifiable {
    case fullName
    case givenName
    case familyName
    case email
    case phone
    case organization
    case streetLine1
    case streetLine2
    case city
    case state
    case postalCode
    case country

    var id: String { rawValue }

    static let addressParts: [ProfileField] = [.streetLine1, .streetLine2, .city, .state, .postalCode, .country]

    var isAddressPart: Bool { Self.addressParts.contains(self) }

    var title: String {
        switch self {
        case .fullName: "Full name"
        case .givenName: "First name"
        case .familyName: "Last name"
        case .email: "Email"
        case .phone: "Phone"
        case .organization: "Company"
        case .streetLine1: "Street"
        case .streetLine2: "Apt, suite"
        case .city: "City"
        case .state: "State"
        case .postalCode: "ZIP"
        case .country: "Country"
        }
    }

    /// The field a text input asks for. Web pages report their `autocomplete`
    /// attribute as the content type; an email keyboard is a weaker hint.
    init?(contentType: UITextContentType?, keyboardType: UIKeyboardType?) {
        switch contentType {
        case .name?: self = .fullName
        case .givenName?: self = .givenName
        case .familyName?: self = .familyName
        case .emailAddress?, .username?: self = .email
        case .telephoneNumber?: self = .phone
        case .organizationName?: self = .organization
        case .fullStreetAddress?, .streetAddressLine1?: self = .streetLine1
        case .streetAddressLine2?: self = .streetLine2
        case .addressCity?: self = .city
        case .addressState?: self = .state
        case .postalCode?: self = .postalCode
        case .countryName?: self = .country
        default:
            guard keyboardType == .emailAddress else { return nil }
            self = .email
        }
    }

    /// Whether typed text looks like a whole value for this field, worth offering to save.
    func accepts(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return false }
        switch self {
        case .email:
            return text.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s.]{2,}/) != nil
        case .phone:
            let digits = text.filter(\.isNumber).count
            return (7...15).contains(digits) && text.allSatisfy { $0.isNumber || "+-(). ".contains($0) }
        case .postalCode:
            return text.count <= 10 && text.contains(where: \.isNumber) && text.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9 -]*[A-Za-z0-9]/) != nil
        case .fullName, .givenName, .familyName, .city, .state, .country:
            return text.count <= 40 && text.allSatisfy { $0.isLetter || " .-'\u{2019}".contains($0) }
        case .organization, .streetLine2:
            return text.count <= 60
        case .streetLine1:
            return text.count <= 80 && text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
        }
    }

    /// The form two values are compared in, so "(555) 123-4567" matches "555-123-4567".
    func normalized(_ text: String) -> String {
        switch self {
        case .phone: text.filter(\.isNumber)
        default: text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}

/// The user's details for filling forms, kept in the app group so the app edits
/// them and the keyboard offers them. Nothing here leaves the phone.
struct AutofillProfile: Codable, Equatable {
    enum Source: String, Codable {
        /// Copied from the user's contact card.
        case contact
        /// Saved from a field the user typed it into.
        case typed
        /// Entered in the app.
        case manual
    }

    struct Value: Codable, Equatable, Identifiable {
        var id = UUID()
        var field: ProfileField
        var text: String
        var source: Source
        /// The address this is part of, so one address's parts are offered together.
        var address: UUID?
        /// The contact card's label for the address, like "home".
        var label: String?
        var lastUsed: Date
    }

    static let empty = AutofillProfile(values: [])

    var values: [Value]

    /// Up to `limit` values that finish `typed`, most recently used first,
    /// with parts of `preferredAddress` ahead of other addresses.
    func candidates(for field: ProfileField, typed: String, preferredAddress: UUID? = nil, limit: Int = 3) -> [Value] {
        let typed = typed.lowercased()
        let matches = values.filter {
            $0.field == field && $0.text.lowercased().hasPrefix(typed) && $0.text.lowercased() != typed
        }
        let sorted = matches.sorted { first, second in
            let firstPreferred = preferredAddress != nil && first.address == preferredAddress
            let secondPreferred = preferredAddress != nil && second.address == preferredAddress
            if firstPreferred != secondPreferred { return firstPreferred }
            return first.lastUsed > second.lastUsed
        }
        return Array(sorted.prefix(limit))
    }

    func contains(_ text: String, for field: ProfileField) -> Bool {
        let normalized = field.normalized(text)
        return values.contains { $0.field == field && field.normalized($0.text) == normalized }
    }

    /// Adds `text` unless the profile already has it.
    mutating func add(_ text: String, for field: ProfileField, source: Source, address: UUID? = nil, label: String? = nil, at now: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !contains(text, for: field) else { return }
        values.append(Value(field: field, text: text, source: source, address: address, label: label, lastUsed: now))
    }

    mutating func markUsed(_ id: UUID, at now: Date = Date()) {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].lastUsed = now
    }

    mutating func remove(_ id: UUID) {
        values.removeAll { $0.id == id }
    }

    /// Every address, each as its parts, in the order they were added.
    var addresses: [UUID] {
        var seen: [UUID] = []
        for value in values {
            if let address = value.address, !seen.contains(address) { seen.append(address) }
        }
        return seen
    }

    func value(for field: ProfileField, in address: UUID) -> Value? {
        values.first { $0.address == address && $0.field == field }
    }

    // MARK: - Storage

    static func load(from defaults: UserDefaults = AppGroup.defaults) -> AutofillProfile {
        guard let data = defaults.data(forKey: SettingsKeys.autofillProfile) else { return .empty }
        return try! JSONDecoder().decode(AutofillProfile.self, from: data)
    }

    func save(to defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(try! JSONEncoder().encode(self), forKey: SettingsKeys.autofillProfile)
    }

    /// Whether the keyboard offers to save details typed into form fields. On until turned off.
    static func offersToSaveTyping(in defaults: UserDefaults = AppGroup.defaults) -> Bool {
        defaults.object(forKey: SettingsKeys.autofillOffersToSave) as? Bool ?? true
    }
}
