import CoreContracts
import EventKitAdapter
import Foundation
import Orchestration
import SlackIntegration
import Testing

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
