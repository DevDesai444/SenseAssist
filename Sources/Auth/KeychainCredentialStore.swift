import Foundation
import LocalAuthentication
import Security

public enum KeychainCredentialError: Error, LocalizedError {
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case decodeFailed
    case deleteFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            return "Failed to save credential in keychain (status: \(status))"
        case let .loadFailed(status):
            return "Failed to load credential from keychain (status: \(status))"
        case .decodeFailed:
            return "Failed to decode keychain credential"
        case let .deleteFailed(status):
            return "Failed to delete credential from keychain (status: \(status))"
        }
    }
}

public final class KeychainCredentialStore: CredentialStore {
    private let serviceName: String
    private let allowUserInteraction: Bool

    public init(serviceName: String = "com.senseassist.oauth", allowUserInteraction: Bool = true) {
        self.serviceName = serviceName
        self.allowUserInteraction = allowUserInteraction
    }

    public func save(_ credential: OAuthCredential, provider: CredentialProvider, accountID: String) throws {
        let keychainAccount = keychainAccountName(provider: provider, accountID: accountID)
        let data = try JSONEncoder().encode(credential)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keychainAccount
        ]
        let effectiveQuery = applyAuthenticationUIPolicy(query)

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(effectiveQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainCredentialError.saveFailed(status: updateStatus)
        }

        var addQuery = effectiveQuery
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.saveFailed(status: addStatus)
        }
    }

    public func load(provider: CredentialProvider, accountID: String) throws -> OAuthCredential? {
        let keychainAccount = keychainAccountName(provider: provider, accountID: accountID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let effectiveQuery = applyAuthenticationUIPolicy(query)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(effectiveQuery as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainCredentialError.loadFailed(status: status)
        }

        guard let data = item as? Data else {
            throw KeychainCredentialError.decodeFailed
        }

        return try JSONDecoder().decode(OAuthCredential.self, from: data)
    }

    public func delete(provider: CredentialProvider, accountID: String) throws {
        let keychainAccount = keychainAccountName(provider: provider, accountID: accountID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw KeychainCredentialError.deleteFailed(status: status)
    }

    private func keychainAccountName(provider: CredentialProvider, accountID: String) -> String {
        "\(provider.rawValue)|\(accountID)"
    }

    private func applyAuthenticationUIPolicy(_ query: [String: Any]) -> [String: Any] {
        guard !allowUserInteraction else {
            return query
        }

        let context = LAContext()
        context.interactionNotAllowed = true

        var adjusted = query
        adjusted[kSecUseAuthenticationContext as String] = context
        return adjusted
    }
}
