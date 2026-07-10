import XCTest
import Swifter
@testable import meee2Kit

final class BoardServerControlPlaneTests: XCTestCase {
    private let token = "current-launch-token"
    private let origins = BoardServer.allowedOrigins(
        port: 9912,
        devOrigins: ["http://127.0.0.1:5002"]
    )

    func testMutationsRequireCurrentLaunchToken() {
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let missing = request(method: method, origin: "http://127.0.0.1:9912")
            XCTAssertEqual(
                BoardServer.controlPlaneDecision(
                    for: missing,
                    allowedOrigins: origins,
                    expectedToken: token
                ),
                .unauthorized,
                method
            )

            let authorized = request(
                method: method,
                origin: "http://127.0.0.1:9912",
                token: token
            )
            XCTAssertEqual(
                BoardServer.controlPlaneDecision(
                    for: authorized,
                    allowedOrigins: origins,
                    expectedToken: token
                ),
                .allow,
                method
            )
        }
    }

    func testForeignOriginIsRejectedEvenWithValidToken() {
        let request = request(method: "POST", origin: "https://attacker.example", token: token)
        XCTAssertEqual(
            BoardServer.controlPlaneDecision(
                for: request,
                allowedOrigins: origins,
                expectedToken: token
            ),
            .forbiddenOrigin
        )
    }

    func testDynamicBoundAndExplicitDevOriginsOnly() {
        XCTAssertTrue(origins.contains("http://127.0.0.1:9912"))
        XCTAssertTrue(origins.contains("http://localhost:9912"))
        XCTAssertTrue(origins.contains("http://127.0.0.1:5002"))
        XCTAssertFalse(origins.contains("http://127.0.0.1:9876"))

        let parsed = BoardServer.parseDevOrigins(
            "http://localhost:5002, https://localhost:5003, http://evil.example:5002, http://127.0.0.1:5004/path"
        )
        XCTAssertEqual(parsed, ["http://localhost:5002"])
    }

    func testFixedViteOriginsRemainLoopbackOnly() {
        XCTAssertEqual(
            BoardServer.viteDevOrigins,
            ["http://127.0.0.1:5002", "http://localhost:5002"]
        )
        XCTAssertTrue(BoardServer.viteDevOrigins.allSatisfy { origin in
            origin.hasPrefix("http://127.0.0.1:") || origin.hasPrefix("http://localhost:")
        })
    }

    func testReadRequestWithoutBrowserOriginRemainsAvailableToLocalProcesses() {
        let request = request(method: "GET", origin: nil)
        XCTAssertEqual(
            BoardServer.controlPlaneDecision(
                for: request,
                allowedOrigins: origins,
                expectedToken: token
            ),
            .allow
        )
    }

    func testWebSocketConsumesTokenOnlyFromFirstAuthFrame() {
        XCTAssertEqual(
            BoardServer.websocketAuthToken(
                in: #"{"type":"auth","controlToken":"current-launch-token"}"#
            ),
            token
        )
        XCTAssertNil(BoardServer.websocketAuthToken(in: #"{"type":"state.changed"}"#))
        XCTAssertNil(BoardServer.websocketAuthToken(in: #"{"type":"auth","controlToken":""}"#))
        XCTAssertNil(BoardServer.websocketAuthToken(in: "not-json"))
    }

    func testDestructiveInboxDrainRequiresTokenEvenThoughLegacyRouteUsesGet() {
        let drain = request(method: "GET", origin: "http://127.0.0.1:9912")
        drain.path = "/api/sessions/session-1/inbox"
        drain.queryParams = [("drain", "true")]
        XCTAssertEqual(
            BoardServer.controlPlaneDecision(
                for: drain,
                allowedOrigins: origins,
                expectedToken: token
            ),
            .unauthorized
        )

        drain.headers["x-meee2-control-token"] = token
        XCTAssertEqual(
            BoardServer.controlPlaneDecision(
                for: drain,
                allowedOrigins: origins,
                expectedToken: token
            ),
            .allow
        )
    }

    func testStateRevisionAdvancesMonotonicallyAcrossConcurrentBroadcasts() {
        let server = BoardServer.shared
        let before = server.currentStateVersion().revision
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            server.broadcastStateChanged()
        }
        XCTAssertEqual(server.currentStateVersion().revision, before + 100)
    }

    private func request(method: String, origin: String?, token: String? = nil) -> HttpRequest {
        let request = HttpRequest()
        request.method = method
        request.path = "/api/test"
        if let origin { request.headers["origin"] = origin }
        if let token { request.headers["x-meee2-control-token"] = token }
        return request
    }
}
