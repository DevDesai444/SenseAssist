import CoreContracts
import Foundation
import ParserPipeline
import Testing

@Test func parsesPiazzaDigestIntoMultipleUpdateCards() {
    let message = InboundMessage(
        source: .piazzaEmail,
        messageID: "pz-1",
        receivedAtUTC: Date(),
        from: "notifications@piazza.com",
        subject: "Piazza Smart Digest",
        bodyText: "1. New post in CSE312\n2. Follow-up from instructor\n3. Reminder to check thread"
    )

    let parsed = ParserPipeline.parse(message: message)

    #expect(parsed.count == 3)
    #expect(parsed.allSatisfy { $0.templateType == "piazza_digest" })
    #expect(parsed.allSatisfy { $0.card.requiresConfirmation })
}

@Test func parsesUBLearnsAssignmentWithHighConfidence() {
    let message = InboundMessage(
        source: .ublearnsEmail,
        messageID: "ub-1",
        receivedAtUTC: Date(),
        from: "noreply@buffalo.edu",
        subject: "CSE312 Assignment posted",
        bodyText: "Your CSE312 homework is due on March 2 at 11:59pm.",
        links: ["https://ublearns.buffalo.edu"]
    )

    let parsed = ParserPipeline.parse(message: message)
    guard let first = parsed.first else {
        Issue.record("Expected one parsed card")
        return
    }

    #expect(first.templateType == "ublearns_assignment")
    #expect(first.card.parseConfidence >= 0.80)
    #expect(!first.card.requiresConfirmation)
    #expect(first.card.tags.contains("course:CSE312"))
}

@Test func marksUntrustedSenderForConfirmation() {
    let message = InboundMessage(
        source: .gmail,
        messageID: "x-1",
        receivedAtUTC: Date(),
        from: "spam@unknown.com",
        subject: "Assignment alert",
        bodyText: "Do this task"
    )

    let parsed = ParserPipeline.parse(message: message)
    guard let first = parsed.first else {
        Issue.record("Expected one parsed card")
        return
    }

    #expect(first.card.requiresConfirmation)
    #expect(first.card.parseConfidence < 0.5)
    #expect(first.card.tags.contains("type:untrusted_source"))
}
