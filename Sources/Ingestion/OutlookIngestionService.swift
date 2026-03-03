import CoreContracts
import LLMRuntime
import OutlookIntegration
import ParserPipeline
import RulesEngine
import Storage
import Foundation

public struct OutlookSyncSummary: Sendable {
    public var accountID: String
    public var accountEmail: String
    public var fetchedMessages: Int
    public var parsedUpdates: Int
    public var storedUpdates: Int
    public var createdOrUpdatedTasks: Int
    public var nextCursor: String?

    public init(
        accountID: String,
        accountEmail: String,
        fetchedMessages: Int,
        parsedUpdates: Int,
        storedUpdates: Int,
        createdOrUpdatedTasks: Int,
        nextCursor: String?
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.fetchedMessages = fetchedMessages
        self.parsedUpdates = parsedUpdates
        self.storedUpdates = storedUpdates
        self.createdOrUpdatedTasks = createdOrUpdatedTasks
        self.nextCursor = nextCursor
    }
}

public final class OutlookIngestionService {
    private let accountID: String
    private let accountEmail: String
    private let outlookClient: OutlookClient
    private let cursorRepository: ProviderCursorRepository
    private let updateRepository: UpdateRepository
    private let taskRepository: TaskRepository
    private let llmRuntime: LLMRuntimeClient
    private let confidenceThreshold: Double

    public init(
        accountID: String,
        accountEmail: String,
        outlookClient: OutlookClient,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double = 0.80
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.outlookClient = outlookClient
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
    }

    public func sync() async throws -> OutlookSyncSummary {
        let existingCursorRecord = try cursorRepository.get(provider: .outlook, accountID: accountID)
        let existingCursor = parseCursor(existingCursorRecord)
        let (messages, nextCursor) = try await outlookClient.fetchMessages(since: existingCursor)

        let parsed = messages.flatMap { message in
            ParserPipeline.parse(
                message: InboundMessage(
                    source: .outlook,
                    messageID: message.messageID,
                    threadID: message.conversationID,
                    receivedAtUTC: message.receivedDateTime,
                    from: message.from,
                    subject: message.subject,
                    bodyText: message.bodyText,
                    links: message.links
                )
            )
            .map {
                var parsed = $0
                parsed.card.accountID = accountID
                return parsed
            }
        }

        let updateCards = parsed.map(\.card)
        let validated = updateCards.map { card in
            (card, RulesEngine.validate(update: card, context: ExtractionValidationContext(confidenceThreshold: confidenceThreshold)))
        }

        var updatesForStorage: [UpdateCard] = []
        var extractionCandidates: [UpdateCard] = []
        for (card, decision) in validated {
            switch decision {
            case .approved:
                let triage = TaskIntentTriageEngine.evaluate(update: card)
                switch triage.classification {
                case .actionable:
                    var enriched = card
                    enriched.tags = appendUniqueTag("triage:actionable", to: enriched.tags)
                    updatesForStorage.append(enriched)
                    extractionCandidates.append(enriched)
                case .maybeActionable:
                    updatesForStorage.append(markForReview(update: card, reason: "triage_maybe_actionable"))
                case .ignore:
                    var enriched = card
                    enriched.tags = appendUniqueTag("triage:ignored", to: enriched.tags)
                    updatesForStorage.append(enriched)
                }
            case let .requiresConfirmation(reason):
                updatesForStorage.append(markForReview(update: card, reason: "rules_\(sanitizeTag(reason))"))
            case let .rejected(reason):
                var enriched = card
                enriched.tags = appendUniqueTag("rules:rejected:\(sanitizeTag(reason))", to: enriched.tags)
                updatesForStorage.append(enriched)
            }
        }

        let tasks = try await llmRuntime.inferExtractTasks(from: extractionCandidates)

        let storedUpdates = try updateRepository.upsert(updatesForStorage)
        let storedTasks = try taskRepository.upsert(tasks)

        if let nextCursor {
            try cursorRepository.upsert(
                ProviderCursorRecord(
                    provider: .outlook,
                    accountID: accountID,
                    primary: nextCursor.receivedDateTimeISO8601,
                    secondary: nextCursor.messageID
                )
            )
        }

        return OutlookSyncSummary(
            accountID: accountID,
            accountEmail: accountEmail,
            fetchedMessages: messages.count,
            parsedUpdates: updateCards.count,
            storedUpdates: storedUpdates,
            createdOrUpdatedTasks: storedTasks,
            nextCursor: nextCursor?.receivedDateTimeISO8601
        )
    }

    private func markForReview(update: UpdateCard, reason: String) -> UpdateCard {
        var enriched = update
        enriched.requiresConfirmation = true
        var tags = enriched.tags
        tags = appendUniqueTag("review_queue", to: tags)
        tags = appendUniqueTag("review_reason:\(sanitizeTag(reason))", to: tags)
        enriched.tags = tags
        return enriched
    }

    private func appendUniqueTag(_ tag: String, to tags: [String]) -> [String] {
        if tags.contains(tag) {
            return tags
        }
        return tags + [tag]
    }

    private func sanitizeTag(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private func parseCursor(_ record: ProviderCursorRecord?) -> OutlookSyncCursor? {
        guard let record else {
            return nil
        }

        // Backward compatibility: older runs stored ISO-8601 in primary only.
        guard ISO8601DateFormatter().date(from: record.primary) != nil else {
            return nil
        }

        return OutlookSyncCursor(receivedDateTimeISO8601: record.primary, messageID: record.secondary)
    }
}
