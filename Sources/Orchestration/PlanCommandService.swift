import CoreContracts
import EventKitAdapter
import Foundation
import RulesEngine
import SlackIntegration
import Storage

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
    private enum UndoOperation: Sendable {
        case createdBlock(blockID: UUID, ekEventID: String?)
        case movedBlock(previous: CalendarBlock)
    }

    private let calendarStore: CalendarStore
    private let managedCalendarName: String
    private var currentPlanRevision: Int
    private let calendar: Calendar
    private let auditLogRepository: AuditLogRepository?
    private var undoStack: [UndoOperation]

    public init(
        calendarStore: CalendarStore,
        managedCalendarName: String = "SenseAssist",
        initialPlanRevision: Int = 1,
        calendar: Calendar = .current,
        auditLogRepository: AuditLogRepository? = nil
    ) {
        self.calendarStore = calendarStore
        self.managedCalendarName = managedCalendarName
        self.currentPlanRevision = initialPlanRevision
        self.calendar = calendar
        self.auditLogRepository = auditLogRepository
        self.undoStack = []
    }

    public func handle(commandText: String, now: Date = Date()) async -> PlanCommandResponse {
        do {
            audit("info", "command_received", context: ["command_text": commandText])
            try await calendarStore.ensureManagedCalendar(named: managedCalendarName)
            let command = try PlanCommandParser.parse(commandText, now: now, calendar: calendar)

            switch command {
            case .today:
                return try await handleToday(now: now)
            case let .add(title, start, durationMinutes):
                return try await handleAdd(title: title, start: start, durationMinutes: durationMinutes)
            case let .move(title, start, durationMinutes):
                return try await handleMove(title: title, start: start, durationMinutes: durationMinutes)
            case .undo:
                return try await handleUndo()
            case .help:
                return PlanCommandResponse(
                    text: "Supported: /plan today, /plan add \"Title\" 60m [today|tomorrow] [7:00pm], /plan move \"Title\" tomorrow 7:00pm [60m], /plan undo",
                    planRevision: currentPlanRevision
                )
            }
        } catch CalendarStoreError.permissionDenied {
            audit("warning", "calendar_permission_denied")
            return PlanCommandResponse(
                text: "Calendar access is unavailable. Enable Calendar permission for SenseAssist in System Settings -> Privacy & Security -> Calendars, then retry.",
                planRevision: currentPlanRevision
            )
        } catch {
            audit("error", "command_failed", context: ["error": error.localizedDescription])
            return PlanCommandResponse(text: "Plan command failed: \(error.localizedDescription)", planRevision: currentPlanRevision)
        }
    }

    private func handleToday(now: Date) async throws -> PlanCommandResponse {
        let blocks = try await calendarStore.fetchManagedBlocks(on: now, calendar: calendar)

        guard !blocks.isEmpty else {
            audit("info", "today_empty", context: ["revision": "\(currentPlanRevision)"])
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
        audit("info", "today_success", context: ["count": "\(blocks.count)", "revision": "\(currentPlanRevision)"])
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
            audit("warning", "add_rejected", context: ["reason": reason])
            return PlanCommandResponse(text: "Add rejected: \(reason)", planRevision: currentPlanRevision)
        case let .requiresConfirmation(reason):
            audit("warning", "add_confirmation_required", context: ["reason": reason])
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

            let created = try await calendarStore.createManagedBlock(block, calendarName: managedCalendarName)
            undoStack.append(.createdBlock(blockID: created.blockID, ekEventID: created.ekEventID))
            trimUndoStack()
            audit(
                "info",
                "add_success",
                context: ["title": title, "duration_minutes": "\(durationMinutes)", "revision": "\(currentPlanRevision)"]
            )

            return PlanCommandResponse(
                text: "Added \"\(title)\" for \(durationMinutes)m. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func handleMove(title: String, start: Date, durationMinutes: Int?) async throws -> PlanCommandResponse {
        let matches = try await calendarStore.findManagedBlocks(fuzzyTitle: title, on: nil, calendar: calendar)

        if matches.isEmpty {
            audit("warning", "move_not_found", context: ["title": title])
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
        let original = target

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
            audit("warning", "move_rejected", context: ["reason": reason, "title": title])
            return PlanCommandResponse(text: "Move rejected: \(reason)", planRevision: currentPlanRevision)
        case let .requiresConfirmation(reason):
            audit("warning", "move_confirmation_required", context: ["reason": reason, "title": title])
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
            undoStack.append(.movedBlock(previous: original))
            trimUndoStack()
            audit("info", "move_success", context: ["title": title, "revision": "\(currentPlanRevision)"])

            return PlanCommandResponse(
                text: "Moved \"\(target.title)\" to \(isoLocal(start)). Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func handleUndo() async throws -> PlanCommandResponse {
        guard let lastOperation = undoStack.popLast() else {
            audit("info", "undo_empty", context: ["revision": "\(currentPlanRevision)"])
            return PlanCommandResponse(text: "Nothing to undo.", planRevision: currentPlanRevision)
        }

        currentPlanRevision += 1

        switch lastOperation {
        case let .createdBlock(blockID, ekEventID):
            try await calendarStore.deleteManagedBlock(
                blockID: blockID,
                ekEventID: ekEventID,
                calendarName: managedCalendarName
            )
            audit("info", "undo_created_block_removed", context: ["revision": "\(currentPlanRevision)"])
            return PlanCommandResponse(
                text: "Undo complete: removed last created block. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        case let .movedBlock(previous):
            var reverted = previous
            reverted.planRevision = currentPlanRevision
            _ = try await calendarStore.updateManagedBlock(reverted, calendarName: managedCalendarName)
            audit("info", "undo_move_restored", context: ["revision": "\(currentPlanRevision)"])
            return PlanCommandResponse(
                text: "Undo complete: restored previous block timing. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func trimUndoStack(maxEntries: Int = 100) {
        if undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }
    }

    private func audit(_ severity: String, _ message: String, context: [String: String] = [:]) {
        try? auditLogRepository?.log(category: "slack_plan_command", severity: severity, message: message, context: context)
    }

    private func isoLocal(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
