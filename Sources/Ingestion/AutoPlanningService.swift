import CoreContracts
import CryptoKit
import EventKitAdapter
import Foundation
import LLMRuntime
import Storage

public struct AutoPlanningApplySummary: Sendable {
    public var revisionID: Int
    public var createdBlocks: Int
    public var deletedBlocks: Int
    public var feasibilityState: FeasibilityState
    public var unscheduledTaskCount: Int

    public init(
        revisionID: Int,
        createdBlocks: Int,
        deletedBlocks: Int,
        feasibilityState: FeasibilityState,
        unscheduledTaskCount: Int
    ) {
        self.revisionID = revisionID
        self.createdBlocks = createdBlocks
        self.deletedBlocks = deletedBlocks
        self.feasibilityState = feasibilityState
        self.unscheduledTaskCount = unscheduledTaskCount
    }
}

public enum SchedulerExecutionMode: String, Sendable {
    case llmOnly = "llm_only"
}

public enum AutoPlanningServiceError: Error, LocalizedError {
    case llmSchedulerUnavailable

    public var errorDescription: String? {
        switch self {
        case .llmSchedulerUnavailable:
            return "LLM-only scheduling is enabled but no scheduler runtime is configured."
        }
    }
}

public struct DailyRoutineTaskDefinition: Sendable {
    public var title: String
    public var category: TaskCategory
    public var estimatedMinutes: Int
    public var minDailyMinutes: Int
    public var priority: Int
    public var stressWeight: Double
    public var dueHourLocal: Int?

    public init(
        title: String,
        category: TaskCategory,
        estimatedMinutes: Int,
        minDailyMinutes: Int,
        priority: Int,
        stressWeight: Double,
        dueHourLocal: Int? = 22
    ) {
        self.title = title
        self.category = category
        self.estimatedMinutes = estimatedMinutes
        self.minDailyMinutes = minDailyMinutes
        self.priority = priority
        self.stressWeight = stressWeight
        self.dueHourLocal = dueHourLocal
    }

    public static let studentDefaults: [DailyRoutineTaskDefinition] = [
        DailyRoutineTaskDefinition(
            title: "LeetCode Practice",
            category: .leetcode,
            estimatedMinutes: 90,
            minDailyMinutes: 45,
            priority: 4,
            stressWeight: 0.35
        ),
        DailyRoutineTaskDefinition(
            title: "Internship Applications",
            category: .application,
            estimatedMinutes: 90,
            minDailyMinutes: 45,
            priority: 4,
            stressWeight: 0.45
        ),
        DailyRoutineTaskDefinition(
            title: "Meals and Nutrition",
            category: .admin,
            estimatedMinutes: 120,
            minDailyMinutes: 90,
            priority: 5,
            stressWeight: 0.15,
            dueHourLocal: 21
        ),
        DailyRoutineTaskDefinition(
            title: "Bath and Hygiene",
            category: .admin,
            estimatedMinutes: 45,
            minDailyMinutes: 30,
            priority: 4,
            stressWeight: 0.10
        ),
        DailyRoutineTaskDefinition(
            title: "Mental Reset and Free Time",
            category: .admin,
            estimatedMinutes: 60,
            minDailyMinutes: 45,
            priority: 3,
            stressWeight: 0.05
        )
    ]
}

public final class AutoPlanningService {
    private let taskRepository: TaskRepository
    private let planRevisionRepository: PlanRevisionRepository
    private let operationRepository: OperationRepository?
    private let calendarStore: CalendarStore
    private let schedulerLLMRuntime: LLMRuntimeClient?
    private let schedulerMode: SchedulerExecutionMode
    private let dailyRoutineTasks: [DailyRoutineTaskDefinition]
    private let plannerInputFilePath: String?
    private let managedCalendarName: String
    private let constraints: PlannerConstraints
    private let calendar: Calendar

    public init(
        taskRepository: TaskRepository,
        planRevisionRepository: PlanRevisionRepository,
        operationRepository: OperationRepository? = nil,
        calendarStore: CalendarStore,
        schedulerLLMRuntime: LLMRuntimeClient? = nil,
        schedulerMode: SchedulerExecutionMode = .llmOnly,
        dailyRoutineTasks: [DailyRoutineTaskDefinition] = DailyRoutineTaskDefinition.studentDefaults,
        plannerInputFilePath: String? = nil,
        managedCalendarName: String = "SenseAssist",
        constraints: PlannerConstraints,
        calendar: Calendar = .current
    ) {
        self.taskRepository = taskRepository
        self.planRevisionRepository = planRevisionRepository
        self.operationRepository = operationRepository
        self.calendarStore = calendarStore
        self.schedulerLLMRuntime = schedulerLLMRuntime
        self.schedulerMode = schedulerMode
        self.dailyRoutineTasks = dailyRoutineTasks
        self.plannerInputFilePath = plannerInputFilePath
        self.managedCalendarName = managedCalendarName
        self.constraints = constraints
        self.calendar = calendar
    }

    public func regenerate(now: Date = Date(), trigger: String) async throws -> AutoPlanningApplySummary {
        let persistedTasks = try taskRepository.listActive()
        let routineTasksForDay = buildDailyRoutineTasks(for: now)
        let activeTasks = mergeTasks(persistedTasks, with: routineTasksForDay)
        try await calendarStore.ensureManagedCalendar(named: managedCalendarName)
        let existingBlocks = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)

        let nextRevision = max(1, (try planRevisionRepository.latestRevisionID()) + 1)
        let snapshot = buildPlannerInputSnapshot(
            now: now,
            nextRevision: nextRevision,
            tasks: activeTasks,
            existingBlocks: existingBlocks
        )
        if let plannerInputFilePath {
            try writePlannerInputSnapshot(snapshot, to: plannerInputFilePath)
        }
        guard let schedulerLLMRuntime else {
            throw AutoPlanningServiceError.llmSchedulerUnavailable
        }

        if schedulerMode != .llmOnly {
            throw AutoPlanningServiceError.llmSchedulerUnavailable
        }

        let result = try await schedulerLLMRuntime.inferSchedulePlan(
            date: now,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: nextRevision,
            timeZoneIdentifier: calendar.timeZone.identifier
        )

        let existingKeys = Set(existingBlocks.map(blockDiffKey))
        let plannedKeys = Set(result.blocks.map(blockDiffKey))

        let toDelete = existingBlocks.filter { !plannedKeys.contains(blockDiffKey($0)) }
        let toCreate = result.blocks.filter { !existingKeys.contains(blockDiffKey($0)) }

        for block in toDelete {
            try await calendarStore.deleteManagedBlock(
                blockID: block.blockID,
                ekEventID: block.ekEventID,
                calendarName: managedCalendarName
            )
        }

        for block in toCreate {
            _ = try await calendarStore.createManagedBlock(block, calendarName: managedCalendarName)
        }

        let summary = PlanSummary(createdBlocks: toCreate.count, movedBlocks: 0, deletedBlocks: toDelete.count)
        let revisionID = try planRevisionRepository.append(trigger: trigger, summary: summary)

        if let operationRepository {
            let payload: [String: String] = [
                "trigger": trigger,
                "feasibility_state": result.feasibilityState.rawValue,
                "unscheduled_task_count": "\(result.unscheduledTaskIDs.count)"
            ]
            let payloadJSON: String
            if let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) {
                payloadJSON = text
            } else {
                payloadJSON = "{}"
            }

            try? operationRepository.insert(
                StoredOperationRecord(
                    expectedPlanRevision: nil,
                    appliedRevision: revisionID,
                    intent: EditIntent.regeneratePlan.rawValue,
                    status: "applied",
                    payloadJSON: payloadJSON,
                    resultJSON: nil
                )
            )
        }

        return AutoPlanningApplySummary(
            revisionID: revisionID,
            createdBlocks: toCreate.count,
            deletedBlocks: toDelete.count,
            feasibilityState: result.feasibilityState,
            unscheduledTaskCount: result.unscheduledTaskIDs.count
        )
    }

    private func blockDiffKey(_ block: CalendarBlock) -> String {
        let startMinute = Int(block.startLocal.timeIntervalSince1970 / 60.0)
        let endMinute = Int(block.endLocal.timeIntervalSince1970 / 60.0)
        return "\(block.title)|\(startMinute)|\(endMinute)"
    }

    private func mergeTasks(_ persisted: [TaskItem], with routineTasks: [TaskItem]) -> [TaskItem] {
        var merged = persisted
        var existingKeys = Set(persisted.map(taskIdentityKey))

        for task in routineTasks {
            let key = taskIdentityKey(task)
            guard !existingKeys.contains(key) else { continue }
            merged.append(task)
            existingKeys.insert(key)
        }

        return merged
    }

    private func taskIdentityKey(_ task: TaskItem) -> String {
        let dueBucket: String
        if let dueAtLocal = task.dueAtLocal {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            dueBucket = formatter.string(from: dueAtLocal)
        } else {
            dueBucket = "none"
        }

        return "\(task.category.rawValue)|\(task.title.lowercased())|\(dueBucket)"
    }

    private func buildDailyRoutineTasks(for date: Date) -> [TaskItem] {
        guard !dailyRoutineTasks.isEmpty else {
            return []
        }

        return dailyRoutineTasks.map { definition in
            TaskItem(
                taskID: routineTaskID(for: definition, on: date),
                title: definition.title,
                category: definition.category,
                dueAtLocal: routineDueDate(for: definition, on: date),
                estimatedMinutes: max(15, definition.estimatedMinutes),
                minDailyMinutes: max(15, definition.minDailyMinutes),
                priority: max(1, definition.priority),
                stressWeight: min(max(definition.stressWeight, 0.0), 1.0),
                status: .todo
            )
        }
    }

    private func routineDueDate(for definition: DailyRoutineTaskDefinition, on date: Date) -> Date? {
        guard let dueHourLocal = definition.dueHourLocal else {
            return nil
        }
        let dayStart = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: min(max(0, dueHourLocal), 23), minute: 0, second: 0, of: dayStart)
    }

    private func routineTaskID(for definition: DailyRoutineTaskDefinition, on date: Date) -> UUID {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: date)
        let input = "routine|\(dayKey)|\(definition.category.rawValue)|\(definition.title.lowercased())"

        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func buildPlannerInputSnapshot(
        now: Date,
        nextRevision: Int,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock]
    ) -> PlannerInputSnapshot {
        let startOfDay = calendar.startOfDay(for: now)
        let dayStart = calendar.date(bySettingHour: constraints.workdayStartHour24, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        let dayEndRaw = calendar.date(bySettingHour: constraints.workdayEndHour24, minute: 0, second: 0, of: startOfDay)
            ?? startOfDay.addingTimeInterval(22 * 3600)
        let cutoff = calendar.date(bySettingHour: constraints.avoidAfterHour24, minute: 0, second: 0, of: startOfDay)
            ?? startOfDay.addingTimeInterval(23 * 3600)
        let dayEnd = min(dayEndRaw, cutoff)

        let metaFormatter = DateFormatter()
        metaFormatter.calendar = calendar
        metaFormatter.timeZone = calendar.timeZone
        metaFormatter.locale = Locale(identifier: "en_US_POSIX")
        metaFormatter.dateFormat = "yyyy-MM-dd"
        let planningDateLocal = metaFormatter.string(from: now)

        let busyBlocks = existingBlocks
            .filter { $0.lockLevel == .locked || !$0.managedByAgent }
            .map {
                PlannerInputSnapshot.BusyBlock(
                    title: $0.title,
                    startLocal: $0.startLocal,
                    endLocal: $0.endLocal,
                    lockLevel: $0.lockLevel.rawValue,
                    managedByAgent: $0.managedByAgent
                )
            }

        let snapshotTasks = tasks.map { task in
            let isLargeAssignment = (task.category == .assignment || task.category == .project) && task.estimatedMinutes >= 180
            let shouldDefer = shouldDeferSmallNearDueTask(task: task, planningDate: now)
            let confidence = task.sources.map(\.confidence).max() ?? 1.0

            return PlannerInputSnapshot.Task(
                taskID: task.taskID.uuidString,
                title: task.title,
                category: task.category.rawValue,
                dueAtLocal: task.dueAtLocal,
                estimatedMinutes: task.estimatedMinutes,
                minDailyMinutes: task.minDailyMinutes,
                priority: task.priority,
                stressWeight: task.stressWeight,
                confidence: confidence,
                isLargeAssignment: isLargeAssignment,
                shouldDeferUntilDayBeforeDue: shouldDefer,
                sources: task.sources.map {
                    PlannerInputSnapshot.Source(
                        provider: $0.source.rawValue,
                        accountID: $0.accountID,
                        messageID: $0.messageID,
                        confidence: $0.confidence
                    )
                }
            )
        }

        return PlannerInputSnapshot(
            meta: PlannerInputSnapshot.Meta(
                generatedAtUTC: Date(),
                planningDateLocal: planningDateLocal,
                timeZone: calendar.timeZone.identifier,
                planRevision: nextRevision
            ),
            constraints: PlannerInputSnapshot.Constraints(
                dayStartLocal: dayStart,
                dayEndLocal: dayEnd,
                maxDeepWorkMinutesPerDay: constraints.maxDeepWorkMinutesPerDay,
                breakEveryMinutes: constraints.breakEveryMinutes,
                breakDurationMinutes: constraints.breakDurationMinutes,
                freeSpaceBufferMinutes: constraints.freeSpaceBufferMinutes,
                sleepWindow: PlannerInputSnapshot.SleepWindow(
                    start: constraints.sleepStart,
                    end: constraints.sleepEnd
                )
            ),
            busyBlocks: busyBlocks,
            tasks: snapshotTasks
        )
    }

    private func writePlannerInputSnapshot(_ snapshot: PlannerInputSnapshot, to path: String) throws {
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: destination, options: [.atomic])
    }

    private func shouldDeferSmallNearDueTask(task: TaskItem, planningDate: Date) -> Bool {
        guard task.category == .assignment || task.category == .quiz else {
            return false
        }
        guard task.estimatedMinutes <= 90, let dueAtLocal = task.dueAtLocal else {
            return false
        }

        let planningStart = calendar.startOfDay(for: planningDate)
        let dueStart = calendar.startOfDay(for: dueAtLocal)
        let daysUntilDue = max(0, calendar.dateComponents([.day], from: planningStart, to: dueStart).day ?? 0)
        return daysUntilDue == 2
    }
}
