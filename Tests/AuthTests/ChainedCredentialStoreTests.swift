import Auth
import Testing

@Test func chainedCredentialStoreFallsBackWhenPrimaryLoadThrows() throws {
    let expected = OAuthCredential(accessToken: "env-token")
    let store = ChainedCredentialStore(
        stores: [
            ThrowingCredentialStore(),
            StaticCredentialStore(credential: expected)
        ]
    )

    let loaded = try store.load(provider: .gmail, accountID: "gmail:user@example.com")
    #expect(loaded == expected)
}

@Test func chainedCredentialStoreReturnsNilWhenAllStoresFailOrMiss() throws {
    let store = ChainedCredentialStore(
        stores: [
            ThrowingCredentialStore(),
            StaticCredentialStore(credential: nil)
        ]
    )

    let loaded = try store.load(provider: .outlook, accountID: "outlook:user@example.com")
    #expect(loaded == nil)
}

private struct ThrowingCredentialStore: CredentialStore {
    func save(_: OAuthCredential, provider _: CredentialProvider, accountID _: String) throws {}

    func load(provider _: CredentialProvider, accountID _: String) throws -> OAuthCredential? {
        throw TestCredentialError.unavailable
    }

    func delete(provider _: CredentialProvider, accountID _: String) throws {}
}

private struct StaticCredentialStore: CredentialStore {
    let credential: OAuthCredential?

    func save(_: OAuthCredential, provider _: CredentialProvider, accountID _: String) throws {}

    func load(provider _: CredentialProvider, accountID _: String) throws -> OAuthCredential? {
        credential
    }

    func delete(provider _: CredentialProvider, accountID _: String) throws {}
}

private enum TestCredentialError: Error, Sendable {
    case unavailable
}
