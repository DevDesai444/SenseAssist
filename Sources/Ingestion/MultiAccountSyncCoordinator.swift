import CoreContracts
import GmailIntegration
import LLMRuntime
import OutlookIntegration
import Storage
import Foundation

public struct MultiAccountSyncResult: Sendable {
    public var gmail: [GmailSyncSummary]
    public var outlook: [OutlookSyncSummary]
    public var failures: [AccountSyncFailure]

    public var totalFetched: Int {
        gmail.reduce(0) { $0 + $1.fetchedMessages } + outlook.reduce(0) { $0 + $1.fetchedMessages }
    }

    public var totalStoredUpdates: Int {
        gmail.reduce(0) { $0 + $1.storedUpdates } + outlook.reduce(0) { $0 + $1.storedUpdates }
    }

    public var totalTasksTouched: Int {
        gmail.reduce(0) { $0 + $1.createdOrUpdatedTasks } + outlook.reduce(0) { $0 + $1.createdOrUpdatedTasks }
    }

    public init(gmail: [GmailSyncSummary], outlook: [OutlookSyncSummary], failures: [AccountSyncFailure] = []) {
        self.gmail = gmail
        self.outlook = outlook
        self.failures = failures
    }
}

public struct AccountSyncFailure: Sendable {
    public var provider: StorageProvider
    public var accountID: String
    public var accountEmail: String
    public var reason: String

    public init(provider: StorageProvider, accountID: String, accountEmail: String, reason: String) {
        self.provider = provider
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.reason = reason
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
    private let autoPlanningService: AutoPlanningService?

    public init(
        accountRepository: AccountRepository,
        cursorRepository: ProviderCursorRepository,
        updateRepository: UpdateRepository,
        taskRepository: TaskRepository,
        llmRuntime: LLMRuntimeClient,
        confidenceThreshold: Double,
        gmailClientFactory: @escaping (ConnectedEmailAccount) -> GmailClient?,
        outlookClientFactory: @escaping (ConnectedEmailAccount) -> OutlookClient?,
        autoPlanningService: AutoPlanningService? = nil
    ) {
        self.accountRepository = accountRepository
        self.cursorRepository = cursorRepository
        self.updateRepository = updateRepository
        self.taskRepository = taskRepository
        self.llmRuntime = llmRuntime
        self.confidenceThreshold = confidenceThreshold
        self.gmailClientFactory = gmailClientFactory
        self.outlookClientFactory = outlookClientFactory
        self.autoPlanningService = autoPlanningService
    }

    public func syncAllEnabledAccounts() async throws -> MultiAccountSyncResult {
        let accounts = try accountRepository.list(enabledOnly: true)

        var gmailSummaries: [GmailSyncSummary] = []
        var outlookSummaries: [OutlookSyncSummary] = []
        var failures: [AccountSyncFailure] = []

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
                    confidenceThreshold: confidenceThreshold,
                    autoPlanningService: autoPlanningService
                )
                do {
                    gmailSummaries.append(try await service.sync())
                } catch {
                    failures.append(
                        AccountSyncFailure(
                            provider: .gmail,
                            accountID: account.accountID,
                            accountEmail: account.email,
                            reason: error.localizedDescription
                        )
                    )
                }
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
                    confidenceThreshold: confidenceThreshold,
                    autoPlanningService: autoPlanningService
                )
                do {
                    outlookSummaries.append(try await service.sync())
                } catch {
                    failures.append(
                        AccountSyncFailure(
                            provider: .outlook,
                            accountID: account.accountID,
                            accountEmail: account.email,
                            reason: error.localizedDescription
                        )
                    )
                }
            }
        }

        return MultiAccountSyncResult(gmail: gmailSummaries, outlook: outlookSummaries, failures: failures)
    }
}
