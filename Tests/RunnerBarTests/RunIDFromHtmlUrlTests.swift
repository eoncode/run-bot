import XCTest

final class RunIDFromHtmlUrlTests: XCTestCase {

    func test_standardRunURL_returnsID() {
        XCTAssertEqual(
            runIDFromHtmlUrl("https://github.com/eoncode/runner-bar/actions/runs/9876543210"),
            9_876_543_210
        )
    }

    func test_urlWithJobPath_returnsRunID() {
        XCTAssertEqual(
            runIDFromHtmlUrl("https://github.com/owner/repo/actions/runs/42/jobs/7"),
            42
        )
    }

    func test_nilInput_returnsNil() {
        XCTAssertNil(runIDFromHtmlUrl(nil))
    }

    func test_urlWithoutRunsSegment_returnsNil() {
        XCTAssertNil(runIDFromHtmlUrl("https://github.com/owner/repo/actions"))
    }

    func test_runsSegmentWithNonNumericID_returnsNil() {
        XCTAssertNil(runIDFromHtmlUrl("https://github.com/owner/repo/actions/runs/abc"))
    }
}
