import Contacts

extension AutofillProfile {
    /// Copies the details on a contact card, skipping ones the profile already has.
    mutating func importContact(_ contact: CNContact, at now: Date = Date()) {
        // The picker can hand back a card without some properties; reading one would throw.
        func available<Property>(_ key: String, _ read: () -> Property, default empty: Property) -> Property {
            contact.isKeyAvailable(key) ? read() : empty
        }
        let given = available(CNContactGivenNameKey, { contact.givenName }, default: "")
        let family = available(CNContactFamilyNameKey, { contact.familyName }, default: "")
        add([given, family].filter { !$0.isEmpty }.joined(separator: " "), for: .fullName, source: .contact, at: now)
        add(given, for: .givenName, source: .contact, at: now)
        add(family, for: .familyName, source: .contact, at: now)
        add(available(CNContactOrganizationNameKey, { contact.organizationName }, default: ""), for: .organization, source: .contact, at: now)
        for email in available(CNContactEmailAddressesKey, { contact.emailAddresses }, default: []) {
            add(email.value as String, for: .email, source: .contact, at: now)
        }
        for phone in available(CNContactPhoneNumbersKey, { contact.phoneNumbers }, default: []) {
            add(phone.value.stringValue, for: .phone, source: .contact, at: now)
        }
        for postal in available(CNContactPostalAddressesKey, { contact.postalAddresses }, default: []) {
            let label = postal.label.map { CNLabeledValue<CNPostalAddress>.localizedString(forLabel: $0) }
            importAddress(postal.value, label: label, at: now)
        }
    }

    /// Adds an address as one group of parts, unless the profile has the same address.
    private mutating func importAddress(_ postal: CNPostalAddress, label: String?, at now: Date) {
        let lines = postal.street
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let texts: [ProfileField: String] = [
            .streetLine1: lines.first ?? "",
            .streetLine2: lines.dropFirst().joined(separator: ", "),
            .city: postal.city,
            .state: postal.state,
            .postalCode: postal.postalCode,
            .country: postal.country,
        ]
        let parts = ProfileField.addressParts.map { (field: $0, text: texts[$0]!.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.contains(where: { !$0.text.isEmpty }) else { return }
        let isKnown = addresses.contains { address in
            parts.allSatisfy { part in
                part.field.normalized(value(for: part.field, in: address)?.text ?? "") == part.field.normalized(part.text)
            }
        }
        guard !isKnown else { return }
        let address = UUID()
        for part in parts where !part.text.isEmpty {
            values.append(Value(field: part.field, text: part.text, source: .contact, address: address, label: label, lastUsed: now))
        }
    }
}
