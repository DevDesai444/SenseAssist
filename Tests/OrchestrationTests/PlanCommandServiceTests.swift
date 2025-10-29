import CoreContracts
import EventKitAdapter
import Foundation
import Orchestration
import SlackIntegration
import Storage
import Testing

extension OperationRepository: @unchecked Sendable {}
extension PlanRevisionRepository: @unchecked Sendable {}

actor DeniedCalendarStore: CalendarStore {
    func ensureManagedCalendar(named name: String) async throws {
        _ = name
        throw CalendarStoreError.permissionDenied
    }

    func fetchManagedBlocks(on date: Date, calendar: Calendar) async throws -> [CalendarBlock] {
        _ = date
        _ = calendar
        return []
    }

    func createManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        _ = block
        _ = calendarName
        throw CalendarStoreError.permissionDenied
    }

    func updateManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        _ = block
        _ = calendarName
        throw CalendarStoreError.permissionDenied
    }

    func findManagedBlocks(fuzzyTitle: String, on date: Date?, calendar: Calendar) async throws -> [CalendarBlock] {
        _ = fuzzyTitle
        _ = date
        _ = calendar
        return []
    }

    func deleteManagedBlock(blockID: UUID, ekEventID: String?, calendarName: String) async throws {
        _ = blockID
        _ = ekEventID
        _ = calendarName
        throw CalendarStoreError.permissionDenied
    }
}

@Test func parserParsesAddCommand() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!

    let now = Date(timeIntervalSince1970: 1_709_251_200)
    let command = try PlanCommandParser.parse("add \"LeetCode\" 60m tomorrow 7:00pm", now: now, calendar: calendar)

    guard case let .add(title, _, duration) = command else {
        Issue.record("Expected add command")
        return
    }

    #expect(title == "LeetCode")
    #expect(duration == 60)
}

@Test func parserParsesUndoCommand() throws {
    let command = try PlanCommandParser.parse("undo", now: Date())
    #expect(command == .undo)
}

@Test func planServiceAddAndTodayFlow() async {
    let store = InMemoryCalendarStore()
    let service = PlanCommandService(calendarStore: store, initialPlanRevision: 10)

    let addResponse = await service.handle(commandText: "add \"CSE312 A2\" 90m today 6:00pm")
    #expect(!addResponse.requiresConfirmation)
    #expect(addResponse.planRevision == 11)
    #expect(addResponse.text.contains("Added"))

    let todayResponse = await service.handle(commandText: "today")
    #expect(todayResponse.text.contains("Today's plan"))
    #expect(todayResponse.text.contains("Deep Work: CSE312 A2"))
}

@Test func planServiceMoveRequiresClarificationOnAmbiguity() async {
    let store = InMemoryCalendarStore()
    let service = PlanCommandService(calendarStore: store, initialPlanRevision: 20)

    _ = await service.handle(commandText: "add \"Homework\" 60m today 5:00pm")
    _ = await service.handle(commandText: "add \"Homework\" 45m today 8:00pm")

    let moveResponse = await service.handle(commandText: "move \"Homework\" tomorrow 7:00pm")

    #expect(moveResponse.requiresConfirmation)
    #expect(moveResponse.text.contains("Ambiguous match"))
}

@Test func planServiceMoveUpdatesSingleMatch() async {
    let store = InMemoryCalendarStore()
    let service = PlanCommandService(calendarStore: store, initialPlanRevision: 30)

    _ = await service.handle(commandText: "add \"Interview Prep\" 60m today 5:00pm")

    let moveResponse = await service.handle(commandText: "move \"Interview Prep\" tomorrow 7:30pm 90m")

    #expect(!moveResponse.requiresConfirmation)
    #expect(moveResponse.text.contains("Moved"))
    #expect(moveResponse.planRevision == 32)
}

@Test func planServiceReturnsPermissionRemediation() async {
    let service = PlanCommandService(calendarStore: DeniedCalendarStore())
    let response = await service.handle(commandText: "today")

    #expect(response.text.contains("Enable Calendar permission"))
}

@Test func planServiceUndoRemovesLatestCreatedBlock() async {
    let store = InMemoryCalendarStore()
    let service = PlanCommandService(calendarStore: store, initialPlanRevision: 40)

    _ = await service.handle(commandText: "add \"LeetCode\" 60m today 7:00pm")
    let undoResponse = await service.handle(commandText: "undo")
    let todayResponse = await service.handle(commandText: "today")

    #expect(undoResponse.text.contains("Undo complete"))
    #expect(todayResponse.text.contains("No SenseAssist blocks"))
}

@Test func planServiceHydrationRetriesAfterRepositoryFailure() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let serviceStore = SQLiteStore(databasePath: dbPath, logger: logger)
    try serviceStore.initialize()
    let controlStore = SQLiteStore(databasePath: dbPath, logger: logger)
    try controlStore.initialize()
    defer {
        serviceStore.close()
        controlStore.close()
    }

    let service = PlanCommandService(
        calendarStore: InMemoryCalendarStore(),
        initialPlanRevision: 1,
        auditLogRepository: AuditLogRepository(store: serviceStore),
        operationRepository: OperationRepository(store: serviceStore),
        planRevisionRepository: PlanRevisionRepository(store: serviceStore)
    )

    // Simulate a transient repository failure during first hydration attempt.
    try controlStore.execute("DROP TABLE operations;")
    let first = await service.handle(commandText: "help")
    #expect(first.planRevision == 1)

    // Restore the table and insert an applied revision higher than in-memory state.
    try controlStore.execute(
        """
        CREATE TABLE operations (
          op_id TEXT PRIMARY KEY,
          expected_plan_revision INTEGER,
          applied_revision INTEGER,
          intent TEXT NOT NULL,
          status TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          result_json TEXT,
          created_at_utc TEXT NOT NULL
        );
        """
    )
    try OperationRepository(store: controlStore).insert(
        StoredOperationRecord(
            expectedPlanRevision: nil,
            appliedRevision: 9,
            intent: EditIntent.createBlock.rawValue,
            status: "applied",
            payloadJSON: "{}",
            resultJSON: nil
        )
    )

    let second = await service.handle(commandText: "help")
    #expect(second.planRevision == 9)
}

@Test func planServicePersistedUndoIsIdempotentWhenBlockAlreadyRemoved() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let serviceStore = SQLiteStore(databasePath: dbPath, logger: logger)
    try serviceStore.initialize()
    let controlStore = SQLiteStore(databasePath: dbPath, logger: logger)
    try controlStore.initialize()
    defer {
        serviceStore.close()
        controlStore.close()
    }

    let calendarStore = InMemoryCalendarStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let block = CalendarBlock(
        title: "Deep Work: Persisted Undo",
        startLocal: now,
        endLocal: now.addingTimeInterval(60 * 60),
        planRevision: 8
    )
    let created = try await calendarStore.createManagedBlock(block, calendarName: "SenseAssist")

    let persistedUndoPayload = """
    {
      "kind": "created_block",
      "blockID": "\(created.blockID.uuidString)",
      "ekEventID": \(created.ekEventID.map { "\"\($0)\"" } ?? "null"),
      "previousBlock": null
    }
    """
    let opID = UUID().uuidString
    try OperationRepository(store: controlStore).insert(
        StoredOperationRecord(
            opID: opID,
            expectedPlanRevision: 8,
            appliedRevision: 8,
            intent: EditIntent.createBlock.rawValue,
            status: "applied",
            payloadJSON: "{}",
            resultJSON: persistedUndoPayload
        )
    )

    // Simulate the calendar mutation already being undone before this process starts.
    try await calendarStore.deleteManagedBlock(
        blockID: created.blockID,
        ekEventID: created.ekEventID,
        calendarName: "SenseAssist"
    )

    let service = PlanCommandService(
        calendarStore: calendarStore,
        initialPlanRevision: 1,
        auditLogRepository: AuditLogRepository(store: serviceStore),
        operationRepository: OperationRepository(store: serviceStore),
        planRevisionRepository: PlanRevisionRepository(store: serviceStore)
    )

    let firstUndo = await service.handle(commandText: "undo")
    #expect(firstUndo.text.contains("Undo already applied"))
    #expect(firstUndo.planRevision == 9)

    let secondUndo = await service.handle(commandText: "undo")
    #expect(secondUndo.text.contains("Nothing to undo"))

    let statusRow = try controlStore.fetchRows("SELECT status FROM operations WHERE op_id = '\(opID)' LIMIT 1;").first
    #expect(statusRow?["status"] == "undone")
}
