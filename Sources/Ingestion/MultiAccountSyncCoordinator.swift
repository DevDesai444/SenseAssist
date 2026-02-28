import CoreContracts
import GmailIntegration
import LLMRuntime
import OutlookIntegration
import Storage
import Foundation

public struct MultiAccountSyncResult: Sendable {
    public var gmail: [GmailSyncSummary]
    public var outlook: [OutlookSyncSummary]

    public var totalFetched: Int {
        gmail.reduce(0) { $0 + $1.fetchedMessages } + outlook.reduce(0) { $0 + $1.fetchedMessages }
    }

    public var totalStoredUpdates: Int {
        gmail.reduce(0) { $0 + $1.storedUpdates } + outlook.reduce(0) { $0 + $1.storedUpdates }
    }

    public var totalTasksTouched: Int {
        gmail.reduce(0) { $0 + $1.createdOrUpdatedTasks } + outlook.reduce(0) { $0 + $1.createdOrUpdatedTasks }
    }

    public init(gmail: [GmailSyncSummary], outlook: [OutlookSyncSummary]) {
        self.gmail = gmail
        self.outlook = outlook
    }
}

public final class MultiAccountSyncCoordinator {
    private let accountRepository: AccountRepository
    private let cursorRepository: ProviderCursorRepository
    private let updateRepository: UpdateRepository
    private let taskRepository: TaskRepository
    private let llmRuntime: LLMRuntimeClient
    private let confidenceThreshold: Double
    private let gmailClientFactory: (ConnectedEmailAccount) -> GmailClient?
    private let outlookClientFactory: (ConnectedEmailAccount) -> OutlookClient?

    public init(
        accountRepository: AccountRepository,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double,
        gmailClientFactory: @escaping (ConnectedEmailAccount) -> GmailClient?,
        outlookClientFactory: @escaping (ConnectedEmailAccount) -> OutlookClient?
    ) {
        self.accountRepository = accountRepository
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
        self.gmailClientFactory = gmailClientFactory
        self.outlookClientFactory = outlookClientFactory
    }

    public func syncAllEnabledAccounts() async throws -> MultiAccountSyncResult {
        let accounts = try accountRepository.list(enabledOnly: true)

        var gmailSummaries: [GmailSyncSummary] = []
        var outlookSummaries: [OutlookSyncSummary] = []

        for account in accounts {
            switch account.provider {
            case .gmail:
                guard let gmailClient = gmailClientFactory(account) else { continue }
                let service = GmailIngestionService(
                    accountID: account.accountID,
                    accountEmail: account.email,
                    gmailClient: gmailClient,
                    cursorRepository: cursorRepository,
                    updateRepository: updateRepository,
                    taskRepository: taskRepository,
                    llmRuntime: llmRuntime,
                    confidenceThreshold: confidenceThreshold
                )
                gmailSummaries.append(try await service.sync())
            case .outlook:
                guard let outlookClient = outlookClientFactory(account) else { continue }
                let service = OutlookIngestionService(
                    accountID: account.accountID,
                    accountEmail: account.email,
                    outlookClient: outlookClient,
                    cursorRepository: cursorRepository,
                    updateRepository: updateRepository,
                    taskRepository: taskRepository,
                    llmRuntime: llmRuntime,
                    confidenceThreshold: confidenceThreshold
                )
                outlookSummaries.append(try await service.sync())
            }
        }

        return MultiAccountSyncResult(gmail: gmailSummaries, outlook: outlookSummaries)
    }
}
