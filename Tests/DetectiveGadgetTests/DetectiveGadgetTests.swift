import XCTest
@testable import DetectiveGadget

final class DetectiveGadgetTests: XCTestCase {
    func testExtractsJiraKeyFromBrowseURL() {
        XCTAssertEqual(JiraSupport.key(from: "https://example.atlassian.net/browse/IOS-123"), "IOS-123")
    }

    func testBuildsJQLFromTicketKey() {
        XCTAssertEqual(JiraSupport.jql(for: "IOS-123"), "key = \"IOS-123\"")
    }

    func testBranchNameUsesMaximumThreeWordsPerPart() {
        XCTAssertEqual(BranchName.make(ticket: "IOS-123", issueDescription: "Player crashes on empty episode", solution: "Guard missing player state"), "bugfix/IOS-123-playerCrashesOn-guardMissingPlayer")
    }
}
