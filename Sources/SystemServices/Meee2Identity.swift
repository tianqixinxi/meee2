import Foundation

/// 单点维护两件 meee2 的稳定身份/端点信息:
///
///   * `machineId`  — 一次生成、UserDefaults 持久化的 v4 UUID。
///     之前直接用 `Host.current().name` 写进 ~/.meee2/settings.json,
///     hostname 变动(改 Mac 名字、切网络、迁移设备)会让 reporter / 桌面端
///     在同一台机器上看起来像两台机器,session 出现孤儿。Pusher 那边的
///     兜底是 `defaults.string(forKey: "meee2MachineId") ?? "unknown"`,
///     而 "unknown" 这个值从来没被人显式写入过,所以默认就一直走 fallback。
///     用一个稳定 UUID 把两边对齐。
///
///   * `apiUrl`     — meee2-online 的 base URL(MCP server 走的是这套 HTTP API,
///     M1 让它默认走 fetch /api/v1/* 替代直连 Supabase RPC)。99% 的用户
///     是公网 SaaS,所以 `https://meee2.online` 作为 fallback;UserDefaults
///     `meee2ApiUrl` 提供 self-hosted 覆盖入口,callback 接到 `api_url`
///     参数时会写它。
public enum Meee2Identity {
    private static let machineIdKey = "meee2MachineId"
    private static let apiUrlKey = "meee2ApiUrl"
    private static let defaultApiUrl = "https://meee2.online"

    /// Stable UUID identifying this physical machine. First call generates +
    /// persists; subsequent calls return the persisted value.
    public static var machineId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: machineIdKey),
           !existing.isEmpty,
           existing != "unknown" {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: machineIdKey)
        NSLog("[Meee2Identity] generated machineId \(fresh)")
        return fresh
    }

    /// meee2-online HTTP API base URL — used by the MCP server to route
    /// writes through Next.js routes (`/api/v1/*`) instead of direct Supabase
    /// RPC. Returns the user override when present, otherwise the SaaS
    /// default. Trailing slash is stripped to match the JS-side path joining.
    public static var apiUrl: String {
        apiUrlOverride ?? defaultApiUrl
    }

    /// User-supplied override (self-hosted deployments) — `nil` when the
    /// user has not set anything. Callers that should fall through to local
    /// discovery when no override is set (e.g. MCP env injection) should
    /// branch on this rather than `apiUrl`, otherwise they pin every install
    /// to the SaaS host and the MCP server's local-first BoardServer
    /// discovery is bypassed.
    public static var apiUrlOverride: String? {
        let raw = UserDefaults.standard.string(forKey: apiUrlKey)
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// Called from the OAuth callback handler when meee2-online forwards
    /// its own base URL via `api_url`. Empty / blank values are ignored so
    /// a missing param does not clobber a previously-set override.
    public static func setApiUrlIfProvided(_ raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UserDefaults.standard.set(raw, forKey: apiUrlKey)
    }
}
