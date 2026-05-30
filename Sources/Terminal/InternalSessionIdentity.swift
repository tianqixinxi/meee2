import Foundation

public enum InternalSessionIdentity {
    public static func normalizedManagedWorkspacePath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizedPath(trimmed)
        guard isMeee2ManagedWorkspace(normalized) else { return nil }
        return normalized
    }

    public static func externalManagedWorkspaceMatchesInternal(
        cwd: String?,
        internalManagedWorkspaceCwds: Set<String>
    ) -> Bool {
        guard let normalized = normalizedManagedWorkspacePath(cwd) else { return false }
        return internalManagedWorkspaceCwds.contains(normalized)
    }

    public static func isMeee2ManagedWorkspace(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        let workspacesRoot = normalizedPath(
            (NSHomeDirectory() as NSString).appendingPathComponent(".meee2/workspaces")
        )
        return normalized == workspacesRoot || normalized.hasPrefix(workspacesRoot + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}
