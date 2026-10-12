import Foundation

/// Follows the form field being typed in: which profile values to offer it,
/// and what the user typed that's worth saving once they move on.
struct AutofillSession {
    private(set) var field: ProfileField?
    private var document: UUID?
    private var text = ""
    /// The address last filled from, whose other parts are offered first.
    private(set) var preferredAddress: UUID?

    /// Call on every sync with the focused field and its whole text. Returns
    /// what was typed into the previous field if the user just left it with
    /// a value the profile doesn't have.
    mutating func observe(field: ProfileField?, document: UUID?, text: String, profile: AutofillProfile) -> (field: ProfileField, text: String)? {
        var offer: (field: ProfileField, text: String)?
        if let previous = self.field, previous != field || document != self.document {
            let typed = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if previous.accepts(typed), !profile.contains(typed, for: previous) {
                offer = (previous, typed)
            }
        }
        self.field = field
        self.document = document
        self.text = field == nil ? "" : text
        return offer
    }

    /// Values that finish what's before the cursor, unless the cursor is in the middle of the text.
    func candidates(before: String, after: String, profile: AutofillProfile) -> [AutofillProfile.Value] {
        guard let field, after.isEmpty else { return [] }
        return profile.candidates(for: field, typed: before, preferredAddress: preferredAddress)
    }

    mutating func didFill(_ value: AutofillProfile.Value) {
        text = value.text
        if let address = value.address { preferredAddress = address }
    }
}
