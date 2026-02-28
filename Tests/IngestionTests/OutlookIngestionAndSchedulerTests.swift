import CoreContracts
import Foundation
import Ingestion
import LLMRuntime
import OutlookIntegration
import Storage
import Testing

@Test func outlookSyncPersistsCursorAndTasks() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let message = OutlookMessage(
        messageID: "o-1",
        conversationID: "c-1",
        receivedDateTime: Date(),
        from: "noreply@buffalo.edu",
        subject: "CSE331 quiz due by March 3",
        bodyText: "Please submit by March 3 at 5pm",
        links: ["https://ublearns.buffalo.edu"]
    )

    let client = StubOutlookClient(
        pages: [
            (cursor: nil, messages: [message], nextCursor: "o-cursor-1"),
            (cursor: "o-cursor-1", messages: [], nextCursor: "o-cursor-1")
        ]
    )

    let service = OutlookIngestionService(
        outlookClient: client,
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

    let second = try await service.sync()
    #expect(second.fetchedMessages == 0)
    #expect(second.createdOrUpdatedTasks == 0)
}

@Test func adaptiveSchedulerUsesConfiguredIntervals() {
    let config = SyncConfiguration(activePollingMinutes: 5, normalPollingMinutes: 15, idlePollingMinutes: 45, maxBackoffMinutes: 120)

    let active = AdaptiveSyncScheduler.nextInterval(for: .active, config: config, seed: 7)
    let normal = AdaptiveSyncScheduler.nextInterval(for: .normal, config: config, seed: 7)
    let idle = AdaptiveSyncScheduler.nextInterval(for: .idle, config: config, seed: 7)
    let error = AdaptiveSyncScheduler.nextInterval(for: .error(retryCount: 3), config: config, seed: 7)

    #expect(active.delayMinutes == 5)
    #expect(normal.delayMinutes == 15)
    #expect(idle.delayMinutes == 45)
    #expect(error.delayMinutes == 40)
    #expect(active.jitterSeconds == 7)
}

@Test func adaptiveSchedulerCapsBackoffAtMaximum() {
    let config = SyncConfiguration(activePollingMinutes: 10, normalPollingMinutes: 15, idlePollingMinutes: 30, maxBackoffMinutes: 60)
    let decision = AdaptiveSyncScheduler.nextInterval(for: .error(retryCount: 8), config: config, seed: 99)

    #expect(decision.delayMinutes == 60)
    #expect(decision.jitterSeconds <= 30)
}
