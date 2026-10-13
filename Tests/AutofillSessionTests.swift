import XCTest
@testable import WhisperPolish

final class AutofillSessionTests: XCTestCase {
    private let emailField = UUID()
    private let nameField = UUID()

    private var profile: AutofillProfile = {
        var profile = AutofillProfile.empty
        profile.add("jon@example.com", for: .email, source: .contact, at: Date(timeIntervalSince1970: 1))
        return profile
    }()

    func testLeavingAFieldWithANewValueOffersToSaveIt() {
        var session = AutofillSession()
        XCTAssertNil(session.observe(field: .email, document: emailField, text: "", profile: profile))
        XCTAssertNil(session.observe(field: .email, document: emailField, text: "new@exam", profile: profile))
        XCTAssertNil(session.observe(field: .email, document: emailField, text: "new@example.com ", profile: profile))
        let offer = session.observe(field: .givenName, document: nameField, text: "", profile: profile)
        XCTAssertEqual(offer?.field, .email)
        XCTAssertEqual(offer?.text, "new@example.com")
    }

    func testLeavingForAFieldThatIsntInTheProfileStillOffers() {
        var session = AutofillSession()
        _ = session.observe(field: .postalCode, document: emailField, text: "78701", profile: profile)
        XCTAssertEqual(session.observe(field: nil, document: nameField, text: "Hello", profile: profile)?.text, "78701")
    }

    func testFieldsOfTheSameKindInOneDocumentCountAsTheSameField() {
        var session = AutofillSession()
        _ = session.observe(field: .email, document: emailField, text: "new@example.com", profile: profile)
        XCTAssertNil(session.observe(field: .email, document: emailField, text: "new@example.com", profile: profile))
    }

    func testKnownValuesAreNotOffered() {
        var session = AutofillSession()
        _ = session.observe(field: .email, document: emailField, text: "JON@example.com", profile: profile)
        XCTAssertNil(session.observe(field: .givenName, document: nameField, text: "", profile: profile))
    }

    func testPartialOrInvalidValuesAreNotOffered() {
        var session = AutofillSession()
        _ = session.observe(field: .email, document: emailField, text: "new@exam", profile: profile)
        XCTAssertNil(session.observe(field: .givenName, document: nameField, text: "", profile: profile))
        _ = session.observe(field: .givenName, document: nameField, text: "R2D2", profile: profile)
        XCTAssertNil(session.observe(field: .email, document: emailField, text: "", profile: profile))
    }

    func testOrdinaryTextFieldsAreNeverOffered() {
        var session = AutofillSession()
        _ = session.observe(field: nil, document: emailField, text: "jon@other.com", profile: profile)
        XCTAssertNil(session.observe(field: .email, document: nameField, text: "", profile: profile))
    }

    func testAFilledValueIsNotOfferedBack() {
        var session = AutofillSession()
        _ = session.observe(field: .email, document: emailField, text: "jo", profile: profile)
        session.didFill(profile.values[0])
        XCTAssertNil(session.observe(field: nil, document: nameField, text: "", profile: profile))
    }

    func testCandidatesFollowTheFocusedField() {
        var session = AutofillSession()
        XCTAssertEqual(session.candidates(before: "", after: "", profile: profile), [])
        _ = session.observe(field: .email, document: emailField, text: "", profile: profile)
        XCTAssertEqual(session.candidates(before: "j", after: "", profile: profile).map(\.text), ["jon@example.com"])
        // The cursor in the middle of the text means the user is editing it, not filling it.
        XCTAssertEqual(session.candidates(before: "j", after: "on", profile: profile), [])
        _ = session.observe(field: .givenName, document: nameField, text: "", profile: profile)
        XCTAssertEqual(session.candidates(before: "", after: "", profile: profile), [])
    }

    func testFillingFromAnAddressPrefersItsOtherParts() {
        var profile = AutofillProfile.empty
        let home = UUID()
        let work = UUID()
        profile.values = [
            .init(field: .streetLine1, text: "1 Main St", source: .contact, address: home, lastUsed: Date(timeIntervalSince1970: 1)),
            .init(field: .city, text: "Austin", source: .contact, address: home, lastUsed: Date(timeIntervalSince1970: 1)),
            .init(field: .streetLine1, text: "9 Elm St", source: .contact, address: work, lastUsed: Date(timeIntervalSince1970: 2)),
            .init(field: .city, text: "Boston", source: .contact, address: work, lastUsed: Date(timeIntervalSince1970: 2)),
        ]
        var session = AutofillSession()
        _ = session.observe(field: .streetLine1, document: emailField, text: "", profile: profile)
        XCTAssertEqual(session.candidates(before: "", after: "", profile: profile).map(\.text), ["9 Elm St", "1 Main St"])
        session.didFill(profile.values[0])
        XCTAssertEqual(session.preferredAddress, home)
        _ = session.observe(field: .city, document: nameField, text: "", profile: profile)
        XCTAssertEqual(session.candidates(before: "", after: "", profile: profile).map(\.text), ["Austin", "Boston"])
    }
}
