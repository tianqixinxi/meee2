import Foundation
import SwiftUI

/// 使用统计追踪器 - 通过 Supabase 收集匿名使用统计
public class UsageTracker {
    public static let shared = UsageTracker()

    // MARK: - Supabase 配置

    private let supabaseUrl = "https://mpypmxskhowzumxgaxnr.supabase.co"
    private let supabaseKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1weXBteHNraG93enVteGdheG5yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU4Mjg5MDcsImV4cCI6MjA5MTQwNDkwN30.OYvnj4eSDkDXrSxo7IN3H78JXG3oyOhy3jhdvTw4FSg"

    // MARK: - 用户设置

    /// 是否启用统计（用户可在设置中关闭）
    @AppStorage("usageTrackingEnabled") var enabled: Bool = true

    /// 设备唯一标识（首次启动生成，存储在 UserDefaults）
    @AppStorage("usageDeviceId") var deviceId: String = ""

    // MARK: - Public

    /// 发送启动事件（异步发送，不阻塞）
    public func trackLaunch() {
        guard enabled else {
            NSLog("[UsageTracker] Tracking disabled by user")
            return
        }

        // 确保 device_id 存在
        if deviceId.isEmpty {
            deviceId = UUID().uuidString
            NSLog("[UsageTracker] Generated new device ID: \(deviceId)")
        }

        sendEventAsync()
    }

    // MARK: - Private

    private func sendEventAsync() {
        let payload = buildPayload()

        Task {
            await sendEvent(payload: payload)
        }
    }

    private func sendEvent(payload: [String: Any]) async {
        guard let url = URL(string: "\(supabaseUrl)/rest/v1/usage_events"),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            NSLog("[UsageTracker] Failed to build request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                NSLog("[UsageTracker] Event sent, status: \(httpResponse.statusCode)")
            }
        } catch {
            NSLog("[UsageTracker] Failed to send event: \(error)")
        }
    }

    private func buildPayload() -> [String: Any] {
        return [
            "device_id": deviceId,
            "app_version": getAppVersion(),
            "os_version": getOSVersion(),
            "mac_model": getMacModel(),
            "language": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "event_type": "launch"
        ]
    }

    private func getAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func getOSVersion() -> String {
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func getMacModel() -> String {
        // 简化：只返回设备类型
        let hostName = ProcessInfo.processInfo.hostName
        return hostName.contains("MacBook") ? "MacBook" : "Mac"
    }
}