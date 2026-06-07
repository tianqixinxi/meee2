import XCTest
@testable import meee2Kit

final class BoardPerfProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BoardPerfProbe.shared.reset()
    }

    func testProbeAggregatesDurationsEventsAndReset() throws {
        let value = BoardPerfProbe.shared.measure(
            "test.duration",
            title: "duration",
            category: "test",
            detail: "canvas=test",
            bytes: 128
        ) {
            "ok"
        }
        XCTAssertEqual(value, "ok")

        BoardPerfProbe.shared.recordEvent(
            "test.event",
            title: "event",
            category: "test",
            detail: "event detail"
        )

        let snapshot = BoardPerfProbe.shared.snapshot()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertEqual(snapshot.recentEvents.count, 2)
        XCTAssertEqual(snapshot.metrics.first(where: { $0.id == "test.duration" })?.totalBytes, 128)

        BoardPerfProbe.shared.reset()
        let reset = BoardPerfProbe.shared.snapshot()
        XCTAssertTrue(reset.metrics.isEmpty)
        XCTAssertTrue(reset.recentEvents.isEmpty)
    }
}
