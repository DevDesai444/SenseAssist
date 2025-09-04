import CoreContracts
import GmailIntegration
import LLMRuntime
import ParserPipeline
import RulesEngine
import Storage
import Foundation

public struct GmailSyncSummary: Sendable {
    public var fetchedMessages: Int
    public var parsedUpdates: Int
    public var storedUpdates: Int
    public var createdOrUpdatedTasks: Int
    public var nextCursor: String?

    public init(
        fetchedMessages: Int,
        parsedUpdates: Int,
        storedUpdates: Int,
        createdOrUpdatedTasks: Int,
        nextCursor: String?
    ) {
        self.fetchedMessages = fetchedMessages
        self.parsedUpdates = parsedUpdates
        self.storedUpdates = storedUpdates
        self.createdOrUpdatedTasks = createdOrUpdatedTasks
        self.nextCursor = nextCursor
    }
}

public final class GmailIngestionService {
    private let gmailClient: GmailClient
    private let cursorRepository: ProviderCursorRepository
    private let updateRepository: UpdateRepository
    private let taskRepository: TaskRepository
    private let llmRuntime: LLMRuntimeClient
    private let confidenceThreshold: Double

    public init(
        gmailClient: GmailClient,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double = 0.80
    ) {
        self.gmailClient = gmailClient
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
    }

    public func sync() async throws -> GmailSyncSummary {
        let existingCursor = try cursorRepository.get(provider: .gmail)?.primary
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

        if let nextCursor {
            try cursorRepository.upsert(ProviderCursorRecord(provider: .gmail, primary: nextCursor))
        }

        return GmailSyncSummary(
            fetchedMessages: messages.count,
            parsedUpdates: updateCards.count,
            storedUpdates: storedUpdates,
            createdOrUpdatedTasks: storedTasks,
            nextCursor: nextCursor
        )
    }
}
