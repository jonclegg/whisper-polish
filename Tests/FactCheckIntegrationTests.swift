import XCTest
@testable import WhisperPolish

/// Hits the real OpenRouter API. Skipped unless a key is available.
///
/// This is the suite that answers the question the mocked tests can't:
/// OpenRouter does not document whether `response_format: json_schema`
/// composes with the `openrouter:web_search` server tool. Everything else
/// about the feature is unit-tested; this proves the combination routes,
/// searches, and comes back as parseable JSON.
///
/// To run it, set OPENROUTER_API_KEY in the scheme's test-action environment.
final class FactCheckIntegrationTests: XCTestCase {

    private func apiKey() throws -> String {
        let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "No OpenRouter key available; skipping live fact-check test.")
        return key
    }

    /// The load-bearing test: a real call, with a claim that is flatly wrong
    /// next to one that is true, and a subjective line that should be ignored.
    func testLiveFactCheckCatchesAWrongDateAndLeavesOpinionsAlone() async throws {
        let key = try apiKey()
        let report = try await FactCheckService().check(
            text: """
            The Apollo 11 moon landing happened in 1968. Swift was open sourced \
            in 2015 under the Apache license. Honestly I think it's the most \
            enjoyable language to write.
            """,
            apiKey: key
        )

        XCTAssertFalse(report.findings.isEmpty, "expected at least the Apollo claim to be checked")

        let apollo = report.findings.first { $0.claim.localizedCaseInsensitiveContains("Apollo") }
        let checked = try XCTUnwrap(apollo, "Apollo 11 date should have been picked up as a claim")
        XCTAssertEqual(checked.verdict, .contradicted, "1968 is wrong; Apollo 11 landed in 1969")
        XCTAssertTrue(checked.note.contains("1969"), "the note should give the right year: \(checked.note)")

        // Opinions aren't checkable and shouldn't be reported as findings.
        XCTAssertNil(
            report.findings.first { $0.claim.localizedCaseInsensitiveContains("enjoyable") },
            "a subjective statement was reported as a factual claim"
        )
    }

    /// Web search actually ran and the citations are real URLs, not invented.
    func testLiveFactCheckReturnsUsableSources() async throws {
        let key = try apiKey()
        let report = try await FactCheckService().check(
            text: "The Eiffel Tower was completed in 1889 and stands in Paris.",
            apiKey: key
        )
        let sources = report.findings.flatMap(\.sources)
        XCTAssertFalse(sources.isEmpty, "expected at least one cited source")
        for source in sources {
            let url = try XCTUnwrap(URL(string: source.url), "unparseable URL: \(source.url)")
            XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""), "not a web URL: \(source.url)")
            XCTAssertFalse(source.title.isEmpty, "source has no title")
        }
    }

    /// A note with nothing checkable in it should come back clean, not with
    /// invented findings.
    func testLiveFactCheckOnAPurelyPersonalNoteFindsNothing() async throws {
        let key = try apiKey()
        let report = try await FactCheckService().check(
            text: """
            Reminder to call Mum back tonight, and I should probably start that \
            book I keep putting off. Felt a lot better after the walk today.
            """,
            apiKey: key
        )
        XCTAssertTrue(
            report.findings.isEmpty,
            "expected no findings, got: \(report.findings.map(\.claim))"
        )
    }
}
