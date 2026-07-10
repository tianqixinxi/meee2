import XCTest
@testable import meee2Kit

final class DebugExporterPrivacyTests: XCTestCase {
    func testRedactsHomeAndCredentialShapes() {
        let input = """
        cwd=\(NSHomeDirectory())/Code/private
        Authorization: Bearer abc.def.ghi
        apiKey=sk-secretvalue123456
        {"refreshToken":"refresh-secret"}
        sk-ant-abcdefghijklmnopqrstuvwxyz
        """

        let output = DebugExporter.redactForExport(input)

        XCTAssertFalse(output.contains(NSHomeDirectory()))
        XCTAssertFalse(output.contains("abc.def.ghi"))
        XCTAssertFalse(output.contains("refresh-secret"))
        XCTAssertFalse(output.contains("sk-ant-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertGreaterThanOrEqual(output.components(separatedBy: "[REDACTED]").count, 4)
    }
}
