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

@Test func autoPlanningFallsBackWhenLLMSchedulerFails() async throws {
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

    let summary = try await service.regenerate(now: now, trigger: "llm_scheduler_fallback_test")
    #expect(summary.createdBlocks >= 1)
    #expect(summary.feasibilityState == .onTrack || summary.feasibilityState == .atRisk || summary.feasibilityState == .infeasible)

    let created = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)
    #expect(created.contains(where: { $0.title.contains("Deep Work:") }))
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
