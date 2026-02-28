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
