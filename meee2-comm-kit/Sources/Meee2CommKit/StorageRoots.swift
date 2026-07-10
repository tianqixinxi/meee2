import Foundation

/// One process-wide filesystem contract for runtime state. Production keeps
/// established locations; tests and integration runners can redirect every
/// durable store with `MEEE2_STORAGE_ROOT` before any singleton initializes.
public struct StorageRoots {
    public let homeDirectory: URL
    public let baseDirectory: URL
    public let logsDirectory: URL
    public let logFileURL: URL
    public let communication: CommKitStoragePaths

    public init(
        homeDirectory: URL,
        baseDirectory: URL,
        logsDirectory: URL? = nil,
        communication: CommKitStoragePaths? = nil
    ) {
        let home = homeDirectory.standardizedFileURL
        let base = baseDirectory.standardizedFileURL
        let logs = (logsDirectory ?? base.appendingPathComponent("logs", isDirectory: true))
            .standardizedFileURL
        self.homeDirectory = home
        self.baseDirectory = base
        self.logsDirectory = logs
        logFileURL = logs.appendingPathComponent("meee2.log")
        self.communication = communication ?? CommKitStoragePaths(baseDirectory: base)
    }

    public static let processDefault: StorageRoots = {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let explicitRoot = firstNonEmpty(
            environment["MEEE2_STORAGE_ROOT"],
            environment["MEEE2_COMM_KIT_STORAGE_ROOT"]
        )

        if !explicitRoot.isEmpty {
            let base = URL(fileURLWithPath: explicitRoot, isDirectory: true)
            return StorageRoots(homeDirectory: home, baseDirectory: base)
        }

        if isRunningTests(environment: environment) {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("meee2-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return StorageRoots(homeDirectory: home, baseDirectory: base)
        }

        let base = home.appendingPathComponent(".meee2", isDirectory: true)
        let inbox = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("teams", isDirectory: true)
            .appendingPathComponent("meee2", isDirectory: true)
            .appendingPathComponent("inboxes", isDirectory: true)
        let logs = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        return StorageRoots(
            homeDirectory: home,
            baseDirectory: base,
            logsDirectory: logs,
            communication: CommKitStoragePaths(baseDirectory: base, inboxDirectory: inbox)
        )
    }()

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func isRunningTests(environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if Bundle.main.bundlePath.lowercased().contains(".xctest") { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.lowercased().contains(".xctest") }) {
            return true
        }
        let executable = CommandLine.arguments.first?.lowercased() ?? ""
        if executable.contains(".xctest") { return true }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        return processName.contains("packagetests") || processName == "xctest"
    }
}
