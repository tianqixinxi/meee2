import XCTest
@testable import meee2Kit

final class BoardAPIPlannerInputTests: XCTestCase {
    func testPlannerInputFileTypesCoverDocumentsTextAndImages() {
        XCTAssertTrue(BoardAPI.plannerInputFileTypeIsSupported(filename: "brief.pdf", contentType: "application/pdf"))
        XCTAssertTrue(BoardAPI.plannerInputFileTypeIsSupported(filename: "budget.xlsx", contentType: "application/octet-stream"))
        XCTAssertTrue(BoardAPI.plannerInputFileTypeIsSupported(filename: "data.csv", contentType: "text/csv"))
        XCTAssertTrue(BoardAPI.plannerInputFileTypeIsSupported(filename: "poster.png", contentType: "image/png"))
    }

    func testPlannerInputFileTypesRejectExecutables() {
        XCTAssertFalse(BoardAPI.plannerInputFileTypeIsSupported(filename: "payload.dylib", contentType: "application/octet-stream"))
        XCTAssertFalse(BoardAPI.plannerInputFileTypeIsSupported(filename: "script.sh", contentType: "application/x-sh"))
    }
}
