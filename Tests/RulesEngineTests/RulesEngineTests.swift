import CoreContracts
import Foundation
import RulesEngine
import Testing

@Test func rejectsStalePlanRevision() {
    let operation = EditOperation(
        expectedPlanRevision: 1,
        intent: .regeneratePlan,
        target: EditTarget(),
        time: EditTime()
    )

    let decision = RulesEngine.validate(
        editOperation: operation,
        context: EditValidationContext(currentPlanRevision: 2)
    )

    #expect(decision == .rejected(reason: "stale_plan_revision"))
}

@Test func requiresConfirmationForAmbiguousTarget() {
    let start = Date(timeIntervalSince1970: 1_709_251_200)
    let operation = EditOperation(
        expectedPlanRevision: 5,
        intent: .moveBlock,
        target: EditTarget(fuzzyTitle: "homework"),
        time: EditTime(startLocal: start, endLocal: start.addingTimeInterval(3600))
    )

    let decision = RulesEngine.validate(
        editOperation: operation,
        context: EditValidationContext(currentPlanRevision: 5, matchedTargetCount: 2)
    )

    #expect(decision == .requiresConfirmation(reason: "ambiguous_target"))
}

@Test func lowConfidenceUpdateRequiresConfirmation() {
    let update = UpdateCard(
        source: .gmail,
        providerIDs: ProviderIDs(messageID: "m1"),
        receivedAtUTC: Date(),
        from: "noreply@buffalo.edu",
        subject: "Assignment posted",
        bodyText: "...",
        parserMethod: .ruleBased,
        parseConfidence: 0.4
    )

    let decision = RulesEngine.validate(update: update, context: ExtractionValidationContext(confidenceThreshold: 0.8))

    #expect(decision == .requiresConfirmation(reason: "low_confidence"))
}
