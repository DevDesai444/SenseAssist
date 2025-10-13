import CoreContracts
import EventKitAdapter
import Foundation
import Ingestion
import LLMRuntime
import Storage
import Testing

@Test func autoPlanningUsesLLMSchedulerWhenAvailable() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_777_777_700)

    let task = TaskItem(
        taskID: UUID(),
        title: "LLM-driven schedule task",
        category: .assignment,
        dueAtLocal: now.addingTimeInterval(24 * 3600),
        estimatedMinutes: 120,
        minDailyMinutes: 60,
        priority: 3,
        stressWeight: 0.3
    )
    try TaskRepository(store: store).upsert([task])

    let blockStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
    let blockEnd = calendar.date(byAdding: .minute, value: 60, to: blockStart)!
    let llmPlan = SchedulePlan(
        blocks: [
            CalendarBlock(
                taskID: task.taskID,
                title: "LLM Scheduled Focus Block",
                startLocal: blockStart,
                endLocal: blockEnd,
                planRevision: 1
            )
        ],
        feasibilityState: .onTrack,
        unscheduledTaskIDs: []
    )

    let calendarStore = InMemoryCalendarStore()
    let service = AutoPlanningService(
        taskRepository: TaskRepository(store: store),
        planRevisionRepository: PlanRevisionRepository(store: store),
        operationRepository: OperationRepository(store: store),
        calendarStore: calendarStore,
        schedulerLLMRuntime: TestSchedulerLLMRuntime(plan: llmPlan),
        managedCalendarName: "SenseAssist",
        constraints: PlannerConstraints(),
        calendar: calendar
    )

    let summary = try await service.regenerate(now: now, trigger: "llm_scheduler_test")
    #expect(summary.createdBlocks == 1)
    #expect(summary.unscheduledTaskCount == 0)

    let created = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)
    #expect(created.contains(where: { $0.title == "LLM Scheduled Focus Block" }))
}

@Test func autoPlanningFailsWhenLLMSchedulerFails() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_777_777_700)

    let task = TaskItem(
        taskID: UUID(),
        title: "Fallback planner task",
        category: .project,
        dueAtLocal: now.addingTimeInterval(2 * 24 * 3600),
        estimatedMinutes: 120,
        minDailyMinutes: 60,
        priority: 2,
        stressWeight: 0.4
    )
    try TaskRepository(store: store).upsert([task])

    let calendarStore = InMemoryCalendarStore()
    let service = AutoPlanningService(
        taskRepository: TaskRepository(store: store),
        planRevisionRepository: PlanRevisionRepository(store: store),
        operationRepository: OperationRepository(store: store),
        calendarStore: calendarStore,
        schedulerLLMRuntime: FailingSchedulerLLMRuntime(),
        managedCalendarName: "SenseAssist",
        constraints: PlannerConstraints(),
        calendar: calendar
    )

    do {
        _ = try await service.regenerate(now: now, trigger: "llm_scheduler_failure_test")
        Issue.record("Expected LLM scheduler failure to be propagated")
    } catch {
        #expect(error is LLMRuntimeError)
    }
}

@Test func autoPlanningInjectsDailyRoutineTasksIntoSchedulerInput() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_777_777_700)

    let capturingLLM = CapturingSchedulerLLMRuntime()
    let service = AutoPlanningService(
        taskRepository: TaskRepository(store: store),
        planRevisionRepository: PlanRevisionRepository(store: store),
        operationRepository: OperationRepository(store: store),
        calendarStore: InMemoryCalendarStore(),
        schedulerLLMRuntime: capturingLLM,
        schedulerMode: .llmOnly,
        dailyRoutineTasks: DailyRoutineTaskDefinition.studentDefaults,
        managedCalendarName: "SenseAssist",
        constraints: PlannerConstraints(),
        calendar: calendar
    )

    _ = try await service.regenerate(now: now, trigger: "routine_tasks_test")
    let capturedTitles = await capturingLLM.capturedTaskTitles()

    #expect(capturedTitles.contains("LeetCode Practice"))
    #expect(capturedTitles.contains("Internship Applications"))
    #expect(capturedTitles.contains("Meals and Nutrition"))
}

@Test func autoPlanningLLMOnlyModeDoesNotFallBackOnFailure() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    let now = Date(timeIntervalSince1970: 1_777_777_700)
    let task = TaskItem(
        taskID: UUID(),
        title: "LLM only should fail",
        category: .assignment,
        dueAtLocal: now.addingTimeInterval(24 * 3600),
        estimatedMinutes: 120,
        minDailyMinutes: 60,
        priority: 3,
        stressWeight: 0.3
    )
    try TaskRepository(store: store).upsert([task])

    let service = AutoPlanningService(
        taskRepository: TaskRepository(store: store),
        planRevisionRepository: PlanRevisionRepository(store: store),
        operationRepository: OperationRepository(store: store),
        calendarStore: InMemoryCalendarStore(),
        schedulerLLMRuntime: FailingSchedulerLLMRuntime(),
        schedulerMode: .llmOnly,
        dailyRoutineTasks: [],
        managedCalendarName: "SenseAssist",
        constraints: PlannerConstraints()
    )

    do {
        _ = try await service.regenerate(now: now, trigger: "llm_only_mode_test")
        Issue.record("Expected llm-only mode to propagate scheduler error")
    } catch {
        #expect(error is LLMRuntimeError)
    }
}

@Test func autoPlanningWritesPlannerInputSnapshotFile() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("senseassist.sqlite").path
    let logger = ConsoleLogger(minimumLevel: .error)
    let store = SQLiteStore(databasePath: dbPath, logger: logger)
    try store.initialize()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 9, minute: 0, second: 0))!
    let shortDue = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 17, minute: 0, second: 0))!
    let longDue = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 23, minute: 0, second: 0))!

    let shortTask = TaskItem(
        taskID: UUID(),
        title: "Short Assignment",
        category: .assignment,
        dueAtLocal: shortDue,
        estimatedMinutes: 60,
        minDailyMinutes: 30,
        priority: 4,
        stressWeight: 0.2
    )
    let longTask = TaskItem(
        taskID: UUID(),
        title: "Long Assignment",
        category: .assignment,
        dueAtLocal: longDue,
        estimatedMinutes: 480,
        minDailyMinutes: 120,
        priority: 4,
        stressWeight: 0.4
    )
    try TaskRepository(store: store).upsert([shortTask, longTask])

    let plannerInputPath = tempDir.appendingPathComponent("planner_input.json").path
    let constraints = PlannerConstraints(workdayStartHour24: 9, workdayEndHour24: 22, avoidAfterHour24: 21)
    let service = AutoPlanningService(
        taskRepository: TaskRepository(store: store),
        planRevisionRepository: PlanRevisionRepository(store: store),
        operationRepository: OperationRepository(store: store),
        calendarStore: InMemoryCalendarStore(),
        schedulerLLMRuntime: CapturingSchedulerLLMRuntime(),
        schedulerMode: .llmOnly,
        dailyRoutineTasks: [],
        plannerInputFilePath: plannerInputPath,
        managedCalendarName: "SenseAssist",
        constraints: constraints,
        calendar: calendar
    )

    _ = try await service.regenerate(now: now, trigger: "planner_input_snapshot_test")

    let snapshotData = try Data(contentsOf: URL(fileURLWithPath: plannerInputPath))
    let snapshotRaw = String(data: snapshotData, encoding: .utf8) ?? ""
    #expect(snapshotRaw.contains("\"busy_blocks\""))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(PlannerInputSnapshot.self, from: snapshotData)

    #expect(snapshot.meta.planRevision == 1)
    #expect(snapshot.tasks.count == 2)
    #expect(calendar.component(.hour, from: snapshot.constraints.dayStartLocal) == 9)
    #expect(calendar.component(.hour, from: snapshot.constraints.dayEndLocal) == 21)

    let tasksByTitle = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.title, $0) })
    #expect(tasksByTitle["Short Assignment"]?.shouldDeferUntilDayBeforeDue == true)
    #expect(tasksByTitle["Short Assignment"]?.isLargeAssignment == false)
    #expect(tasksByTitle["Long Assignment"]?.isLargeAssignment == true)
    #expect(tasksByTitle["Long Assignment"]?.shouldDeferUntilDayBeforeDue == false)
}

private struct TestSchedulerLLMRuntime: LLMRuntimeClient {
    let plan: SchedulePlan

    func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        _ = updates
        return []
    }

    func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        _ = messageText
        _ = expectedPlanRevision
        throw LLMRuntimeError.unsupportedPrompt
    }

    func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        _ = date
        _ = tasks
        _ = existingBlocks
        _ = constraints
        _ = planRevision
        _ = timeZoneIdentifier
        return plan
    }
}

private struct FailingSchedulerLLMRuntime: LLMRuntimeClient {
    func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        _ = updates
        return []
    }

    func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        _ = messageText
        _ = expectedPlanRevision
        throw LLMRuntimeError.unsupportedPrompt
    }

    func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        _ = date
        _ = tasks
        _ = existingBlocks
        _ = constraints
        _ = planRevision
        _ = timeZoneIdentifier
        throw LLMRuntimeError.invalidJSON
    }
}

private actor CapturingSchedulerLLMRuntime: LLMRuntimeClient {
    private var titles: [String] = []

    func capturedTaskTitles() -> [String] {
        titles
    }

    func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        _ = updates
        return []
    }

    func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        _ = messageText
        _ = expectedPlanRevision
        throw LLMRuntimeError.unsupportedPrompt
    }

    func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        _ = date
        _ = existingBlocks
        _ = constraints
        _ = planRevision
        _ = timeZoneIdentifier
        titles = tasks.map(\.title)
        return SchedulePlan(blocks: [], feasibilityState: .atRisk, unscheduledTaskIDs: tasks.map(\.taskID))
    }
}
