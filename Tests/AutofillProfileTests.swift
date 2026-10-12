import Contacts
import UIKit
import XCTest
@testable import WhisperPolish

final class AutofillProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AutofillProfileTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - Fields

    func testWebAutocompleteContentTypesMapToFields() {
        let cases: [(UITextContentType, ProfileField)] = [
            (.name, .fullName), (.givenName, .givenName), (.familyName, .familyName),
            (.emailAddress, .email), (.username, .email), (.telephoneNumber, .phone),
            (.organizationName, .organization), (.streetAddressLine1, .streetLine1),
            (.fullStreetAddress, .streetLine1), (.streetAddressLine2, .streetLine2),
            (.addressCity, .city), (.addressState, .state), (.postalCode, .postalCode),
            (.countryName, .country),
        ]
        for (contentType, field) in cases {
            XCTAssertEqual(ProfileField(contentType: contentType, keyboardType: .default), field, contentType.rawValue)
        }
    }

    func testAnEmailKeyboardWithoutAContentTypeIsAnEmailField() {
        XCTAssertEqual(ProfileField(contentType: nil, keyboardType: .emailAddress), .email)
        XCTAssertNil(ProfileField(contentType: nil, keyboardType: .default))
        XCTAssertNil(ProfileField(contentType: .password, keyboardType: .default))
        XCTAssertNil(ProfileField(contentType: .oneTimeCode, keyboardType: .numberPad))
    }

    func testAcceptsWholeValuesOnly() {
        XCTAssertTrue(ProfileField.email.accepts("jon@example.com"))
        XCTAssertFalse(ProfileField.email.accepts("jon@example"))
        XCTAssertFalse(ProfileField.email.accepts("jon@example.c"))
        XCTAssertFalse(ProfileField.email.accepts("jon example.com"))
        XCTAssertTrue(ProfileField.phone.accepts("(555) 123-4567"))
        XCTAssertTrue(ProfileField.phone.accepts("+44 20 7946 0958"))
        XCTAssertFalse(ProfileField.phone.accepts("12345"))
        XCTAssertFalse(ProfileField.phone.accepts("call me"))
        XCTAssertTrue(ProfileField.postalCode.accepts("78701"))
        XCTAssertTrue(ProfileField.postalCode.accepts("78701-1234"))
        XCTAssertTrue(ProfileField.postalCode.accepts("SW1A 1AA"))
        XCTAssertFalse(ProfileField.postalCode.accepts("Austin"))
        XCTAssertTrue(ProfileField.givenName.accepts("Mary-Jane"))
        XCTAssertTrue(ProfileField.familyName.accepts("O\u{2019}Brien"))
        XCTAssertFalse(ProfileField.givenName.accepts("Jon2"))
        XCTAssertTrue(ProfileField.streetLine1.accepts("1 Infinite Loop"))
        XCTAssertFalse(ProfileField.streetLine1.accepts("Infinite Loop"))
        XCTAssertFalse(ProfileField.city.accepts(""))
        XCTAssertFalse(ProfileField.city.accepts("   "))
        XCTAssertFalse(ProfileField.organization.accepts("Line one\nLine two"))
    }

    func testPhonesCompareByDigitsAndTextIgnoringCase() {
        var profile = AutofillProfile.empty
        profile.add("(555) 123-4567", for: .phone, source: .contact)
        XCTAssertTrue(profile.contains("555.123.4567", for: .phone))
        profile.add("Jon@Example.com", for: .email, source: .contact)
        XCTAssertTrue(profile.contains("jon@example.com ", for: .email))
        XCTAssertFalse(profile.contains("jon@example.com", for: .phone))
    }

    // MARK: - Candidates

    func testCandidatesFinishWhatsTypedMostRecentFirst() {
        var profile = AutofillProfile.empty
        profile.add("jon@work.com", for: .email, source: .contact, at: date(1))
        profile.add("jon@home.com", for: .email, source: .contact, at: date(3))
        profile.add("other@home.com", for: .email, source: .contact, at: date(2))
        profile.add("Jon", for: .givenName, source: .contact, at: date(4))

        XCTAssertEqual(profile.candidates(for: .email, typed: "").map(\.text), ["jon@home.com", "other@home.com", "jon@work.com"])
        XCTAssertEqual(profile.candidates(for: .email, typed: "JO").map(\.text), ["jon@home.com", "jon@work.com"])
        XCTAssertEqual(profile.candidates(for: .email, typed: "jon@w").map(\.text), ["jon@work.com"])
        XCTAssertEqual(profile.candidates(for: .email, typed: "x").map(\.text), [])
        // A field already holding the whole value has nothing left to offer.
        XCTAssertEqual(profile.candidates(for: .email, typed: "jon@work.com").map(\.text), [])
    }

    func testCandidatesStopAtTheLimit() {
        var profile = AutofillProfile.empty
        for index in 0..<5 { profile.add("person\(index)@example.com", for: .email, source: .typed, at: date(Double(index))) }
        XCTAssertEqual(profile.candidates(for: .email, typed: "").count, 3)
        XCTAssertEqual(profile.candidates(for: .email, typed: "").first?.text, "person4@example.com")
    }

    func testMarkingAValueUsedMovesItFirst() {
        var profile = AutofillProfile.empty
        profile.add("a@example.com", for: .email, source: .contact, at: date(1))
        profile.add("b@example.com", for: .email, source: .contact, at: date(2))
        let older = profile.values[0]
        profile.markUsed(older.id, at: date(3))
        XCTAssertEqual(profile.candidates(for: .email, typed: "").first?.text, "a@example.com")
    }

    func testThePreferredAddressComesFirst() {
        var profile = AutofillProfile.empty
        let home = UUID()
        let work = UUID()
        profile.values = [
            .init(field: .city, text: "Austin", source: .contact, address: home, lastUsed: date(1)),
            .init(field: .city, text: "Boston", source: .contact, address: work, lastUsed: date(2)),
        ]
        XCTAssertEqual(profile.candidates(for: .city, typed: "").map(\.text), ["Boston", "Austin"])
        XCTAssertEqual(profile.candidates(for: .city, typed: "", preferredAddress: home).map(\.text), ["Austin", "Boston"])
        XCTAssertEqual(profile.addresses, [home, work])
        XCTAssertEqual(profile.value(for: .city, in: work)?.text, "Boston")
    }

    func testAddingSkipsBlanksAndDuplicates() {
        var profile = AutofillProfile.empty
        profile.add("  ", for: .city, source: .manual)
        profile.add(" Austin ", for: .city, source: .manual)
        profile.add("austin", for: .city, source: .typed)
        XCTAssertEqual(profile.values.map(\.text), ["Austin"])
        profile.remove(profile.values[0].id)
        XCTAssertEqual(profile.values, [])
    }

    // MARK: - Storage

    func testSavesAndLoadsThroughTheAppGroup() {
        XCTAssertEqual(AutofillProfile.load(from: defaults), .empty)
        var profile = AutofillProfile.empty
        profile.add("jon@example.com", for: .email, source: .typed, at: date(5))
        profile.save(to: defaults)
        XCTAssertEqual(AutofillProfile.load(from: defaults), profile)
    }

    func testOffersToSaveTypingUntilTurnedOff() {
        XCTAssertTrue(AutofillProfile.offersToSaveTyping(in: defaults))
        defaults.set(false, forKey: SettingsKeys.autofillOffersToSave)
        XCTAssertFalse(AutofillProfile.offersToSaveTyping(in: defaults))
    }

    // MARK: - Contact card

    private func contactCard() -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = "Jon"
        contact.familyName = "Clegg"
        contact.organizationName = "Yallware"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "jon@example.com" as NSString),
            CNLabeledValue(label: CNLabelWork, value: "jon@work.example" as NSString),
        ]
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(555) 123-4567"))]
        let home = CNMutablePostalAddress()
        home.street = "1 Main St\nApt 4"
        home.city = "Austin"
        home.state = "TX"
        home.postalCode = "78701"
        home.country = "United States"
        let work = CNMutablePostalAddress()
        work.street = "500 Congress Ave"
        work.city = "Austin"
        work.state = "TX"
        work.postalCode = "78702"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: home), CNLabeledValue(label: CNLabelWork, value: work)]
        return contact
    }

    func testImportsEveryDetailOnTheCard() {
        var profile = AutofillProfile.empty
        profile.importContact(contactCard(), at: date(1))

        func texts(_ field: ProfileField) -> [String] { profile.values.filter { $0.field == field }.map(\.text) }
        XCTAssertEqual(texts(.fullName), ["Jon Clegg"])
        XCTAssertEqual(texts(.givenName), ["Jon"])
        XCTAssertEqual(texts(.familyName), ["Clegg"])
        XCTAssertEqual(texts(.organization), ["Yallware"])
        XCTAssertEqual(texts(.email), ["jon@example.com", "jon@work.example"])
        XCTAssertEqual(texts(.phone), ["(555) 123-4567"])
        XCTAssertTrue(profile.values.allSatisfy { $0.source == .contact })

        XCTAssertEqual(profile.addresses.count, 2)
        let home = profile.addresses[0]
        let work = profile.addresses[1]
        XCTAssertEqual(profile.value(for: .streetLine1, in: home)?.text, "1 Main St")
        XCTAssertEqual(profile.value(for: .streetLine2, in: home)?.text, "Apt 4")
        XCTAssertEqual(profile.value(for: .city, in: home)?.text, "Austin")
        XCTAssertEqual(profile.value(for: .postalCode, in: home)?.text, "78701")
        XCTAssertEqual(profile.value(for: .country, in: home)?.text, "United States")
        XCTAssertEqual(profile.value(for: .city, in: home)?.label, "home")
        XCTAssertNil(profile.value(for: .streetLine2, in: work))
        XCTAssertNil(profile.value(for: .country, in: work))
        // Both addresses keep their own city even though it's the same.
        XCTAssertEqual(profile.value(for: .city, in: work)?.text, "Austin")
    }

    func testImportingTheSameCardTwiceAddsNothing() {
        var profile = AutofillProfile.empty
        profile.importContact(contactCard(), at: date(1))
        let first = profile
        profile.importContact(contactCard(), at: date(2))
        XCTAssertEqual(profile, first)
    }

    func testImportKeepsDetailsAlreadyInTheProfile() {
        var profile = AutofillProfile.empty
        profile.add("jon@example.com", for: .email, source: .typed, at: date(0))
        profile.importContact(contactCard(), at: date(1))
        XCTAssertEqual(profile.values.filter { $0.field == .email }.map(\.source), [.typed, .contact])
    }

    func testImportSkipsPropertiesThePickerLeftOut() {
        let partial = CNContact()
        var profile = AutofillProfile.empty
        profile.importContact(partial)
        XCTAssertEqual(profile, .empty)
    }
}
