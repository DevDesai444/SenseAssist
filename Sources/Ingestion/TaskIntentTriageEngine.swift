import CoreContracts
import Foundation

public enum TaskIntentTriageClassification: String, Sendable {
    case actionable
    case maybeActionable = "maybe_actionable"
    case ignore
}

public struct TaskIntentTriageDecision: Sendable {
    public var classification: TaskIntentTriageClassification
    public var confidence: Double
    public var reasons: [String]

    public init(classification: TaskIntentTriageClassification, confidence: Double, reasons: [String]) {
        self.classification = classification
        self.confidence = confidence
        self.reasons = reasons
    }
}

public enum TaskIntentTriageEngine {
    public static func evaluate(update: UpdateCard) -> TaskIntentTriageDecision {
        let text = "\(update.subject)\n\(update.bodyText)".lowercased()
        let tags = Set(update.tags.map { $0.lowercased() })
        var reasons: [String] = []

        var score = min(max(update.parseConfidence, 0.0), 1.0) * 0.45

        if tags.contains("type:assignment") {
            score += 0.35
            reasons.append("assignment_tag")
        }
        if tags.contains("type:quiz") {
            score += 0.35
            reasons.append("quiz_tag")
        }
        if tags.contains("type:response_required") {
            score += 0.18
            reasons.append("response_required_tag")
        }

        if update.evidence.contains(where: { $0.lowercased().hasPrefix("due_date:") }) || text.contains(" due ") || text.contains("submit by ") {
            score += 0.20
            reasons.append("due_signal")
        }

        if text.contains("assignment") || text.contains("quiz") || text.contains("project") || text.contains("homework") || text.contains("leetcode") {
            score += 0.10
            reasons.append("task_keyword")
        }

        if tags.contains("type:announcement") {
            score -= 0.35
            reasons.append("announcement_penalty")
        }
        if tags.contains("type:untrusted_source") {
            score -= 0.55
            reasons.append("untrusted_source_penalty")
        }
        if update.requiresConfirmation {
            score -= 0.20
            reasons.append("confirmation_penalty")
        }

        let bounded = min(max(score, 0.0), 1.0)
        let classification: TaskIntentTriageClassification
        if bounded >= 0.70 {
            classification = .actionable
        } else if bounded >= 0.45 {
            classification = .maybeActionable
        } else {
            classification = .ignore
        }

        return TaskIntentTriageDecision(classification: classification, confidence: bounded, reasons: reasons)
    }
}
