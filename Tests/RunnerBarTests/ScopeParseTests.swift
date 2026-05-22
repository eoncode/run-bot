import XCTest

final class ScopeParseTests: XCTestCase {

    // MARK: - Repo

    func test_ownerSlashRepo_parsesAsRepo() {
        guard case .repo(let owner, let name) = Scope.parse("eoncode/runner-bar") else {
            return XCTFail("Expected .repo")
        }
        XCTAssertEqual(owner, "eoncode")
        XCTAssertEqual(name, "runner-bar")
    }

    func test_repoApiPrefix() {
        XCTAssertEqual(Scope.parse("apple/swift")?.apiPrefix, "repos/apple/swift")
    }

    // MARK: - Org

    func test_singleSegment_parsesAsOrg() {
        guard case .org(let org) = Scope.parse("myorg") else {
            return XCTFail("Expected .org")
        }
        XCTAssertEqual(org, "myorg")
    }

    func test_orgApiPrefix() {
        XCTAssertEqual(Scope.parse("myorg")?.apiPrefix, "orgs/myorg")
    }

    // MARK: - Invalid

    func test_emptyString_returnsNil() {
        XCTAssertNil(Scope.parse(""))
    }

    func test_leadingSlash_returnsNil() {
        XCTAssertNil(Scope.parse("/repo"))
    }

    func test_trailingSlash_returnsNil() {
        XCTAssertNil(Scope.parse("owner/"))
    }

    func test_slashOnly_returnsNil() {
        XCTAssertNil(Scope.parse("/"))
    }

    func test_threeSegments_parsesFirstTwoAsRepo() {
        // split(maxSplits:1) means "owner/repo/extra" → owner="owner", name="repo/extra"
        // Verify it doesn't silently drop the third segment in an unexpected way
        guard case .repo(let owner, let name) = Scope.parse("owner/repo/extra") else {
            return XCTFail("Expected .repo")
        }
        XCTAssertEqual(owner, "owner")
        XCTAssertEqual(name, "repo/extra")
    }
}
