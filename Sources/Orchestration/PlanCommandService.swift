import CoreContracts
import EventKitAdapter
import Foundation
import RulesEngine
import SlackIntegration

public struct PlanCommandResponse: Sendable {
    public var text: String
    public var planRevision: Int
    public var requiresConfirmation: Bool

    public init(text: String, planRevision: Int, requiresConfirmation: Bool = false) {
        self.text = text
        self.planRevision = planRevision
        self.requiresConfirmation = requiresConfirmation
    }
}

public actor PlanCommandService {
    private let calendarStore: CalendarStore
    private let managedCalendarName: String
    private var currentPlanRevision: Int
    private let calendar: Calendar

    public init(
        calendarStore: CalendarStore,
        managedCalendarName: String = "SenseAssist",
        initialPlanRevision: Int = 1,
        calendar: Calendar = .current
    ) {
        self.calendarStore = calendarStore
        self.managedCalendarName = managedCalendarName
        self.currentPlanRevision = initialPlanRevision
        self.calendar = calendar
    }

    public func handle(commandText: String, now: Date = Date()) async -> PlanCommandResponse {
        do {
            try await calendarStore.ensureManagedCalendar(named: managedCalendarName)
            let command = try PlanCommandParser.parse(commandText, now: now, calendar: calendar)

            switch command {
            case .today:
                return try await handleToday(now: now)
            case let .add(title, start, durationMinutes):
                return try await handleAdd(title: title, start: start, durationMinutes: durationMinutes)
            case let .move(title, start, durationMinutes):
                return try await handleMove(title: title, start: start, durationMinutes: durationMinutes)
            case .help:
                return PlanCommandResponse(
                    text: "Supported: /plan today, /plan add \"Title\" 60m [today|tomorrow] [7:00pm], /plan move \"Title\" tomorrow 7:00pm [60m]",
                    planRevision: currentPlanRevision
                )
            }
        } catch CalendarStoreError.permissionDenied {
            return PlanCommandResponse(
                text: "Calendar access is unavailable. Enable Calendar permission for SenseAssist in System Settings -> Privacy & Security -> Calendars, then retry.",
                planRevision: currentPlanRevision
            )
        } catch {
            return PlanCommandResponse(text: "Plan command failed: \(error.localizedDescription)", planRevision: currentPlanRevision)
        }
    }

    private func handleToday(now: Date) async throws -> PlanCommandResponse {
        let blocks = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)

        guard !blocks.isEmpty else {
            return PlanCommandResponse(text: "No SenseAssist blocks scheduled for today.", planRevision: currentPlanRevision)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"

        let lines = blocks.map { block in
            "- \(block.title): \(formatter.string(from: block.startLocal)) - \(formatter.string(from: block.endLocal))"
        }

        let text = (["Today's plan:"] + lines + ["Plan revision: \(currentPlanRevision)"]).joined(separator: "\n")
        return PlanCommandResponse(text: text, planRevision: currentPlanRevision)
    }

    private func handleAdd(title: String, start: Date, durationMinutes: Int) async throws -> PlanCommandResponse {
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let operation = EditOperation(
            expectedPlanRevision: currentPlanRevision,
            intent: .createBlock,
            target: EditTarget(fuzzyTitle: title),
            time: EditTime(startLocal: start, endLocal: end),
            notes: "Slack add command"
        )

        let decision = RulesEngine.validate(
            editOperation: operation,
            context: EditValidationContext(currentPlanRevision: currentPlanRevision)
        )

        switch decision {
        case let .rejected(reason):
            return PlanCommandResponse(text: "Add rejected: \(reason)", planRevision: currentPlanRevision)
        case let .requiresConfirmation(reason):
            return PlanCommandResponse(
                text: "Add requires confirmation: \(reason)",
                planRevision: currentPlanRevision,
                requiresConfirmation: true
            )
        case .approved:
            currentPlanRevision += 1

            let block = CalendarBlock(
                title: "Deep Work: \(title)",
                startLocal: start,
                endLocal: end,
                calendarName: managedCalendarName,
                managedByAgent: true,
                lockLevel: .flexible,
                planRevision: currentPlanRevision
            )

            _ = try await calendarStore.createManagedBlock(block, calendarName: managedCalendarName)

            return PlanCommandResponse(
                text: "Added \"\(title)\" for \(durationMinutes)m. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func handleMove(title: String, start: Date, durationMinutes: Int?) async throws -> PlanCommandResponse {
        let matches = try await calendarStore.findManagedBlocks(fuzzyTitle: title, on: nil, calendar: calendar)

        if matches.isEmpty {
            return PlanCommandResponse(text: "No matching managed block found for \"\(title)\".", planRevision: currentPlanRevision)
        }

        if matches.count > 1 {
            let options = matches.enumerated().map { index, block in
                "\(index + 1). \(block.title) @ \(isoLocal(block.startLocal))"
            }.joined(separator: "\n")

            return PlanCommandResponse(
                text: "Ambiguous match for \"\(title)\". Choose one:\n\(options)",
                planRevision: currentPlanRevision,
                requiresConfirmation: true
            )
        }

        guard var target = matches.first else {
            return PlanCommandResponse(text: "No matching managed block found for \"\(title)\".", planRevision: currentPlanRevision)
        }

        let oldDuration = Int(target.endLocal.timeIntervalSince(target.startLocal) / 60)
        let newDuration = durationMinutes ?? max(30, oldDuration)
        let newEnd = start.addingTimeInterval(TimeInterval(newDuration * 60))

        let operation = EditOperation(
            expectedPlanRevision: currentPlanRevision,
            intent: .moveBlock,
            target: EditTarget(ekEventID: target.ekEventID, fuzzyTitle: title),
            time: EditTime(startLocal: start, endLocal: newEnd),
            notes: "Slack move command"
        )

        let decision = RulesEngine.validate(
            editOperation: operation,
            context: EditValidationContext(currentPlanRevision: currentPlanRevision, matchedTargetCount: matches.count)
        )

        switch decision {
        case let .rejected(reason):
            return PlanCommandResponse(text: "Move rejected: \(reason)", planRevision: currentPlanRevision)
        case let .requiresConfirmation(reason):
            return PlanCommandResponse(
                text: "Move requires confirmation: \(reason)",
                planRevision: currentPlanRevision,
                requiresConfirmation: true
            )
        case .approved:
            currentPlanRevision += 1
            target.startLocal = start
            target.endLocal = newEnd
            target.planRevision = currentPlanRevision

            _ = try await calendarStore.updateManagedBlock(target, calendarName: managedCalendarName)

            return PlanCommandResponse(
                text: "Moved \"\(target.title)\" to \(isoLocal(start)). Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func isoLocal(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
