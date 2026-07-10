import Foundation
import LocalAuthentication
import Security

/// Minimal credential-store contract so security-sensitive clients can be
/// exercised with an in-memory store instead of a developer's real Keychain.
public protocol SecureCredentialStoring: AnyObject {
    func read(account: String) -> String?

    @discardableResult
    func write(_ value: String, account: String) -> Bool

    @discardableResult
    func delete(account: String) -> Bool

    @discardableResult
    func deleteAll() -> Bool
}

/// Small Keychain-backed credential store shared by the Board and online clients.
/// Values are never mirrored into UserDefaults or JSON files.
public final class SecureCredentialStore: SecureCredentialStoring {
    public static let shared = SecureCredentialStore()

    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.meee2.app") {
        self.service = service
    }

    public func read(account: String) -> String? {
        let context = nonInteractiveContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Runtime state reads must never summon Keychain UI and stall the
            // main actor / local control plane. A locked Keychain is treated
            // as temporarily unavailable and can be retried later.
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return delete(account: account)
        }
        let context = nonInteractiveContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        let context = nonInteractiveContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete every credential owned by the meee2 Keychain service. Normal
    /// disconnect and auth-expiry flows delete their account only; this broader
    /// operation is reserved for the explicitly confirmed factory-reset path.
    @discardableResult
    public func deleteAll() -> Bool {
        let context = nonInteractiveContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
