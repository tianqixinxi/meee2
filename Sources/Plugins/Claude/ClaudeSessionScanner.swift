import Foundation
import PeerPluginKit

/// CSM 会话数据 (从 ~/.csm/sessions/*.json 解析)
struct CSMSessionData {
    let sessionId: String
    let project: String
    var pid: Int?
    var transcriptPath: String?
    var startedAt: String       // ISO 8601
    var lastActivity: String    // ISO 8601
    var status: String          // idle/active/waiting/dead/completed
    var detailedStatus: String? // thinking/tooling/permissionRequired/...
    var currentTool: String?
    var currentTask: String?
    var description: String?
    var progress: String?
    var terminalInfo: TerminalInfo?
    var ghosttyTerminalId: String?

    var projectName: String {
        URL(fileURLWithPath: project).lastPathComponent
    }

    var startedAtDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: startedAt) ?? Date()
    }

    var lastActivityDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: lastActivity) ?? Date()
    }

    /// 从 CSM JSON 解析
    static func from(json: [String: Any]) -> CSMSessionData? {
        guard let sessionId = json["session_id"] as? String,
              let project = json["project"] as? String else { return nil }

        var termInfo: TerminalInfo?
        if let ti = json["terminal_info"] as? [String: Any] {
            termInfo = TerminalInfo(
                tty: ti["tty"] as? String,
                termProgram: ti["term_program"] as? String,
                termBundleId: ti["term_bundle_id"] as? String,
                cmuxSocketPath: ti["cmux_socket_path"] as? String,
                cmuxSurfaceId: ti["cmux_surface_id"] as? String
            )
        }

        return CSMSessionData(
            sessionId: sessionId,
            project: project,
            pid: json["pid"] as? Int,
            transcriptPath: json["transcript_path"] as? String,
            startedAt: json["started_at"] as? String ?? "",
            lastActivity: json["last_activity"] as? String ?? "",
            status: json["status"] as? String ?? "idle",
            detailedStatus: json["detailed_status"] as? String,
            currentTool: json["current_tool"] as? String,
            currentTask: json["current_task"] as? String,
            description: json["description"] as? String,
            progress: json["progress"] as? String,
            terminalInfo: termInfo,
            ghosttyTerminalId: json["ghostty_terminal_id"] as? String
        )
    }
}

/// 监听 CSM sessions 目录变化
/// 读取 ~/.csm/sessions/ (由 CSM hooks 写入)
class ClaudeSessionScanner {
    private let csmSessionsPath: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private let parseQueue = DispatchQueue(label: "com.peerisland.claude.scanner", qos: .userInitiated)

    /// 当前扫描到的 CSM 会话
    private(set) var currentSessions: [CSMSessionData] = []

    /// 会话更新回调
    var onSessionsChanged: (([CSMSessionData]) -> Void)?

    init() {
        csmSessionsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".csm")
            .appendingPathComponent("sessions")
    }

    deinit { stop() }

    func start() {
        guard FileManager.default.fileExists(atPath: csmSessionsPath.path) else {
            NSLog("[ClaudeSessionScanner] CSM sessions directory not found: \(csmSessionsPath.path)")
            NSLog("[ClaudeSessionScanner] Run 'csm install' to set up CSM")
            return
        }

        refresh()
        setupFileWatcher()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NSLog("[ClaudeSessionScanner] Started monitoring: \(csmSessionsPath.path)")
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        parseQueue.async { [weak self] in
            guard let self else { return }
            let sessions = self.loadFromCSMDirectory()

            DispatchQueue.main.async {
                self.currentSessions = sessions
                self.onSessionsChanged?(sessions)
            }
        }
    }

    // MARK: - Private

    private func setupFileWatcher() {
        let descriptor = open(csmSessionsPath.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: parseQueue
        )
        fileSource?.setEventHandler { [weak self] in self?.refresh() }
        fileSource?.setCancelHandler { close(descriptor) }
        fileSource?.resume()
    }

    private func loadFromCSMDirectory() -> [CSMSessionData] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: csmSessionsPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url -> CSMSessionData? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return CSMSessionData.from(json: json)
        }.sorted { $0.lastActivityDate > $1.lastActivityDate }
    }
}
