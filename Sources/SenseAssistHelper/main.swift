import Auth
import CoreContracts
import EventKitAdapter
import Foundation
import GmailIntegration
import Ingestion
import LLMRuntime
import Orchestration
import OutlookIntegration
import ParserPipeline
import Planner
import RulesEngine
import SlackIntegration
import Storage

@main
struct SenseAssistHelperMain {
    private static let demoMultiAccounts: [ConnectedEmailAccount] = [
        ConnectedEmailAccount(
            accountID: "gmail:demo.student.one@example.com",
            provider: .gmail,
            email: "demo.student.one@example.com"
        ),
        ConnectedEmailAccount(
            accountID: "gmail:demo.student.two@example.com",
            provider: .gmail,
            email: "demo.student.two@example.com"
        ),
        ConnectedEmailAccount(
            accountID: "gmail:demo.student.three@example.com",
            provider: .gmail,
            email: "demo.student.three@example.com"
        ),
        ConnectedEmailAccount(
            accountID: "outlook:demo.student@university.example",
            provider: .outlook,
            email: "demo.student@university.example"
        )
    ]

    static func main() async {
        let logger = ConsoleLogger(minimumLevel: .info)

        do {
            let environment = ProcessInfo.processInfo.environment
            let arguments = ProcessInfo.processInfo.arguments
            let home = environment["HOME"] ?? FileManager.default.currentDirectoryPath
            let config = SenseAssistConfiguration.default(homeDirectory: home)
            let demoModeEnabled = environment["SENSEASSIST_ENABLE_DEMO_COMMANDS"] == "1" || arguments.contains("--allow-demo")

            let bootstrap = try StorageBootstrap.run(config: config, logger: logger)
            guard bootstrap.healthy else {
                logger.log(.error, "Storage health check failed", category: "helper")
                Foundation.exit(1)
            }

            if arguments.contains("--health-check") {
                logger.log(.info, "health=ok db=\(bootstrap.databasePath)", category: "helper")
                Foundation.exit(0)
            }

            if let command = extractPlanCommand(arguments: arguments) {
                let commandStore = SQLiteStore(databasePath: config.databasePath, logger: logger)
                try commandStore.initialize()
                let auditRepository = AuditLogRepository(store: commandStore)
                let operationRepository = OperationRepository(store: commandStore)
                let planRevisionRepository = PlanRevisionRepository(store: commandStore)

                let service = PlanCommandService(
                    calendarStore: EventKitService(),
                    auditLogRepository: auditRepository,
                    operationRepository: operationRepository,
                    planRevisionRepository: planRevisionRepository
                )
                let response = await service.handle(commandText: command, now: Date())
                print(response.text)
                Foundation.exit(response.requiresConfirmation ? 2 : 0)
            }

            if arguments.contains("--gmail-sync-demo") {
                guard demoModeEnabled else { throw LiveSyncError.demoModeDisabled }
                let summary = try await runGmailSyncDemo(config: config, logger: logger)
                print(
                    "Gmail sync summary: account=\(summary.accountEmail) fetched=\(summary.fetchedMessages) parsed=\(summary.parsedUpdates) stored_updates=\(summary.storedUpdates) tasks=\(summary.createdOrUpdatedTasks) next_cursor=\(summary.nextCursor ?? "nil")"
                )
                Foundation.exit(0)
            }

            if arguments.contains("--outlook-sync-demo") {
                guard demoModeEnabled else { throw LiveSyncError.demoModeDisabled }
                let summary = try await runOutlookSyncDemo(config: config, logger: logger)
                print(
                    "Outlook sync summary: account=\(summary.accountEmail) fetched=\(summary.fetchedMessages) parsed=\(summary.parsedUpdates) stored_updates=\(summary.storedUpdates) tasks=\(summary.createdOrUpdatedTasks) next_cursor=\(summary.nextCursor ?? "nil")"
                )
                Foundation.exit(0)
            }

            if arguments.contains("--sync-all-demo") {
                guard demoModeEnabled else { throw LiveSyncError.demoModeDisabled }
                let report = try await runMultiAccountSyncDemo(config: config, logger: logger)
                print(report)
                Foundation.exit(0)
            }

            if arguments.contains("--sync-live-once") {
                let report = try await runMultiAccountSyncLive(config: config, logger: logger)
                print(report.report)
                Foundation.exit(0)
            }

            logger.log(.info, "SenseAssist helper initialized", category: "helper")

            let runtimeStore = SQLiteStore(databasePath: config.databasePath, logger: logger)
            try runtimeStore.initialize()
            let runtimeAuditRepository = AuditLogRepository(store: runtimeStore)
            let runtimeOperationRepository = OperationRepository(store: runtimeStore)
            let runtimePlanRevisionRepository = PlanRevisionRepository(store: runtimeStore)
            let runtimePlanService = PlanCommandService(
                calendarStore: EventKitService(),
                auditLogRepository: runtimeAuditRepository,
                operationRepository: runtimeOperationRepository,
                planRevisionRepository: runtimePlanRevisionRepository
            )

            var connectedSlackClient: SlackWebAPIClient?
            if let botToken = environment["SENSEASSIST_SLACK_BOT_TOKEN"], !botToken.isEmpty,
               let appToken = environment["SENSEASSIST_SLACK_APP_TOKEN"], !appToken.isEmpty {
                let slackClient = SlackWebAPIClient(botToken: botToken, appLevelToken: appToken)
                await slackClient.setCommandHandler { command in
                    let response = await runtimePlanService.handle(commandText: command.text, now: Date())
                    return response.text
                }
                try await slackClient.connect()
                connectedSlackClient = slackClient
                logger.log(.info, "Slack Socket Mode connected", category: "slack")
            } else {
                logger.log(
                    .warning,
                    "Slack tokens are not configured. Set SENSEASSIST_SLACK_BOT_TOKEN and SENSEASSIST_SLACK_APP_TOKEN for runtime command routing.",
                    category: "slack"
                )
            }

            _ = connectedSlackClient
            try await runBackgroundSyncLoop(config: config, logger: logger)
        } catch {
            fputs("Helper failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func extractPlanCommand(arguments: [String]) -> String? {
        guard let commandIndex = arguments.firstIndex(of: "--plan") else {
            return nil
        }

        let next = arguments.dropFirst(commandIndex + 1)
        guard !next.isEmpty else {
            return nil
        }

        return next.joined(separator: " ")
    }

    private static func runGmailSyncDemo(config: SenseAssistConfiguration, logger: Logging) async throws -> GmailSyncSummary {
        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()

        let cursorRepository = ProviderCursorRepository(store: store)
        let updateRepository = UpdateRepository(store: store)
        let taskRepository = TaskRepository(store: store)
        let llmRuntime = StubLLMRuntime()

        let sampleMessage = GmailMessage(
            messageID: "demo-msg-1",
            threadID: "demo-thread-1",
            internalDate: Date(),
            from: "noreply@buffalo.edu",
            subject: "CSE312 Assignment posted - due on March 2 at 11:59pm",
            bodyText: "A new assignment is available. Please submit by due on March 2 at 11:59pm.",
            links: ["https://ublearns.buffalo.edu"]
        )

        let client = StubGmailClient(
            pages: [
                (
                    cursor: nil,
                    messages: [sampleMessage],
                    nextCursor: GmailSyncCursor(
                        internalDateSeconds: Int(sampleMessage.internalDate.timeIntervalSince1970),
                        messageID: sampleMessage.messageID
                    )
                ),
                (
                    cursor: GmailSyncCursor(
                        internalDateSeconds: Int(sampleMessage.internalDate.timeIntervalSince1970),
                        messageID: sampleMessage.messageID
                    ),
                    messages: [],
                    nextCursor: GmailSyncCursor(
                        internalDateSeconds: Int(sampleMessage.internalDate.timeIntervalSince1970),
                        messageID: sampleMessage.messageID
                    )
                )
            ]
        )
        let service = GmailIngestionService(
            accountID: "gmail:demo",
            accountEmail: "demo@gmail.com",
            gmailClient: client,
            cursorRepository: cursorRepository,
            updateRepository: updateRepository,
            taskRepository: taskRepository,
            llmRuntime: llmRuntime,
            confidenceThreshold: config.confidenceThreshold
        )

        let summary = try await service.sync()
        store.close()
        return summary
    }

    private static func runOutlookSyncDemo(config: SenseAssistConfiguration, logger: Logging) async throws -> OutlookSyncSummary {
        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()

        let cursorRepository = ProviderCursorRepository(store: store)
        let updateRepository = UpdateRepository(store: store)
        let taskRepository = TaskRepository(store: store)
        let llmRuntime = StubLLMRuntime()

        let sampleMessage = OutlookMessage(
            messageID: "out-demo-1",
            conversationID: "conv-1",
            receivedDateTime: Date(),
            from: "noreply@buffalo.edu",
            subject: "CSE331 quiz reminder due by March 3 at 5pm",
            bodyText: "Quiz posted. Please submit by March 3 at 5pm.",
            links: ["https://ublearns.buffalo.edu"]
        )

        let client = StubOutlookClient(
            pages: [
                (
                    cursor: nil,
                    messages: [sampleMessage],
                    nextCursor: OutlookSyncCursor(
                        receivedDateTimeISO8601: ISO8601DateFormatter().string(from: sampleMessage.receivedDateTime),
                        messageID: sampleMessage.messageID
                    )
                ),
                (
                    cursor: OutlookSyncCursor(
                        receivedDateTimeISO8601: ISO8601DateFormatter().string(from: sampleMessage.receivedDateTime),
                        messageID: sampleMessage.messageID
                    ),
                    messages: [],
                    nextCursor: OutlookSyncCursor(
                        receivedDateTimeISO8601: ISO8601DateFormatter().string(from: sampleMessage.receivedDateTime),
                        messageID: sampleMessage.messageID
                    )
                )
            ]
        )
        let service = OutlookIngestionService(
            accountID: "outlook:demo",
            accountEmail: "demo@outlook.com",
            outlookClient: client,
            cursorRepository: cursorRepository,
            updateRepository: updateRepository,
            taskRepository: taskRepository,
            llmRuntime: llmRuntime,
            confidenceThreshold: config.confidenceThreshold
        )

        let summary = try await service.sync()
        store.close()
        return summary
    }

    private static func runMultiAccountSyncDemo(config: SenseAssistConfiguration, logger: Logging) async throws -> String {
        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()

        let accountRepository = AccountRepository(store: store)
        for account in demoMultiAccounts {
            try accountRepository.upsert(account)
        }

        let cursorRepository = ProviderCursorRepository(store: store)
        let updateRepository = UpdateRepository(store: store)
        let taskRepository = TaskRepository(store: store)
        let llmRuntime = StubLLMRuntime()

        let coordinator = MultiAccountSyncCoordinator(
            accountRepository: accountRepository,
            cursorRepository: cursorRepository,
            updateRepository: updateRepository,
            taskRepository: taskRepository,
            llmRuntime: llmRuntime,
            confidenceThreshold: config.confidenceThreshold,
            gmailClientFactory: { account in
                guard account.provider == .gmail else { return nil }
                let message = GmailMessage(
                    messageID: "shared-demo-message-1",
                    threadID: "thread-\(account.accountID)",
                    internalDate: Date(),
                    from: "noreply@buffalo.edu",
                    subject: "CSE312 Assignment update due on March 2 at 11:59pm",
                    bodyText: "Account \(account.email) received assignment update due on March 2 at 11:59pm.",
                    links: ["https://ublearns.buffalo.edu"]
                )
                return StubGmailClient(
                    pages: [
                        (
                            cursor: nil,
                            messages: [message],
                            nextCursor: GmailSyncCursor(
                                internalDateSeconds: Int(message.internalDate.timeIntervalSince1970),
                                messageID: message.messageID
                            )
                        ),
                        (
                            cursor: GmailSyncCursor(
                                internalDateSeconds: Int(message.internalDate.timeIntervalSince1970),
                                messageID: message.messageID
                            ),
                            messages: [],
                            nextCursor: GmailSyncCursor(
                                internalDateSeconds: Int(message.internalDate.timeIntervalSince1970),
                                messageID: message.messageID
                            )
                        )
                    ]
                )
            },
            outlookClientFactory: { account in
                guard account.provider == .outlook else { return nil }
                let message = OutlookMessage(
                    messageID: "shared-demo-message-1",
                    conversationID: "conv-\(account.accountID)",
                    receivedDateTime: Date(),
                    from: "noreply@buffalo.edu",
                    subject: "CSE331 Quiz reminder due by March 3 at 5pm",
                    bodyText: "Account \(account.email) received quiz reminder due by March 3 at 5pm.",
                    links: ["https://ublearns.buffalo.edu"]
                )
                return StubOutlookClient(
                    pages: [
                        (
                            cursor: nil,
                            messages: [message],
                            nextCursor: OutlookSyncCursor(
                                receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
                                messageID: message.messageID
                            )
                        ),
                        (
                            cursor: OutlookSyncCursor(
                                receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
                                messageID: message.messageID
                            ),
                            messages: [],
                            nextCursor: OutlookSyncCursor(
                                receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
                                messageID: message.messageID
                            )
                        )
                    ]
                )
            }
        )

        let result = try await coordinator.syncAllEnabledAccounts()
        let accounts = try accountRepository.list(enabledOnly: true)
        var lines: [String] = ["Connected accounts sync summary:"]
        lines.append(
            contentsOf: result.gmail.map {
                "gmail \($0.accountEmail): fetched=\($0.fetchedMessages) stored_updates=\($0.storedUpdates) tasks=\($0.createdOrUpdatedTasks)"
            }
        )
        lines.append(
            contentsOf: result.outlook.map {
                "outlook \($0.accountEmail): fetched=\($0.fetchedMessages) stored_updates=\($0.storedUpdates) tasks=\($0.createdOrUpdatedTasks)"
            }
        )

        let totalUpdates = try updateRepository.count()
        let totalTasks = try taskRepository.count()
        lines.append(
            "totals: fetched=\(result.totalFetched) updates=\(totalUpdates) tasks=\(totalTasks) accounts=\(accounts.count)"
        )

        store.close()
        return lines.joined(separator: "\n")
    }

    private static func runBackgroundSyncLoop(config: SenseAssistConfiguration, logger: Logging) async throws {
        var syncState: SyncState = .normal
        var retryCount = 0

        while true {
            let seed = Int(Date().timeIntervalSince1970)
            let interval = AdaptiveSyncScheduler.nextInterval(for: syncState, config: config.sync, seed: seed)
            let sleepSeconds = (interval.delayMinutes * 60) + interval.jitterSeconds
            try await Task.sleep(for: .seconds(sleepSeconds))

            do {
                let report = try await runMultiAccountSyncLive(config: config, logger: logger)
                logger.log(.info, report.report, category: "sync")
                retryCount = 0
                syncState = report.totalFetched > 0 ? .active : .idle
            } catch {
                retryCount += 1
                syncState = .error(retryCount: retryCount)
                logger.log(.warning, "background_sync_failed: \(error.localizedDescription)", category: "sync")
            }
        }
    }

    private struct LiveSyncExecutionResult: Sendable {
        let report: String
        let totalFetched: Int
    }

    private static func runMultiAccountSyncLive(config: SenseAssistConfiguration, logger: Logging) async throws -> LiveSyncExecutionResult {
        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()
        defer { store.close() }

        let accountRepository = AccountRepository(store: store)
        let enabledAccounts = try accountRepository.list(enabledOnly: true)

        guard !enabledAccounts.isEmpty else {
            throw LiveSyncError.noEnabledAccounts
        }

        let cursorRepository = ProviderCursorRepository(store: store)
        let updateRepository = UpdateRepository(store: store)
        let taskRepository = TaskRepository(store: store)
        let planRevisionRepository = PlanRevisionRepository(store: store)
        let operationRepository = OperationRepository(store: store)
        let credentialStore = ChainedCredentialStore(stores: [KeychainCredentialStore(), EnvironmentCredentialStore()])
        let llmRuntime = try configuredLLMRuntime()

        var gmailTokens: [String: String] = [:]
        var outlookTokens: [String: String] = [:]
        var skippedAccounts: [String] = []

        for account in enabledAccounts {
            switch account.provider {
            case .gmail:
                if let credential = try loadCredential(
                    store: credentialStore,
                    provider: .gmail,
                    accountID: account.accountID,
                    email: account.email
                ) {
                    gmailTokens[account.accountID] = credential.accessToken
                } else {
                    skippedAccounts.append("gmail \(account.email): missing OAuth token")
                }
            case .outlook:
                if let credential = try loadCredential(
                    store: credentialStore,
                    provider: .outlook,
                    accountID: account.accountID,
                    email: account.email
                ) {
                    outlookTokens[account.accountID] = credential.accessToken
                } else {
                    skippedAccounts.append("outlook \(account.email): missing OAuth token")
                }
            }
        }

        if gmailTokens.isEmpty && outlookTokens.isEmpty {
            throw LiveSyncError.noCredentialsConfigured
        }

        let eventKitService = EventKitService()
        let permissionState = await eventKitService.currentPermissionState()
        let autoPlanningService: AutoPlanningService?
        switch permissionState {
        case .fullAccess, .writeOnly:
            autoPlanningService = AutoPlanningService(
                taskRepository: taskRepository,
                planRevisionRepository: planRevisionRepository,
                operationRepository: operationRepository,
                calendarStore: eventKitService,
                managedCalendarName: "SenseAssist",
                constraints: config.constraints
            )
        default:
            autoPlanningService = nil
        }

        let coordinator = MultiAccountSyncCoordinator(
            accountRepository: accountRepository,
            cursorRepository: cursorRepository,
            updateRepository: updateRepository,
            taskRepository: taskRepository,
            llmRuntime: llmRuntime,
            confidenceThreshold: config.confidenceThreshold,
            gmailClientFactory: { account in
                guard account.provider == .gmail, let token = gmailTokens[account.accountID] else {
                    return nil
                }
                return GoogleGmailAPIClient(accessToken: token)
            },
            outlookClientFactory: { account in
                guard account.provider == .outlook, let token = outlookTokens[account.accountID] else {
                    return nil
                }
                return MicrosoftGraphOutlookClient(accessToken: token)
            },
            autoPlanningService: autoPlanningService
        )

        let result = try await coordinator.syncAllEnabledAccounts()
        let totalUpdates = try updateRepository.count()
        let totalTasks = try taskRepository.count()

        var lines: [String] = ["Live accounts sync summary:"]
        lines.append(
            contentsOf: result.gmail.map {
                "gmail \($0.accountEmail): fetched=\($0.fetchedMessages) stored_updates=\($0.storedUpdates) tasks=\($0.createdOrUpdatedTasks)"
            }
        )
        lines.append(
            contentsOf: result.outlook.map {
                "outlook \($0.accountEmail): fetched=\($0.fetchedMessages) stored_updates=\($0.storedUpdates) tasks=\($0.createdOrUpdatedTasks)"
            }
        )
        lines.append("skipped_accounts=\(skippedAccounts.count)")
        lines.append(contentsOf: skippedAccounts.map { "skipped: \($0)" })
        lines.append(
            "totals: fetched=\(result.totalFetched) updates=\(totalUpdates) tasks=\(totalTasks) enabled_accounts=\(enabledAccounts.count)"
        )

        return LiveSyncExecutionResult(report: lines.joined(separator: "\n"), totalFetched: result.totalFetched)
    }

    private static func configuredLLMRuntime() throws -> LLMRuntimeClient {
        let environment = ProcessInfo.processInfo.environment

        guard let onnxModelPath = environment["SENSEASSIST_ONNX_MODEL_PATH"], !onnxModelPath.isEmpty else {
            throw LiveSyncError.onDeviceLLMNotConfigured
        }

        let runnerPath = environment["SENSEASSIST_ONNX_RUNNER"] ?? "Scripts/onnx_genai_runner.py"
        guard FileManager.default.fileExists(atPath: runnerPath) else {
            throw LiveSyncError.onDeviceLLMRunnerMissing(path: runnerPath)
        }

        let pythonPath = environment["SENSEASSIST_ONNX_PYTHON"] ?? "/usr/bin/python3"
        let maxNewTokens = Int(environment["SENSEASSIST_ONNX_MAX_NEW_TOKENS"] ?? "") ?? 512
        let temperature = Double(environment["SENSEASSIST_ONNX_TEMPERATURE"] ?? "") ?? 0.2
        let topP = Double(environment["SENSEASSIST_ONNX_TOP_P"] ?? "") ?? 0.95
        let provider = environment["SENSEASSIST_ONNX_PROVIDER"]

        return ONNXGenAILLMRuntime(
            modelPath: onnxModelPath,
            runnerScriptPath: runnerPath,
            pythonExecutable: pythonPath,
            maxNewTokens: maxNewTokens,
            temperature: temperature,
            topP: topP,
            provider: provider
        )
    }

    private static func loadCredential(
        store: CredentialStore,
        provider: CredentialProvider,
        accountID: String,
        email: String
    ) throws -> OAuthCredential? {
        if let primary = try store.load(provider: provider, accountID: accountID), !primary.accessToken.isEmpty {
            return primary
        }

        if let emailScoped = try store.load(provider: provider, accountID: email), !emailScoped.accessToken.isEmpty {
            return emailScoped
        }

        return nil
    }
}

private enum LiveSyncError: Error, LocalizedError {
    case noEnabledAccounts
    case noCredentialsConfigured
    case demoModeDisabled
    case onDeviceLLMNotConfigured
    case onDeviceLLMRunnerMissing(path: String)

    var errorDescription: String? {
        switch self {
        case .noEnabledAccounts:
            return "No enabled Gmail/Outlook accounts are configured."
        case .noCredentialsConfigured:
            return "No OAuth tokens found for enabled accounts. Configure tokens in Keychain or environment variables."
        case .demoModeDisabled:
            return "Demo commands are disabled. Set SENSEASSIST_ENABLE_DEMO_COMMANDS=1 or pass --allow-demo."
        case .onDeviceLLMNotConfigured:
            return "On-device LLM is required. Set SENSEASSIST_ONNX_MODEL_PATH to a local ONNX Runtime GenAI model path."
        case let .onDeviceLLMRunnerMissing(path):
            return "ONNX runner script not found at \(path). Set SENSEASSIST_ONNX_RUNNER to a valid local runner script."
        }
    }
}
