import XCTest
import Darwin
@testable import meee2Kit

final class PermissionContractTests: XCTestCase {
    func testBridgeWaitsPastTheSharedServerDeadlineAndNeverLogsRawPayloads() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(
            contentsOf: repository.appendingPathComponent("Bridge/claude-hook-bridge.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(bridge.contains("MEEE2_PERMISSION_TIMEOUT_SECONDS:-300"))
        XCTAssertTrue(bridge.contains("BRIDGE_PERMISSION_TIMEOUT_SECONDS=$((PERMISSION_TIMEOUT_SECONDS + 5))"))
        XCTAssertFalse(bridge.contains("meee2-permission-payload.log"))
        XCTAssertFalse(bridge.contains("PAYLOAD event="))
    }

    func testTimeoutPolicyUsesOneValidatedEnvironmentContract() {
        XCTAssertEqual(PermissionTimeoutPolicy.serverSeconds(environment: [:]), 300)
        XCTAssertEqual(
            PermissionTimeoutPolicy.serverSeconds(environment: ["MEEE2_PERMISSION_TIMEOUT_SECONDS": "45"]),
            45
        )
        XCTAssertEqual(
            PermissionTimeoutPolicy.serverSeconds(environment: ["MEEE2_PERMISSION_TIMEOUT_SECONDS": "invalid"]),
            300
        )
        XCTAssertEqual(
            PermissionTimeoutPolicy.serverSeconds(environment: ["MEEE2_PERMISSION_TIMEOUT_SECONDS": "1e2"]),
            300
        )
        XCTAssertEqual(
            PermissionTimeoutPolicy.serverSeconds(environment: ["MEEE2_PERMISSION_TIMEOUT_SECONDS": "0"]),
            300
        )
        XCTAssertEqual(PermissionTimeoutPolicy.bridgeGraceSeconds, 5)
    }

    func testCanonicalCorrelationKeyIgnoresJSONObjectKeyOrder() {
        let first = HookEvent(
            event: .preToolUse,
            sessionId: "session-a",
            toolUseId: "tool-a",
            toolName: "Bash",
            rawData: #"{"session_id":"session-a","tool_name":"Bash","tool_input":{"b":2,"a":1}}"#
        )
        let second = HookEvent(
            event: .permissionRequest,
            sessionId: "session-a",
            toolName: "Bash",
            rawData: #"{"tool_input":{"a":1,"b":2},"tool_name":"Bash","session_id":"session-a"}"#
        )

        XCTAssertEqual(HookSocketServer.cacheKey(for: first), HookSocketServer.cacheKey(for: second))
        XCTAssertFalse(HookSocketServer.cacheKey(for: first).contains("\"a\""))
    }

    func testCorrelationCacheExpiresAndEvictsLeastRecentlyUsedEntries() {
        let server = HookSocketServer(permissionTimeoutProvider: { 0 })
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiring = correlationEvent(sessionId: "expiring", input: 1)
        server.cacheToolUseId(event: expiring, toolUseId: "old", now: now)
        XCTAssertNil(
            server.popCachedToolUseId(
                event: expiring,
                now: now.addingTimeInterval(HookSocketServer.toolUseIdCacheTTL + 1)
            )
        )

        for index in 0...HookSocketServer.toolUseIdCacheMaxEntries {
            server.cacheToolUseId(
                event: correlationEvent(sessionId: "session-\(index)", input: index),
                toolUseId: "tool-\(index)",
                now: now
            )
        }
        XCTAssertEqual(server.cachedToolUseEntryCount, HookSocketServer.toolUseIdCacheMaxEntries)
        XCTAssertNil(server.popCachedToolUseId(event: correlationEvent(sessionId: "session-0", input: 0), now: now))
        XCTAssertEqual(
            server.popCachedToolUseId(
                event: correlationEvent(sessionId: "session-\(HookSocketServer.toolUseIdCacheMaxEntries)", input: HookSocketServer.toolUseIdCacheMaxEntries),
                now: now
            ),
            "tool-\(HookSocketServer.toolUseIdCacheMaxEntries)"
        )
    }

    func testAllowAndDenyEachCompleteExactlyOnce() throws {
        for decision in ["allow", "deny"] {
            let sockets = try makeSocketPair()
            defer { close(sockets.peer) }
            let completion = expectation(description: "\(decision) completed")
            let recorder = PermissionCompletionRecorder()
            let server = HookSocketServer(permissionTimeoutProvider: { 1 })
            server.configurePermissionCompletionForTesting { sessionId, toolUseId, outcome in
                recorder.append((sessionId, toolUseId, outcome))
                completion.fulfill()
            }
            server.registerPendingPermissionForTesting(
                sessionId: "session-\(decision)",
                toolUseId: "tool-\(decision)",
                clientSocket: sockets.server,
                event: permissionEvent(sessionId: "session-\(decision)", toolUseId: "tool-\(decision)")
            )

            server.respondToPermission(toolUseId: "tool-\(decision)", decision: decision)
            wait(for: [completion], timeout: 1)
            let response = try JSONDecoder().decode(PermissionResponse.self, from: readResponse(from: sockets.peer))
            XCTAssertEqual(response.decision, decision)
            XCTAssertEqual(recorder.values.map(\.2), [.responded])
            XCTAssertEqual(server.pendingPermissionCount, 0)
        }
    }

    func testTimeoutDeniesAndLateResponseCannotCompleteTwice() throws {
        let sockets = try makeSocketPair()
        defer { close(sockets.peer) }
        let completion = expectation(description: "timeout completed")
        let recorder = PermissionCompletionRecorder()
        let server = HookSocketServer(
            permissionTimeoutProvider: { 0.03 },
            permissionDecisionProvider: { "deny" }
        )
        server.configurePermissionCompletionForTesting { sessionId, toolUseId, outcome in
            recorder.append((sessionId, toolUseId, outcome))
            completion.fulfill()
        }
        server.registerPendingPermissionForTesting(
            sessionId: "session-timeout",
            toolUseId: "tool-timeout",
            clientSocket: sockets.server,
            event: permissionEvent(sessionId: "session-timeout", toolUseId: "tool-timeout")
        )

        wait(for: [completion], timeout: 1)
        let response = try JSONDecoder().decode(PermissionResponse.self, from: readResponse(from: sockets.peer))
        XCTAssertEqual(response.decision, "deny")
        XCTAssertEqual(recorder.values.map(\.2), [.timedOut])

        server.respondToPermission(toolUseId: "tool-timeout", decision: "allow")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(server.pendingPermissionCount, 0)
    }

    func testCancelClosesSocketAndCompletesExactlyOnce() throws {
        let sockets = try makeSocketPair()
        defer { close(sockets.peer) }
        let completion = expectation(description: "cancel completed")
        let recorder = PermissionCompletionRecorder()
        let server = HookSocketServer(permissionTimeoutProvider: { 1 })
        server.configurePermissionCompletionForTesting { sessionId, toolUseId, outcome in
            recorder.append((sessionId, toolUseId, outcome))
            completion.fulfill()
        }
        server.registerPendingPermissionForTesting(
            sessionId: "session-cancel",
            toolUseId: "tool-cancel",
            clientSocket: sockets.server,
            event: permissionEvent(sessionId: "session-cancel", toolUseId: "tool-cancel")
        )

        server.cancelPendingPermission(toolUseId: "tool-cancel")
        wait(for: [completion], timeout: 1)
        XCTAssertEqual(recorder.values.map(\.2), [.cancelled])
        XCTAssertEqual(readResponse(from: sockets.peer), Data())

        server.cancelPendingPermission(toolUseId: "tool-cancel")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(recorder.values.count, 1)
    }

    private func permissionEvent(sessionId: String, toolUseId: String) -> HookEvent {
        HookEvent(
            event: .permissionRequest,
            sessionId: sessionId,
            toolUseId: toolUseId,
            toolName: "Bash",
            permission: "Run a command",
            status: "waiting_for_approval"
        )
    }

    private func correlationEvent(sessionId: String, input: Int) -> HookEvent {
        HookEvent(
            event: .preToolUse,
            sessionId: sessionId,
            toolUseId: "tool-\(input)",
            toolName: "Bash",
            rawData: "{\"tool_input\":{\"value\":\(input)}}"
        )
    }

    private func makeSocketPair() throws -> (server: Int32, peer: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (descriptors[0], descriptors[1])
    }

    private func readResponse(from socket: Int32) -> Data {
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 1_000) > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = read(socket, &buffer, buffer.count)
        guard count > 0 else { return Data() }
        return Data(buffer.prefix(count))
    }
}

private final class PermissionCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, String, PermissionTerminalOutcome)] = []

    var values: [(String, String, PermissionTerminalOutcome)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: (String, String, PermissionTerminalOutcome)) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
