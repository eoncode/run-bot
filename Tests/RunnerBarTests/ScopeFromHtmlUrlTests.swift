import XCTest

final class ScopeFromHtmlUrlTests: XCTestCase {

    func test_repoURL_returnsOwnerSlashRepo() {
        XCTAssertEqual(scopeFromHtmlUrl("https://github.com/apple/swift"), "apple/swift")
    }

    func test_repoURLWithPath_returnsOwnerSlashRepo() {
        XCTAssertEqual(
            scopeFromHtmlUrl("https://github.com/eoncode/runner-bar/actions/runs/123"),
            "eoncode/runner-bar"
        )
    }

    func test_nilInput_returnsNil() {
        XCTAssertNil(scopeFromHtmlUrl(nil))
    }

    func test_emptyString_returnsNil() {
        XCTAssertNil(scopeFromHtmlUrl(""))
    }

    func test_malformedURL_returnsNil() {
        XCTAssertNil(scopeFromHtmlUrl("not a url"))
    }

    func test_rootURL_returnsNil() {
        // Only one path component — not enough for owner/repo
        XCTAssertNil(scopeFromHtmlUrl("https://github.com/onlyone"))
    }
}
