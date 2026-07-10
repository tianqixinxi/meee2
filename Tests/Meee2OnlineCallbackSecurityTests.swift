import Foundation
import Swifter
import XCTest
@testable import meee2Kit

final class Meee2OnlineCallbackSecurityTests: XCTestCase {
    func testCallbackStateIsOneTimeAndExpires() throws {
        var currentTime = Date(timeIntervalSince1970: 2_000_000_000)
        var tokenIndex = 0
        let store = Meee2OnlineCallbackStateStore(
            ttl: 30,
            now: { currentTime },
            makeToken: {
                tokenIndex += 1
                return "state-\(tokenIndex)"
            },
            makeVerifier: { "verifier-verifier-verifier-verifier-verifier-123" }
        )

        XCTAssertThrowsError(try store.consume(nil)) { error in
            XCTAssertEqual(error as? Meee2OnlineCallbackStateStore.ConsumptionError, .missing)
        }
        XCTAssertThrowsError(try store.consume("not-issued")) { error in
            XCTAssertEqual(error as? Meee2OnlineCallbackStateStore.ConsumptionError, .invalidOrReplayed)
        }

        let first = store.issue()
        XCTAssertEqual(try store.consume(first.state), "verifier-verifier-verifier-verifier-verifier-123")
        XCTAssertThrowsError(try store.consume(first.state)) { error in
            XCTAssertEqual(error as? Meee2OnlineCallbackStateStore.ConsumptionError, .invalidOrReplayed)
        }

        let expiring = store.issue()
        currentTime = currentTime.addingTimeInterval(31)
        XCTAssertThrowsError(try store.consume(expiring.state)) { error in
            XCTAssertEqual(error as? Meee2OnlineCallbackStateStore.ConsumptionError, .expired)
        }
    }

    func testConnectURLBindsStateWithoutPuttingCredentialsInURL() throws {
        let store = Meee2OnlineCallbackStateStore(
            makeToken: { "fixed-state" },
            makeVerifier: { "verifier-verifier-verifier-verifier-verifier-123" }
        )
        let connectURL = Meee2OnlineCallbackAPI.issueConnectURL(
            boardURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9912")),
            stateStore: store
        )
        let outer = try XCTUnwrap(URLComponents(url: connectURL, resolvingAgainstBaseURL: false))
        let outerItems = try XCTUnwrap(outer.queryItems)
        XCTAssertEqual(outerItems.first(where: { $0.name == "state" })?.value, "fixed-state")
        XCTAssertEqual(outerItems.first(where: { $0.name == "response_type" })?.value, "code")
        XCTAssertEqual(outerItems.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertFalse(try XCTUnwrap(outerItems.first(where: { $0.name == "code_challenge" })?.value).isEmpty)
        XCTAssertFalse(connectURL.absoluteString.contains("code_verifier"))

        let callbackRaw = try XCTUnwrap(outerItems.first(where: { $0.name == "callback" })?.value)
        let callbackURL = try XCTUnwrap(URL(string: callbackRaw))
        let callback = try XCTUnwrap(URLComponents(url: callbackURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(callback.path, "/meee2/callback")
        XCTAssertEqual(callback.queryItems?.first(where: { $0.name == "state" })?.value, "fixed-state")

        for forbidden in ["access_token", "refresh_token", "supabase_key"] {
            XCTAssertFalse(connectURL.absoluteString.lowercased().contains(forbidden))
        }
    }

    func testMissingWrongAndReplayedStateCannotPersist() throws {
        let store = Meee2OnlineCallbackStateStore(makeToken: { "valid-state" })
        var exchangeCount = 0
        var persistCount = 0
        let exchange: Meee2OnlineCallbackAPI.CodeExchange = { _, verifier in
            exchangeCount += 1
            XCTAssertFalse(verifier.isEmpty)
            return .success(self.connectionResult())
        }
        let persist: Meee2OnlineCallbackAPI.ConnectionPersist = { _ in
            persistCount += 1
            return true
        }

        let maliciousNavigation = request([
            ("code", "attacker-code"),
            ("team_name", "<script>window.pwned=1</script>")
        ])
        XCTAssertEqual(callback(maliciousNavigation, store: store, exchange: exchange, persist: persist).statusCode, 403)

        let issued = store.issue().state
        XCTAssertEqual(callback(
            request([("state", "wrong-state"), ("code", "code-a")]),
            store: store,
            exchange: exchange,
            persist: persist
        ).statusCode, 403)

        let accepted = callback(
            request([("state", issued), ("code", "code-a")]),
            store: store,
            exchange: exchange,
            persist: persist
        )
        XCTAssertEqual(accepted.statusCode, 200)

        let replay = callback(
            request([("state", issued), ("code", "code-a")]),
            store: store,
            exchange: exchange,
            persist: persist
        )
        XCTAssertEqual(replay.statusCode, 403)
        XCTAssertEqual(exchangeCount, 1)
        XCTAssertEqual(persistCount, 1)
    }

    func testLegacyCredentialQueryIsRejectedWithoutExchangeOrPersistence() {
        let store = Meee2OnlineCallbackStateStore(makeToken: { "legacy-state" })
        let state = store.issue().state
        var exchangeCount = 0
        var persistCount = 0
        let response = callback(
            request([
                ("state", state),
                ("access_token", "must-not-enter-url"),
                ("refresh_token", "must-not-enter-url-either"),
                ("team_name", "Attacker")
            ]),
            store: store,
            exchange: { _, _ in
                exchangeCount += 1
                return .success(self.connectionResult())
            },
            persist: { _ in
                persistCount += 1
                return true
            }
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(exchangeCount, 0)
        XCTAssertEqual(persistCount, 0)
        let body = responseBody(response)
        XCTAssertFalse(body.contains("must-not-enter-url"))
        XCTAssertFalse(body.contains("Attacker"))
    }

    func testSuccessHTMLIsEscapedTokenFreeAndLockedDownByCSP() {
        let store = Meee2OnlineCallbackStateStore(makeToken: { "xss-state" })
        let state = store.issue().state
        let dangerousName = #"</strong><script>window.pwned=1</script><strong>"#
        let result = connectionResult(teamName: dangerousName)
        let response = callback(
            request([("state", state), ("code", "secure-code")]),
            store: store,
            exchange: { _, _ in .success(result) },
            persist: { _ in true }
        )

        XCTAssertEqual(response.statusCode, 200)
        let headers = response.headers()
        let csp = headers["Content-Security-Policy"] ?? ""
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("script-src 'none'"))
        XCTAssertEqual(headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(headers["X-Frame-Options"], "DENY")

        let body = responseBody(response)
        XCTAssertFalse(body.contains("<script>window.pwned=1</script>"))
        XCTAssertTrue(body.contains("&lt;script&gt;window.pwned=1&lt;/script&gt;"))
        XCTAssertFalse(body.contains("access-secret"))
        XCTAssertFalse(body.contains("refresh-secret"))
    }

    private func callback(
        _ request: HttpRequest,
        store: Meee2OnlineCallbackStateStore,
        exchange: @escaping Meee2OnlineCallbackAPI.CodeExchange,
        persist: @escaping Meee2OnlineCallbackAPI.ConnectionPersist
    ) -> HttpResponse {
        Meee2OnlineCallbackAPI.handleCallback(
            request: request,
            stateStore: store,
            exchange: exchange,
            persist: persist
        )
    }

    private func request(_ query: [(String, String)]) -> HttpRequest {
        let request = HttpRequest()
        request.method = "GET"
        request.path = "/meee2/callback"
        request.queryParams = query
        return request
    }

    private func connectionResult(
        teamName: String = "Secure Team"
    ) -> Meee2OnlineConnectResult {
        Meee2OnlineConnectResult(
            team: Meee2OnlineTeam(id: "team-1", name: teamName, role: "owner"),
            teams: nil,
            user: Meee2OnlineUser(id: "user-1", email: "user@example.com", name: "User", avatar_url: nil),
            supabase_url: "https://example.supabase.co",
            supabase_key: "public-anon-key",
            online_base_url: "https://www.meee2.com",
            access_token: "access-secret",
            refresh_token: "refresh-secret"
        )
    }

    private func responseBody(_ response: HttpResponse) -> String {
        guard case .raw(_, _, _, let write) = response, let write else { return "" }
        let sink = MemoryResponseWriter()
        try? write(sink)
        return String(data: sink.data, encoding: .utf8) ?? ""
    }
}

private final class MemoryResponseWriter: HttpResponseBodyWriter {
    private(set) var data = Data()

    func write(_ file: String.File) throws {}
    func write(_ bytes: [UInt8]) throws { data.append(contentsOf: bytes) }
    func write(_ bytes: ArraySlice<UInt8>) throws { data.append(contentsOf: bytes) }
    func write(_ value: NSData) throws { data.append(value as Data) }
    func write(_ value: Data) throws { data.append(value) }
}
