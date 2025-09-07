import CoreContracts
import Foundation

public enum LLMRuntimeError: Error, LocalizedError {
    case unsupportedPrompt
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .unsupportedPrompt:
            return "Unsupported prompt for stub LLM runtime"
        case .invalidJSON:
            return "Invalid JSON payload"
        }
    }
}

public protocol LLMRuntimeClient: Sendable {
    func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem]
    func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation
}

public struct StubLLMRuntime: LLMRuntimeClient {
    public init() {}

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        updates.map { update in
            TaskItem(
                title: update.subject,
                category: .assignment,
                dueAtLocal: nil,
                estimatedMinutes: 60,
                minDailyMinutes: 30,
                priority: 1,
                stressWeight: 0.5,
                sources: [
                    TaskSource(
                        source: update.source,
                        accountID: update.accountID,
                        messageID: update.providerIDs.messageID,
                        confidence: update.parseConfidence
                    )
                ]
            )
        }
    }

    public func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        let normalized = messageText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("today") || normalized.hasPrefix("regenerate") {
            return EditOperation(
                expectedPlanRevision: expectedPlanRevision,
                intent: .regeneratePlan,
                target: EditTarget(),
                time: EditTime(),
                notes: "Regenerate today's plan"
            )
        }

        if normalized.hasPrefix("lock sleep") {
            return EditOperation(
                expectedPlanRevision: expectedPlanRevision,
                intent: .lockSleep,
                target: EditTarget(),
                time: EditTime(),
                parameters: EditParameters(sleepWindow: SleepWindow(start: "00:30", end: "08:00")),
                notes: "Lock sleep window"
            )
        }

        throw LLMRuntimeError.unsupportedPrompt
    }
}
