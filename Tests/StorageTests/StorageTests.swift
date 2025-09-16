import CryptoKit
import CoreContracts
import Foundation
import Storage
import Testing

@Test func storageBootstrapCreatesAndPassesHealth() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let config = SenseAssistConfiguration(databasePath: dbPath)
    let logger = ConsoleLogger(minimumLevel: .error)

    let result = try StorageBootstrap.run(config: config, logger: logger)

    #expect(result.healthy)
    #expect(FileManager.default.fileExists(atPath: dbPath))
}

@Test func storageInitializeIsIdempotentAcrossRestarts() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)

    do {
        let firstStore = SQLiteStore(databasePath: dbPath, logger: logger)
        try firstStore.initialize()
        firstStore.close()
    }

    let secondStore = SQLiteStore(databasePath: dbPath, logger: logger)
    try secondStore.initialize()
    let healthy = try secondStore.healthCheck()
    secondStore.close()

    #expect(healthy)
}

@Test func auditLogRepositoryWritesEntries() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let audit = AuditLogRepository(store: store)
    try audit.log(category: "slack_plan_command", severity: "info", message: "command_received", context: ["command": "today"])
    try audit.log(category: "slack_plan_command", severity: "info", message: "today_success", context: ["count": "2"])

    let count = try audit.count(category: "slack_plan_command")
    #expect(count == 2)
}

@Test func providerCursorRepositorySupportsMultipleAccounts() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let cursorRepo = ProviderCursorRepository(store: store)
    try cursorRepo.upsert(
        ProviderCursorRecord(
            provider: .gmail,
            accountID: "gmail:devdesaiyt@gmail.com",
            primary: "cursor-a"
        )
    )
    try cursorRepo.upsert(
        ProviderCursorRecord(
            provider: .gmail,
            accountID: "gmail:devdesaiofficial@gmail.com",
            primary: "cursor-b"
        )
    )

    let first = try cursorRepo.get(provider: .gmail, accountID: "gmail:devdesaiyt@gmail.com")
    let second = try cursorRepo.get(provider: .gmail, accountID: "gmail:devdesaiofficial@gmail.com")
    let list = try cursorRepo.list(for: .gmail)

    #expect(first?.primary == "cursor-a")
    #expect(second?.primary == "cursor-b")
    #expect(list.count == 2)
}

@Test func accountRepositoryPersistsConnectedAccounts() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let accounts = AccountRepository(store: store)
    try accounts.upsert(
        ConnectedEmailAccount(
            accountID: "gmail:devdesaiyt@gmail.com",
            provider: .gmail,
            email: "devdesaiyt@gmail.com"
        )
    )
    try accounts.upsert(
        ConnectedEmailAccount(
            accountID: "outlook:devchira@buffalo.edu",
            provider: .outlook,
            email: "devchira@buffalo.edu"
        )
    )

    let all = try accounts.list(enabledOnly: true)
    #expect(all.count == 2)
}

@Test func updateRepositoryUsesDeterministicSHA256ContentHash() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let bodyText = "Deterministic hash payload"
    let update = UpdateCard(
        accountID: "gmail:demo.student.one@example.com",
        source: .gmail,
        providerIDs: ProviderIDs(messageID: "msg-hash-1", threadID: "thread-1"),
        receivedAtUTC: Date(timeIntervalSince1970: 1_700_000_000),
        from: "noreply@buffalo.edu",
        subject: "Hash test",
        bodyText: bodyText,
        parserMethod: .ruleBased,
        parseConfidence: 0.95
    )

    let updates = UpdateRepository(store: store)
    _ = try updates.upsert([update])

    let rows = try store.fetchRows("SELECT content_hash FROM updates WHERE message_id = 'msg-hash-1' LIMIT 1;")
    let storedHash = rows.first?["content_hash"]

    let expectedHash = SHA256.hash(data: Data(bodyText.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(storedHash == expectedHash)
}

@Test func operationRepositoryTracksUndoableAndUndoneStates() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let operations = OperationRepository(store: store)
    let record = StoredOperationRecord(
        opID: UUID().uuidString,
        expectedPlanRevision: 10,
        appliedRevision: 11,
        intent: EditIntent.createBlock.rawValue,
        status: "applied",
        payloadJSON: "{\"intent\":\"create_block\"}",
        resultJSON: "{\"kind\":\"created_block\",\"blockID\":\"\(UUID().uuidString)\",\"ekEventID\":null,\"previousBlock\":null}"
    )

    try operations.insert(record)
    let latest = try operations.latestUndoableOperation()
    #expect(latest?.opID == record.opID)
    #expect(try operations.latestAppliedRevision() == 11)

    try operations.markUndone(opID: record.opID)
    let afterUndo = try operations.latestUndoableOperation()
    #expect(afterUndo == nil)
}

@Test func planRevisionRepositoryAppendsAndReadsLatestRevision() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let revisions = PlanRevisionRepository(store: store)
    let first = try revisions.append(trigger: "test_1", summary: PlanSummary(createdBlocks: 1, movedBlocks: 0, deletedBlocks: 0))
    let second = try revisions.append(trigger: "test_2", summary: PlanSummary(createdBlocks: 0, movedBlocks: 1, deletedBlocks: 1))

    #expect(first > 0)
    #expect(second > first)
    #expect(try revisions.latestRevisionID() == second)
}
