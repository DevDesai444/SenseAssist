import CoreContracts
import Foundation
import Planner
import Testing

@Test func plannerDetectsInfeasibleWhenNoAvailability() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!

    let date = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-02T00:00:00-0500
    let task = TaskItem(
        title: "Big Assignment",
        category: .assignment,
        dueAtLocal: date.addingTimeInterval(24 * 3600),
        estimatedMinutes: 300,
        minDailyMinutes: 180,
        priority: 1,
        stressWeight: 0.5
    )

    let locked = CalendarBlock(
        title: "All day event",
        startLocal: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!,
        endLocal: calendar.date(bySettingHour: 22, minute: 0, second: 0, of: date)!,
        managedByAgent: false,
        lockLevel: .locked,
        planRevision: 1
    )

    let input = PlannerInput(
        date: date,
        tasks: [task],
        existingBlocks: [locked],
        constraints: PlannerConstraints(),
        planRevision: 1,
        calendar: calendar
    )

    let result = PlannerEngine.plan(input)

    #expect(result.feasibilityState == .infeasible)
    #expect(result.blocks.isEmpty)
}

@Test func plannerCreatesBlocksWithinDailyCap() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let date = Date(timeIntervalSince1970: 1_709_251_200)
    let task = TaskItem(
        title: "CSE312 A2",
        category: .assignment,
        dueAtLocal: date.addingTimeInterval(2 * 24 * 3600),
        estimatedMinutes: 600,
        minDailyMinutes: 120,
        priority: 1,
        stressWeight: 0.7
    )

    var constraints = PlannerConstraints()
    constraints.maxDeepWorkMinutesPerDay = 180

    let input = PlannerInput(
        date: date,
        tasks: [task],
        existingBlocks: [],
        constraints: constraints,
        planRevision: 3,
        calendar: calendar
    )

    let result = PlannerEngine.plan(input)
    let scheduledMinutes = result.blocks.reduce(0) { partial, block in
        partial + Int(block.endLocal.timeIntervalSince(block.startLocal) / 60)
    }

    #expect(!result.blocks.isEmpty)
    #expect(scheduledMinutes <= 180)
}
