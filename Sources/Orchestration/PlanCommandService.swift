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

    private struct PersistedUndoEnvelope: Codable {
        var kind: String
        var blockID: String?
        var ekEventID: String?
        var previousBlock: CalendarBlock?
    }

    private let calendarStore: CalendarStore
    private let managedCalendarName: String
    private var currentPlanRevision: Int
    private let calendar: Calendar
    private let auditLogRepository: AuditLogRepository?
    private let operationRepository: OperationRepository?
    private let planRevisionRepository: PlanRevisionRepository?
    private var undoStack: [UndoOperation]
    private var hydratedState: Bool

    public init(
        calendarStore: CalendarStore,
        managedCalendarName: String = "SenseAssist",
        initialPlanRevision: Int = 1,
        calendar: Calendar = .current,
        auditLogRepository: AuditLogRepository? = nil,
        operationRepository: OperationRepository? = nil,
        planRevisionRepository: PlanRevisionRepository? = nil
    ) {
        self.calendarStore = calendarStore
        self.managedCalendarName = managedCalendarName
        self.currentPlanRevision = initialPlanRevision
        self.calendar = calendar
        self.auditLogRepository = auditLogRepository
        self.operationRepository = operationRepository
        self.planRevisionRepository = planRevisionRepository
        self.undoStack = []
        self.hydratedState = false
    }

    public func handle(commandText: String, now: Date = Date()) async -> PlanCommandResponse {
        do {
            hydrateStateIfNeeded()
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
            persistOperation(
                expectedRevision: operation.expectedPlanRevision,
                appliedRevision: currentPlanRevision,
                intent: operation.intent.rawValue,
                status: "applied",
                payload: operation,
                undoEnvelope: PersistedUndoEnvelope(
                    kind: "created_block",
                    blockID: created.blockID.uuidString,
                    ekEventID: created.ekEventID,
                    previousBlock: nil
                )
            )
            appendRevision(trigger: "slack_add", summary: PlanSummary(createdBlocks: 1, movedBlocks: 0, deletedBlocks: 0))
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
            persistOperation(
                expectedRevision: operation.expectedPlanRevision,
                appliedRevision: currentPlanRevision,
                intent: operation.intent.rawValue,
                status: "applied",
                payload: operation,
                undoEnvelope: PersistedUndoEnvelope(
                    kind: "moved_block",
                    blockID: nil,
                    ekEventID: nil,
                    previousBlock: original
                )
            )
            appendRevision(trigger: "slack_move", summary: PlanSummary(createdBlocks: 0, movedBlocks: 1, deletedBlocks: 0))
            audit("info", "move_success", context: ["title": title, "revision": "\(currentPlanRevision)"])

            return PlanCommandResponse(
                text: "Moved \"\(target.title)\" to \(isoLocal(start)). Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }
    }

    private func handleUndo() async throws -> PlanCommandResponse {
        var operationToUndo = undoStack.popLast()
        var persistedUndoOperationID: String?

        if operationToUndo == nil, let persisted = try operationRepository?.latestUndoableOperation() {
            persistedUndoOperationID = persisted.opID
            operationToUndo = decodePersistedUndoOperation(from: persisted.resultJSON)
        }

        guard let lastOperation = operationToUndo else {
            audit("info", "undo_empty", context: ["revision": "\(currentPlanRevision)"])
            return PlanCommandResponse(text: "Nothing to undo.", planRevision: currentPlanRevision)
        }

        currentPlanRevision += 1
        let response: PlanCommandResponse

        switch lastOperation {
        case let .createdBlock(blockID, ekEventID):
            try await calendarStore.deleteManagedBlock(
                blockID: blockID,
                ekEventID: ekEventID,
                calendarName: managedCalendarName
            )
            audit("info", "undo_created_block_removed", context: ["revision": "\(currentPlanRevision)"])
            response = PlanCommandResponse(
                text: "Undo complete: removed last created block. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        case let .movedBlock(previous):
            var reverted = previous
            reverted.planRevision = currentPlanRevision
            _ = try await calendarStore.updateManagedBlock(reverted, calendarName: managedCalendarName)
            audit("info", "undo_move_restored", context: ["revision": "\(currentPlanRevision)"])
            response = PlanCommandResponse(
                text: "Undo complete: restored previous block timing. Plan revision: \(currentPlanRevision)",
                planRevision: currentPlanRevision
            )
        }

        if let persistedUndoOperationID {
            try? operationRepository?.markUndone(opID: persistedUndoOperationID)
        }

        appendRevision(trigger: "slack_undo", summary: PlanSummary(createdBlocks: 0, movedBlocks: 0, deletedBlocks: 1))
        return response
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

    private func hydrateStateIfNeeded() {
        guard !hydratedState else {
            return
        }

        let persistedRevision = max(
            (try? planRevisionRepository?.latestRevisionID()) ?? 0,
            (try? operationRepository?.latestAppliedRevision()) ?? 0
        )
        currentPlanRevision = max(currentPlanRevision, persistedRevision)
        hydratedState = true
    }

    private func persistOperation(
        expectedRevision: Int?,
        appliedRevision: Int?,
        intent: String,
        status: String,
        payload: EditOperation,
        undoEnvelope: PersistedUndoEnvelope?
    ) {
        guard let operationRepository else {
            return
        }

        let payloadJSON = encodedJSONString(payload) ?? "{}"
        let resultJSON = undoEnvelope.flatMap { encodedJSONString($0) }
        let record = StoredOperationRecord(
            expectedPlanRevision: expectedRevision,
            appliedRevision: appliedRevision,
            intent: intent,
            status: status,
            payloadJSON: payloadJSON,
            resultJSON: resultJSON
        )
        try? operationRepository.insert(record)
    }

    private func appendRevision(trigger: String, summary: PlanSummary) {
        _ = try? planRevisionRepository?.append(trigger: trigger, summary: summary)
    }

    private func decodePersistedUndoOperation(from resultJSON: String?) -> UndoOperation? {
        guard let resultJSON,
              let data = resultJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PersistedUndoEnvelope.self, from: data)
        else {
            return nil
        }

        switch envelope.kind {
        case "created_block":
            guard let blockIDRaw = envelope.blockID,
                  let blockID = UUID(uuidString: blockIDRaw)
            else {
                return nil
            }
            return .createdBlock(blockID: blockID, ekEventID: envelope.ekEventID)
        case "moved_block":
            guard let previous = envelope.previousBlock else {
                return nil
            }
            return .movedBlock(previous: previous)
        default:
            return nil
        }
    }

    private func encodedJSONString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
