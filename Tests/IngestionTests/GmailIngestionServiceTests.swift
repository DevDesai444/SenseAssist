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
            (cursor: nil, messages: [message], nextCursor: "c1"),
            (cursor: "c1", messages: [], nextCursor: "c1")
        ]
    )

    let service = GmailIngestionService(
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
    #expect(first.nextCursor == "c1")

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

    let gmail = StubGmailClient(pages: [(cursor: nil, messages: [suspicious], nextCursor: "c2")])

    let service = GmailIngestionService(
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
