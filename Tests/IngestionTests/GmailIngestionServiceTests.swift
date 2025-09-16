import CoreContracts
import Foundation
import GmailIntegration
import Ingestion
import LLMRuntime
import Storage
import Testing

@Test func gmailSyncPersistsCursorAndTasksIncrementally() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let message = GmailMessage(
        messageID: "m-1",
        threadID: "t-1",
        internalDate: Date(),
        from: "noreply@buffalo.edu",
        subject: "CSE312 assignment due on March 2",
        bodyText: "Assignment posted due on March 2 at 11:59pm.",
        links: ["https://ublearns.buffalo.edu"]
    )

    let gmail = StubGmailClient(
        pages: [
            (cursor: nil, messages: [message], nextCursor: GmailSyncCursor(internalDateSeconds: Int(message.internalDate.timeIntervalSince1970), messageID: message.messageID)),
            (cursor: GmailSyncCursor(internalDateSeconds: Int(message.internalDate.timeIntervalSince1970), messageID: message.messageID), messages: [], nextCursor: GmailSyncCursor(internalDateSeconds: Int(message.internalDate.timeIntervalSince1970), messageID: message.messageID))
        ]
    )

    let service = GmailIngestionService(
        accountID: "gmail:devdesaiyt@gmail.com",
        accountEmail: "devdesaiyt@gmail.com",
        gmailClient: gmail,
        cursorRepository: ProviderCursorRepository(store: store),
        updateRepository: UpdateRepository(store: store),
        taskRepository: TaskRepository(store: store),
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80
    )

    let first = try await service.sync()
    #expect(first.fetchedMessages == 1)
    #expect(first.storedUpdates == 1)
    #expect(first.createdOrUpdatedTasks == 1)
    #expect(first.nextCursor == "\(Int(message.internalDate.timeIntervalSince1970))")

    let second = try await service.sync()
    #expect(second.fetchedMessages == 0)
    #expect(second.storedUpdates == 0)
    #expect(second.createdOrUpdatedTasks == 0)

    let taskCount = try TaskRepository(store: store).count()
    #expect(taskCount == 1)
}

@Test func gmailSyncSkipsLowConfidenceTaskExtraction() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let suspicious = GmailMessage(
        messageID: "m-2",
        internalDate: Date(),
        from: "unknown@external.com",
        subject: "URGENT assignment",
        bodyText: "Do this now",
        links: []
    )

    let gmail = StubGmailClient(
        pages: [
            (
                cursor: nil,
                messages: [suspicious],
                nextCursor: GmailSyncCursor(
                    internalDateSeconds: Int(suspicious.internalDate.timeIntervalSince1970),
                    messageID: suspicious.messageID
                )
            )
        ]
    )

    let service = GmailIngestionService(
        accountID: "gmail:devdesaiofficial@gmail.com",
        accountEmail: "devdesaiofficial@gmail.com",
        gmailClient: gmail,
        cursorRepository: ProviderCursorRepository(store: store),
        updateRepository: UpdateRepository(store: store),
        taskRepository: TaskRepository(store: store),
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80
    )

    let summary = try await service.sync()

    #expect(summary.fetchedMessages == 1)
    #expect(summary.storedUpdates == 1)
    #expect(summary.createdOrUpdatedTasks == 0)
}

@Test func gmailSyncSupportsMultipleAccountsWithSameMessageID() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let sharedMessageA = GmailMessage(
        messageID: "shared-id-1",
        threadID: "thread-a",
        internalDate: Date(),
        from: "noreply@buffalo.edu",
        subject: "CSE312 assignment due on March 2",
        bodyText: "Account A assignment due on March 2 at 11:59pm.",
        links: ["https://ublearns.buffalo.edu"]
    )
    let sharedMessageB = GmailMessage(
        messageID: "shared-id-1",
        threadID: "thread-b",
        internalDate: Date(),
        from: "noreply@buffalo.edu",
        subject: "CSE312 assignment due on March 2",
        bodyText: "Account B assignment due on March 2 at 11:59pm.",
        links: ["https://ublearns.buffalo.edu"]
    )

    let repos = (
        cursor: ProviderCursorRepository(store: store),
        updates: UpdateRepository(store: store),
        tasks: TaskRepository(store: store)
    )

    let serviceA = GmailIngestionService(
        accountID: "gmail:devdesaiyt@gmail.com",
        accountEmail: "devdesaiyt@gmail.com",
        gmailClient: StubGmailClient(
            pages: [
                (
                    cursor: nil,
                    messages: [sharedMessageA],
                    nextCursor: GmailSyncCursor(
                        internalDateSeconds: Int(sharedMessageA.internalDate.timeIntervalSince1970),
                        messageID: sharedMessageA.messageID
                    )
                )
            ]
        ),
        cursorRepository: repos.cursor,
        updateRepository: repos.updates,
        taskRepository: repos.tasks,
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80
    )

    let serviceB = GmailIngestionService(
        accountID: "gmail:devdesaiofficial@gmail.com",
        accountEmail: "devdesaiofficial@gmail.com",
        gmailClient: StubGmailClient(
            pages: [
                (
                    cursor: nil,
                    messages: [sharedMessageB],
                    nextCursor: GmailSyncCursor(
                        internalDateSeconds: Int(sharedMessageB.internalDate.timeIntervalSince1970),
                        messageID: sharedMessageB.messageID
                    )
                )
            ]
        ),
        cursorRepository: repos.cursor,
        updateRepository: repos.updates,
        taskRepository: repos.tasks,
        llmRuntime: StubLLMRuntime(),
        confidenceThreshold: 0.80
    )

    let summaryA = try await serviceA.sync()
    let summaryB = try await serviceB.sync()

    #expect(summaryA.storedUpdates == 1)
    #expect(summaryB.storedUpdates == 1)

    let updateCountA = try repos.updates.count(source: .gmail, accountID: "gmail:devdesaiyt@gmail.com")
    let updateCountB = try repos.updates.count(source: .gmail, accountID: "gmail:devdesaiofficial@gmail.com")
    #expect(updateCountA == 1)
    #expect(updateCountB == 1)
}
