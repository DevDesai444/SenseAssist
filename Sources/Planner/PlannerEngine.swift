import CoreContracts
import Foundation

public struct PlannerInput: Sendable {
    public var date: Date
    public var tasks: [TaskItem]
    public var existingBlocks: [CalendarBlock]
    public var constraints: PlannerConstraints
    public var planRevision: Int
    public var calendar: Calendar

    public init(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        calendar: Calendar = .current
    ) {
        self.date = date
        self.tasks = tasks
        self.existingBlocks = existingBlocks
        self.constraints = constraints
        self.planRevision = planRevision
        self.calendar = calendar
    }
}

public struct PlannerResult: Sendable {
    public var blocks: [CalendarBlock]
    public var feasibilityState: FeasibilityState
    public var unscheduledTaskIDs: [UUID]

    public init(blocks: [CalendarBlock], feasibilityState: FeasibilityState, unscheduledTaskIDs: [UUID]) {
        self.blocks = blocks
        self.feasibilityState = feasibilityState
        self.unscheduledTaskIDs = unscheduledTaskIDs
    }
}

private struct Window {
    var start: Date
    var end: Date

    var minutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60.0))
    }
}

public enum PlannerEngine {
    public static func plan(_ input: PlannerInput) -> PlannerResult {
        let activeTasks = input.tasks.filter { $0.status == .todo || $0.status == .inProgress }
        guard !activeTasks.isEmpty else {
            return PlannerResult(blocks: [], feasibilityState: .onTrack, unscheduledTaskIDs: [])
        }

        var windows = availableWindows(for: input)
        if windows.isEmpty {
            return PlannerResult(
                blocks: [],
                feasibilityState: .infeasible,
                unscheduledTaskIDs: activeTasks.map(\.taskID)
            )
        }

        let demandByTask = Dictionary(uniqueKeysWithValues: activeTasks.map {
            ($0.taskID, dailyDemandMinutes(for: $0, on: input.date, calendar: input.calendar))
        })

        let requiredMinutes = demandByTask.values.reduce(0, +)
        let availableMinutes = max(0, windows.reduce(0) { $0 + $1.minutes } - input.constraints.freeSpaceBufferMinutes)

        var feasibility: FeasibilityState
        if requiredMinutes > availableMinutes {
            feasibility = .infeasible
        } else if requiredMinutes > Int(Double(availableMinutes) * 0.9) {
            feasibility = .atRisk
        } else {
            feasibility = .onTrack
        }

        let maxSchedulableMinutes = min(input.constraints.maxDeepWorkMinutesPerDay, availableMinutes)
        let scoredTasks = activeTasks.sorted {
            score($0, on: input.date, calendar: input.calendar) > score($1, on: input.date, calendar: input.calendar)
        }

        var remainingCapacity = maxSchedulableMinutes
        var plannedBlocks: [CalendarBlock] = []
        var unscheduled: [UUID] = []

        for task in scoredTasks {
            guard let requestedMinutes = demandByTask[task.taskID], requestedMinutes > 0 else { continue }

            var remainingForTask = min(requestedMinutes, remainingCapacity)
            let chunkSize = max(30, input.constraints.breakEveryMinutes)
            var scheduledForTask = 0

            while remainingForTask > 0 {
                guard let windowIndex = windows.firstIndex(where: { $0.minutes >= 25 }) else { break }

                let window = windows[windowIndex]
                let nextChunk = min(chunkSize, min(remainingForTask, window.minutes))

                if nextChunk < 25 {
                    break
                }

                let blockStart = window.start
                let blockEnd = blockStart.addingTimeInterval(TimeInterval(nextChunk * 60))

                plannedBlocks.append(
                    CalendarBlock(
                        taskID: task.taskID,
                        title: "Deep Work: \(task.title)",
                        startLocal: blockStart,
                        endLocal: blockEnd,
                        planRevision: input.planRevision
                    )
                )

                scheduledForTask += nextChunk
                remainingForTask -= nextChunk
                remainingCapacity -= nextChunk

                let breakMinutes = min(input.constraints.breakDurationMinutes, max(0, window.minutes - nextChunk))
                let nextStart = blockEnd.addingTimeInterval(TimeInterval(breakMinutes * 60))

                if nextStart >= window.end {
                    windows.remove(at: windowIndex)
                } else {
                    windows[windowIndex] = Window(start: nextStart, end: window.end)
                }

                if remainingCapacity <= 0 {
                    break
                }
            }

            if scheduledForTask == 0 || scheduledForTask < requestedMinutes {
                unscheduled.append(task.taskID)
            }

            if remainingCapacity <= 0 {
                unscheduled.append(contentsOf: scoredTasks.drop(while: { $0.taskID != task.taskID }).dropFirst().map(\.taskID))
                break
            }
        }

        return PlannerResult(blocks: plannedBlocks, feasibilityState: feasibility, unscheduledTaskIDs: Array(Set(unscheduled)))
    }

    private static func availableWindows(for input: PlannerInput) -> [Window] {
        let startOfDay = input.calendar.startOfDay(for: input.date)
        guard
            let dayStart = input.calendar.date(bySettingHour: input.constraints.workdayStartHour24, minute: 0, second: 0, of: startOfDay),
            let dayEndRaw = input.calendar.date(bySettingHour: input.constraints.workdayEndHour24, minute: 0, second: 0, of: startOfDay),
            let cutoff = input.calendar.date(bySettingHour: input.constraints.avoidAfterHour24, minute: 0, second: 0, of: startOfDay)
        else {
            return []
        }

        let dayEnd = min(dayEndRaw, cutoff)
        guard dayStart < dayEnd else { return [] }

        var windows: [Window] = [Window(start: dayStart, end: dayEnd)]
        let busy = input.existingBlocks
            .filter { $0.lockLevel == .locked || !$0.managedByAgent }
            .sorted { $0.startLocal < $1.startLocal }

        for block in busy {
            windows = subtract(block: block, from: windows)
            if windows.isEmpty {
                break
            }
        }

        return windows
    }

    private static func subtract(block: CalendarBlock, from windows: [Window]) -> [Window] {
        windows.flatMap { window -> [Window] in
            if block.endLocal <= window.start || block.startLocal >= window.end {
                return [window]
            }

            var result: [Window] = []
            if block.startLocal > window.start {
                result.append(Window(start: window.start, end: block.startLocal))
            }
            if block.endLocal < window.end {
                result.append(Window(start: block.endLocal, end: window.end))
            }
            return result
        }
    }

    private static func dailyDemandMinutes(for task: TaskItem, on date: Date, calendar: Calendar) -> Int {
        let minimum = max(30, task.minDailyMinutes)
        let estimate = max(30, task.estimatedMinutes)

        guard let due = task.dueAtLocal else {
            return min(estimate, minimum)
        }

        let daysUntilDue = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: due)).day ?? 0)

        if daysUntilDue <= 1 {
            return min(estimate, max(minimum, 120))
        }
        if daysUntilDue <= 3 {
            return min(estimate, max(minimum, 90))
        }

        return min(estimate, minimum)
    }

    private static func score(_ task: TaskItem, on date: Date, calendar: Calendar) -> Double {
        let priorityWeight = Double(task.priority * 20)
        let sizePressure = Double(task.estimatedMinutes) * 0.05
        let stressPenalty = task.stressWeight * 10

        let urgency: Double
        if let due = task.dueAtLocal {
            let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: due)).day ?? 0)
            urgency = 200.0 / Double(days + 1)
        } else {
            urgency = 25
        }

        return urgency + priorityWeight + sizePressure - stressPenalty
    }
}
