import CoreContracts
import EventKitAdapter
import Foundation
import Planner
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

public final class AutoPlanningService {
    private let taskRepository: TaskRepository
    private let planRevisionRepository: PlanRevisionRepository
    private let operationRepository: OperationRepository?
    private let calendarStore: CalendarStore
    private let managedCalendarName: String
    private let constraints: PlannerConstraints
    private let calendar: Calendar

    public init(
        taskRepository: TaskRepository,
        planRevisionRepository: PlanRevisionRepository,
        operationRepository: OperationRepository? = nil,
        calendarStore: CalendarStore,
        managedCalendarName: String = "SenseAssist",
        constraints: PlannerConstraints,
        calendar: Calendar = .current
    ) {
        self.taskRepository = taskRepository
        self.planRevisionRepository = planRevisionRepository
        self.operationRepository = operationRepository
        self.calendarStore = calendarStore
        self.managedCalendarName = managedCalendarName
        self.constraints = constraints
        self.calendar = calendar
    }

    public func regenerate(now: Date = Date(), trigger: String) async throws -> AutoPlanningApplySummary {
        let activeTasks = try taskRepository.listActive()
        try await calendarStore.ensureManagedCalendar(named: managedCalendarName)
        let existingBlocks = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)

        let nextRevision = max(1, (try planRevisionRepository.latestRevisionID()) + 1)
        let input = PlannerInput(
            date: now,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: nextRevision,
            calendar: calendar
        )
        let result = PlannerEngine.plan(input)

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
}
