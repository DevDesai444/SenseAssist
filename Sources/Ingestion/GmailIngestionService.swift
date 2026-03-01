import CoreContracts
import GmailIntegration
import LLMRuntime
import ParserPipeline
import RulesEngine
import Storage
import Foundation

public struct GmailSyncSummary: Sendable {
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

public final class GmailIngestionService {
    private let accountID: String
    private let accountEmail: String
    private let gmailClient: GmailClient
    private let cursorRepository: ProviderCursorRepository
    private let updateRepository: UpdateRepository
    private let taskRepository: TaskRepository
    private let llmRuntime: LLMRuntimeClient
    private let confidenceThreshold: Double
    private let autoPlanningService: AutoPlanningService?

    public init(
        accountID: String,
        accountEmail: String,
        gmailClient: GmailClient,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double = 0.80,
        autoPlanningService: AutoPlanningService? = nil
    ) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.gmailClient = gmailClient
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
        self.autoPlanningService = autoPlanningService
    }

    public func sync() async throws -> GmailSyncSummary {
        let existingCursorRecord = try cursorRepository.get(provider: .gmail, accountID: accountID)
        let existingCursor = parseCursor(existingCursorRecord)
        let (messages, nextCursor) = try await gmailClient.fetchMessages(since: existingCursor)

        let parsed = messages.flatMap { message in
            ParserPipeline.parse(
                message: InboundMessage(
                    source: .gmail,
                    messageID: message.messageID,
                    threadID: message.threadID,
                    receivedAtUTC: message.internalDate,
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

        let approvedUpdates = validated.compactMap { pair in
            if case .approved = pair.1 { return pair.0 }
            return nil
        }

        let tasks = try await llmRuntime.inferExtractTasks(from: approvedUpdates)

        let storedUpdates = try updateRepository.upsert(updateCards)
        let storedTasks = try taskRepository.upsert(tasks)
        if let autoPlanningService {
            _ = try await autoPlanningService.regenerate(now: Date(), trigger: "gmail_sync")
        }

        if let nextCursor {
            try cursorRepository.upsert(
                ProviderCursorRecord(
                    provider: .gmail,
                    accountID: accountID,
                    primary: String(nextCursor.internalDateSeconds),
                    secondary: nextCursor.messageID
                )
            )
        }

        return GmailSyncSummary(
            accountID: accountID,
            accountEmail: accountEmail,
            fetchedMessages: messages.count,
            parsedUpdates: updateCards.count,
            storedUpdates: storedUpdates,
            createdOrUpdatedTasks: storedTasks,
            nextCursor: nextCursor.map { "\($0.internalDateSeconds)" }
        )
    }

    private func parseCursor(_ record: ProviderCursorRecord?) -> GmailSyncCursor? {
        guard let record else {
            return nil
        }

        // Backward compatibility: if old cursor format was stored as plain seconds, keep using it.
        let seconds = Int(record.primary) ?? 0
        guard seconds > 0 else {
            return nil
        }

        return GmailSyncCursor(internalDateSeconds: seconds, messageID: record.secondary)
    }
}
