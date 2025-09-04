import CoreContracts
import Foundation

public enum RuleDecision: Equatable, Sendable {
    case approved
    case requiresConfirmation(reason: String)
    case rejected(reason: String)
}

public struct EditValidationContext: Sendable {
    public var currentPlanRevision: Int
    public var matchedTargetCount: Int
    public var touchesNonAgentManagedEvent: Bool

    public init(currentPlanRevision: Int, matchedTargetCount: Int = 1, touchesNonAgentManagedEvent: Bool = false) {
        self.currentPlanRevision = currentPlanRevision
        self.matchedTargetCount = matchedTargetCount
        self.touchesNonAgentManagedEvent = touchesNonAgentManagedEvent
    }
}

public struct ExtractionValidationContext: Sendable {
    public var confidenceThreshold: Double

    public init(confidenceThreshold: Double) {
        self.confidenceThreshold = confidenceThreshold
    }
}

public enum RulesEngine {
    public static func validate(editOperation: EditOperation, context: EditValidationContext) -> RuleDecision {
        guard editOperation.expectedPlanRevision == context.currentPlanRevision else {
            return .rejected(reason: "stale_plan_revision")
        }

        if context.touchesNonAgentManagedEvent {
            return .requiresConfirmation(reason: "non_agent_event")
        }

        if context.matchedTargetCount > 1 {
            return .requiresConfirmation(reason: "ambiguous_target")
        }

        if editOperation.requiresConfirmation {
            return .requiresConfirmation(reason: editOperation.ambiguityReason ?? "explicit_confirmation_flag")
        }

        switch editOperation.intent {
        case .createBlock, .moveBlock, .resizeBlock:
            guard let start = editOperation.time.startLocal, let end = editOperation.time.endLocal, start < end else {
                return .rejected(reason: "invalid_or_missing_time_window")
            }
        case .deleteBlock, .markDone:
            if editOperation.target.ekEventID == nil, editOperation.target.fuzzyTitle?.isEmpty != false {
                return .rejected(reason: "missing_target")
            }
        case .lockSleep:
            guard editOperation.parameters.sleepWindow != nil else {
                return .rejected(reason: "missing_sleep_window")
            }
        case .regeneratePlan:
            break
        }

        return .approved
    }

    public static func validate(update: UpdateCard, context: ExtractionValidationContext) -> RuleDecision {
        guard update.parseConfidence >= 0.0, update.parseConfidence <= 1.0 else {
            return .rejected(reason: "invalid_confidence_range")
        }

        guard !update.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(reason: "empty_subject")
        }

        if update.parseConfidence < context.confidenceThreshold {
            return .requiresConfirmation(reason: "low_confidence")
        }

        if update.requiresConfirmation {
            return .requiresConfirmation(reason: "update_flagged_for_confirmation")
        }

        return .approved
    }
}
