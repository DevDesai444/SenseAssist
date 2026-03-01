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
    private let autoPlanningService: AutoPlanningService?

    public init(
        accountID: String,
        accountEmail: String,
        outlookClient: OutlookClient,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double = 0.80,
        autoPlanningService: AutoPlanningService? = nil
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.outlookClient = outlookClient
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
        self.autoPlanningService = autoPlanningService
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

        let approved = validated.compactMap { item -> UpdateCard? in
            if case .approved = item.1 { return item.0 }
            return nil
        }

        let tasks = try await llmRuntime.inferExtractTasks(from: approved)

        let storedUpdates = try updateRepository.upsert(updateCards)
        let storedTasks = try taskRepository.upsert(tasks)
        if let autoPlanningService {
            _ = try await autoPlanningService.regenerate(now: Date(), trigger: "outlook_sync")
        }

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
