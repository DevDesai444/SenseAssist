import CoreContracts
import Foundation
import GmailIntegration
import Ingestion
import LLMRuntime
import OutlookIntegration
import Storage
import Testing

@Test func multiAccountCoordinatorSyncsThreeGmailAndOneOutlook() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let accountRepository = AccountRepository(store: store)
    let configured: [ConnectedEmailAccount] = [
        ConnectedEmailAccount(accountID: "gmail:devdesaiyt@gmail.com", provider: .gmail, email: "devdesaiyt@gmail.com"),
        ConnectedEmailAccount(accountID: "gmail:devdesaiofficial@gmail.com", provider: .gmail, email: "devdesaiofficial@gmail.com"),
        ConnectedEmailAccount(accountID: "gmail:devdesaiyttt@gmail.com", provider: .gmail, email: "devdesaiyttt@gmail.com"),
        ConnectedEmailAccount(accountID: "outlook:devchira@buffalo.edu", provider: .outlook, email: "devchira@buffalo.edu")
    ]

    for account in configured {
        try accountRepository.upsert(account)
    }

    let coordinator = MultiAccountSyncCoordinator(
        accountRepository: accountRepository,
        cursorRepository: ProviderCursorRepository(store: store),
        updateRepository: UpdateRepository(store: store),
        taskRepository: TaskRepository(store: store),
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80,
        gmailClientFactory: { account in
            guard account.provider == .gmail else { return nil }
            let message = GmailMessage(
                messageID: "shared-id-1",
                threadID: "thread-\(account.accountID)",
                internalDate: Date(),
                from: "noreply@buffalo.edu",
                subject: "CSE312 assignment due on March 2",
                bodyText: "Account \(account.email) update due on March 2 at 11:59pm.",
                links: ["https://ublearns.buffalo.edu"]
            )
            return StubGmailClient(
                pages: [
                    (
                        cursor: nil,
                        messages: [message],
                        nextCursor: GmailSyncCursor(
                            internalDateSeconds: Int(message.internalDate.timeIntervalSince1970),
                            messageID: message.messageID
                        )
                    )
                ]
            )
        },
        outlookClientFactory: { account in
            guard account.provider == .outlook else { return nil }
            let message = OutlookMessage(
                messageID: "shared-id-1",
                conversationID: "conv-1",
                receivedDateTime: Date(),
                from: "noreply@buffalo.edu",
                subject: "CSE331 quiz due by March 3",
                bodyText: "Account \(account.email) quiz due by March 3 at 5pm.",
                links: ["https://ublearns.buffalo.edu"]
            )
            return StubOutlookClient(
                pages: [
                    (
                        cursor: nil,
                        messages: [message],
                        nextCursor: OutlookSyncCursor(
                            receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
                            messageID: message.messageID
                        )
                    )
                ]
            )
        }
    )

    let result = try await coordinator.syncAllEnabledAccounts()

    #expect(result.gmail.count == 3)
    #expect(result.outlook.count == 1)
    #expect(result.failures.isEmpty)
    #expect(result.totalFetched == 4)

    let updates = UpdateRepository(store: store)
    #expect(try updates.count(source: .gmail, accountID: "gmail:devdesaiyt@gmail.com") == 1)
    #expect(try updates.count(source: .gmail, accountID: "gmail:devdesaiofficial@gmail.com") == 1)
    #expect(try updates.count(source: .gmail, accountID: "gmail:devdesaiyttt@gmail.com") == 1)
    #expect(try updates.count(source: .outlook, accountID: "outlook:devchira@buffalo.edu") == 1)
}

@Test func multiAccountCoordinatorContinuesAfterSingleAccountSyncFailure() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let accountRepository = AccountRepository(store: store)
    let configured: [ConnectedEmailAccount] = [
        ConnectedEmailAccount(accountID: "gmail:ok@gmail.com", provider: .gmail, email: "ok@gmail.com"),
        ConnectedEmailAccount(accountID: "gmail:fail@gmail.com", provider: .gmail, email: "fail@gmail.com"),
        ConnectedEmailAccount(accountID: "outlook:ok@contoso.com", provider: .outlook, email: "ok@contoso.com")
    ]

    for account in configured {
        try accountRepository.upsert(account)
    }

    let coordinator = MultiAccountSyncCoordinator(
        accountRepository: accountRepository,
        cursorRepository: ProviderCursorRepository(store: store),
        updateRepository: UpdateRepository(store: store),
        taskRepository: TaskRepository(store: store),
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80,
        gmailClientFactory: { account in
            guard account.provider == .gmail else { return nil }
            if account.accountID == "gmail:fail@gmail.com" {
                return FailingGmailClient()
            }

            let message = GmailMessage(
                messageID: "gmail-success-msg",
                threadID: "thread-\(account.accountID)",
                internalDate: Date(),
                from: "noreply@buffalo.edu",
                subject: "Lab due tomorrow",
                bodyText: "Submit lab tomorrow at 5pm.",
                links: []
            )
            return StubGmailClient(
                pages: [
                    (
                        cursor: nil,
                        messages: [message],
                        nextCursor: GmailSyncCursor(
                            internalDateSeconds: Int(message.internalDate.timeIntervalSince1970),
                            messageID: message.messageID
                        )
                    )
                ]
            )
        },
        outlookClientFactory: { account in
            guard account.provider == .outlook else { return nil }
            let message = OutlookMessage(
                messageID: "outlook-success-msg",
                conversationID: "conv-\(account.accountID)",
                receivedDateTime: Date(),
                from: "noreply@buffalo.edu",
                subject: "Quiz deadline reminder",
                bodyText: "Quiz closes at 9pm.",
                links: []
            )
            return StubOutlookClient(
                pages: [
                    (
                        cursor: nil,
                        messages: [message],
                        nextCursor: OutlookSyncCursor(
                            receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
                            messageID: message.messageID
                        )
                    )
                ]
            )
        }
    )

    let result = try await coordinator.syncAllEnabledAccounts()

    #expect(result.gmail.count == 1)
    #expect(result.outlook.count == 1)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.provider == .gmail)
    #expect(result.failures.first?.accountID == "gmail:fail@gmail.com")
    #expect(result.totalFetched == 2)

    let updates = UpdateRepository(store: store)
    #expect(try updates.count(source: .gmail, accountID: "gmail:ok@gmail.com") == 1)
    #expect(try updates.count(source: .gmail, accountID: "gmail:fail@gmail.com") == 0)
    #expect(try updates.count(source: .outlook, accountID: "outlook:ok@contoso.com") == 1)
}

private struct FailingGmailClient: GmailClient {
    func fetchMessages(since _: GmailSyncCursor?) async throws -> ([GmailMessage], nextCursor: GmailSyncCursor?) {
        throw StubClientError.forcedFailure("forced gmail failure")
    }
}

private enum StubClientError: Error, LocalizedError, Sendable {
    case forcedFailure(String)

    var errorDescription: String? {
        switch self {
        case let .forcedFailure(message):
            return message
        }
    }
}
