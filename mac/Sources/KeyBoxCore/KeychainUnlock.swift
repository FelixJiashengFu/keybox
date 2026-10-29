import Foundation
import Security

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "钥匙串错误 \(status)"
    }
}

/// Optional "unlock without the master password": the vault key, kept as a generic password in the
/// user's login keychain. The app asks for Touch ID or the Mac login password (LocalAuthentication)
/// before it reads it.
public enum KeychainUnlock {
    static let service = "密钥匣 KeyBox"

    struct Stored: Codable {
        let salt: String
        let key: String
    }

    static func baseQuery(_ paths: DataPaths) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: paths.dir.path]
    }

    public static func store(_ vault: Vault, paths: DataPaths) throws {
        remove(paths)
        let payload = try JSONEncoder().encode(Stored(salt: vault.saltData.base64EncodedString(),
                                                      key: vault.exportKey().base64EncodedString()))
        var query = baseQuery(paths)
        query[kSecAttrLabel as String] = "密钥匣 KeyBox 解锁钥匙"
        query[kSecValueData as String] = payload
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func remove(_ paths: DataPaths) {
        SecItemDelete(baseQuery(paths) as CFDictionary)
    }

    /// The opened vault, or nil when there is no stored key or it is stale (it is then removed).
    public static func open(_ paths: DataPaths) -> Vault? {
        var query = baseQuery(paths)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let key = Data(base64Encoded: stored.key)
        else { return nil }
        do {
            return try Vault.open(at: paths.vault, key: key)
        } catch VaultError.wrongPassword {
            remove(paths)
            return nil
        } catch {
            return nil
        }
    }
}
