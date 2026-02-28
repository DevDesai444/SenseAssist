import Foundation

public enum CredentialProvider: String, Sendable {
    case gmail
    case outlook
    case slackBot = "slack_bot"
    case slackApp = "slack_app"
}

public struct OAuthCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtUTC: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAtUTC: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtUTC = expiresAtUTC
    }

    public var isExpired: Bool {
        guard let expiresAtUTC else { return false }
        return expiresAtUTC <= Date()
    }
}

public protocol CredentialStore: Sendable {
    func save(_ credential: OAuthCredential, provider: CredentialProvider, accountID: String) throws
    func load(provider: CredentialProvider, accountID: String) throws -> OAuthCredential?
    func delete(provider: CredentialProvider, accountID: String) throws
}

public final class EnvironmentCredentialStore: CredentialStore {
    private let env: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = environment
    }

    public func save(_ credential: OAuthCredential, provider: CredentialProvider, accountID: String) throws {
        _ = credential
        _ = provider
        _ = accountID
        throw NSError(domain: "EnvironmentCredentialStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Environment store is read-only"])
    }

    public func load(provider: CredentialProvider, accountID: String) throws -> OAuthCredential? {
        let key = envKey(provider: provider, accountID: accountID)
        guard let token = env[key], !token.isEmpty else {
            return nil
        }
        return OAuthCredential(accessToken: token)
    }

    public func delete(provider: CredentialProvider, accountID: String) throws {
        _ = provider
        _ = accountID
        throw NSError(domain: "EnvironmentCredentialStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Environment store is read-only"])
    }

    private func envKey(provider: CredentialProvider, accountID: String) -> String {
        let normalizedAccount = accountID
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
            .uppercased()
        return "SENSEASSIST_TOKEN_\(provider.rawValue.uppercased())_\(normalizedAccount)"
    }
}

public final class ChainedCredentialStore: CredentialStore {
    private let stores: [CredentialStore]

    public init(stores: [CredentialStore]) {
        self.stores = stores
    }

    public func save(_ credential: OAuthCredential, provider: CredentialProvider, accountID: String) throws {
        guard let primary = stores.first else {
            return
        }
        try primary.save(credential, provider: provider, accountID: accountID)
    }

    public func load(provider: CredentialProvider, accountID: String) throws -> OAuthCredential? {
        for store in stores {
            if let credential = try store.load(provider: provider, accountID: accountID) {
                return credential
            }
        }
        return nil
    }

    public func delete(provider: CredentialProvider, accountID: String) throws {
        for store in stores {
            try? store.delete(provider: provider, accountID: accountID)
        }
    }
}
