@testable import CalendarEngine
import XCTest

/// Unit tests for the search matchers (fuzzy text + date concepts). These are pure static functions, so
/// they exercise the core scoring without standing up a full engine/view.
@MainActor
final class SearchMatchTests: XCTestCase {

    /// ── Word-anchored text ────────────────────────────────────────────────────────
    func testWholeWordBeatsPrefix() {
        let whole = CalendarEngine.wordScore("planning", "sprint planning") // whole word
        let prefix = CalendarEngine.wordScore("plan", "sprint planning") // word prefix
        XCTAssertEqual(whole, 1.0)
        XCTAssertEqual(prefix, 0.85)
        XCTAssertGreaterThan(whole, prefix)
    }

    func testWordPrefixMatches() {
        XCTAssertEqual(CalendarEngine.wordScore("cof", "coffee chat"), 0.85) // prefix of "coffee"
        XCTAssertEqual(CalendarEngine.wordScore("ai", "amazon ai"), 1.0) // whole word "ai"
        XCTAssertEqual(CalendarEngine.wordScore("sprint", "sprint planning"), 1.0)
    }

    func testNotSubsequenceNorMidWord() {
        // The reported case: "aaai" must NOT match "amazon ai".
        XCTAssertEqual(CalendarEngine.wordScore("aaai", "amazon ai"), 0)
        XCTAssertEqual(CalendarEngine.wordScore("pig", "sprint planning"), 0) // scattered subsequence
        XCTAssertEqual(CalendarEngine.wordScore("hat", "coffee chat"), 0) // mid-word (c·hat)
        XCTAssertEqual(CalendarEngine.wordScore("az", "amazon"), 0) // not a word prefix
        XCTAssertEqual(CalendarEngine.wordScore("wednesdy", "wednesday"), 0) // omission typo — no longer fuzzy
        XCTAssertEqual(CalendarEngine.wordScore("zzz", "coffee chat"), 0)
    }

    /// ── Date concepts ─────────────────────────────────────────────────────────────
    /// Reference date: Wednesday, 2026-07-15 (July, month0 = 6, weekday 4 = Wednesday).
    private let y = 2026, m0 = 6, d = 15, wed = 4

    private func score(_ term: String) -> Double {
        CalendarEngine.dateMatchScore(term, year: y, month0: m0, day: d, weekday: wed)
    }

    func testMonthNameAndPrefix() {
        XCTAssertGreaterThan(score("july"), 0)
        XCTAssertGreaterThan(score("jul"), 0)
        XCTAssertEqual(score("august"), 0)
        XCTAssertEqual(score("ju"), 0) // <3 chars → not treated as a month
    }

    func testWeekdayNamesAndAbbrevs() {
        XCTAssertGreaterThan(score("wednesday"), 0)
        XCTAssertGreaterThan(score("wed"), 0)
        XCTAssertGreaterThan(score("weds"), 0) // non-prefix abbrev
        XCTAssertEqual(score("mon"), 0)
    }

    func testISOAndSlashDates() {
        XCTAssertGreaterThan(score("2026-07-15"), 0)
        XCTAssertEqual(score("2026-07-16"), 0)
        XCTAssertGreaterThan(score("7/15"), 0)
        XCTAssertGreaterThan(score("7-15"), 0) // m-d form
        XCTAssertEqual(score("8/15"), 0)
    }

    func testYear() {
        XCTAssertGreaterThan(score("2026"), 0)
        XCTAssertEqual(score("2025"), 0)
    }

    func testNonDateTermScoresZero() {
        XCTAssertEqual(score("coffee"), 0)
    }
}
