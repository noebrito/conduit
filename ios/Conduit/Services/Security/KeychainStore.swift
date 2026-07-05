import Foundation
import Security

/// Secure storage for the two secrets Conduit keeps on-device:
///
/// - `webhook_bearer_token` — the user's webhook auth token, written when they
///   configure a webhook. Never displayed again after first save (§8).
/// - `device_id` — a per-install UUID generated once on first launch. It is
///   intentionally stored in the Keychain (not UserDefaults) so it survives app
///   reinstalls, keeping the user's downstream pipeline coherent (§4.8).
///
/// Both items use `kSecAttrAccessibleAfterFirstUnlock` so background work that
/// wakes after a device reboot — before the user has unlocked — can still read
/// the token and device id (§4.8).
final class KeychainStore {
    static let shared = KeychainStore()

    /// Keychain service namespace for all Conduit items.
    private let service = "dev.noebrito.Conduit"

    /// Account keys for the stored items.
    private enum Account {
        static let bearerToken = "webhook_bearer_token"
        static let deviceID = "device_id"
    }

    init() {}

    // MARK: - Webhook bearer token

    /// The currently stored webhook bearer token, if any.
    var webhookBearerToken: String? {
        readString(account: Account.bearerToken)
    }

    /// Store (or replace) the webhook bearer token.
    @discardableResult
    func setWebhookBearerToken(_ token: String) -> Bool {
        write(Data(token.utf8), account: Account.bearerToken)
    }

    /// Remove the stored webhook bearer token (e.g. on webhook reset).
    @discardableResult
    func deleteWebhookBearerToken() -> Bool {
        delete(account: Account.bearerToken)
    }

    // MARK: - Device id

    /// The stable per-install device id. Generated and persisted on first access
    /// and reused thereafter (including across reinstalls).
    var deviceID: String {
        if let existing = readString(account: Account.deviceID) {
            return existing
        }
        let generated = UUID().uuidString
        write(Data(generated.utf8), account: Account.deviceID)
        return generated
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    private func write(_ data: Data, account: String) -> Bool {
        // Upsert: try to update an existing item first, fall back to adding.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func readString(account: String) -> String? {
        guard let data = read(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
