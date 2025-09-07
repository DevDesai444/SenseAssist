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
    private static let defaultMultiAccounts: [ConnectedEmailAccount] = [
        ConnectedEmailAccount(
            accountID: "gmail:devdesaiyt@gmail.com",
            provider: .gmail,
            email: "devdesaiyt@gmail.com"
        ),
        ConnectedEmailAccount(
            accountID: "gmail:devdesaiofficial@gmail.com",
            provider: .gmail,
            email: "devdesaiofficial@gmail.com"
        ),
        ConnectedEmailAccount(
            accountID: "gmail:devdesaiyttt@gmail.com",
            provider: .gmail,
            email: "devdesaiyttt@gmail.com"
        ),
        ConnectedEmailAccount(
            accountID: "outlook:devchira@buffalo.edu",
            provider: .outlook,
            email: "devchira@buffalo.edu"
        )
    ]

    static func main() async {
        let logger = ConsoleLogger(minimumLevel: .info)

        do {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.currentDirectoryPath
            let config = SenseAssistConfiguration.default(homeDirectory: home)

            let bootstrap = try StorageBootstrap.run(config: config, logger: logger)
            guard bootstrap.healthy else {
                logger.log(.error, "Storage health check failed", category: "helper")
                Foundation.exit(1)
            }

            if ProcessInfo.processInfo.arguments.contains("--health-check") {
                logger.log(.info, "health=ok db=\(bootstrap.databasePath)", category: "helper")
                Foundation.exit(0)
            }

            if let command = extractPlanCommand(arguments: ProcessInfo.processInfo.arguments) {
                let auditStore = SQLiteStore(databasePath: config.databasePath, logger: logger)
                try auditStore.initialize()
                let auditRepository = AuditLogRepository(store: auditStore)

                let service = PlanCommandService(
                    calendarStore: EventKitService(),
                    auditLogRepository: auditRepository
                )
                let response = await service.handle(commandText: command, now: Date())
                print(response.text)
                Foundation.exit(response.requiresConfirmation ? 2 : 0)
            }

            if ProcessInfo.processInfo.arguments.contains("--gmail-sync-demo") {
                let summary = try await runGmailSyncDemo(config: config, logger: logger)
                print(
                    "Gmail sync summary: account=\(summary.accountEmail) fetched=\(summary.fetchedMessages) parsed=\(summary.parsedUpdates) stored_updates=\(summary.storedUpdates) tasks=\(summary.createdOrUpdatedTasks) next_cursor=\(summary.nextCursor ?? "nil")"
                )
                Foundation.exit(0)
            }

            if ProcessInfo.processInfo.arguments.contains("--outlook-sync-demo") {
                let summary = try await runOutlookSyncDemo(config: config, logger: logger)
                print(
                    "Outlook sync summary: account=\(summary.accountEmail) fetched=\(summary.fetchedMessages) parsed=\(summary.parsedUpdates) stored_updates=\(summary.storedUpdates) tasks=\(summary.createdOrUpdatedTasks) next_cursor=\(summary.nextCursor ?? "nil")"
                )
                Foundation.exit(0)
            }

            if ProcessInfo.processInfo.arguments.contains("--sync-all-demo") {
                let report = try await runMultiAccountSyncDemo(config: config, logger: logger)
                print(report)
                Foundation.exit(0)
            }

            logger.log(.info, "SenseAssist helper initialized", category: "helper")

            // Minimal runtime loop for Milestone 1 scaffolding.
            while true {
                try await Task.sleep(for: .seconds(config.sync.normalPollingMinutes * 60))
                logger.log(.debug, "heartbeat", category: "helper")
            }
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
                (cursor: nil, messages: [sampleMessage], nextCursor: "demo-cursor-v1"),
                (cursor: "demo-cursor-v1", messages: [], nextCursor: "demo-cursor-v1")
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
                (cursor: nil, messages: [sampleMessage], nextCursor: "outlook-cursor-v1"),
                (cursor: "outlook-cursor-v1", messages: [], nextCursor: "outlook-cursor-v1")
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
        for account in defaultMultiAccounts {
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
                        (cursor: nil, messages: [message], nextCursor: "\(account.accountID)-cursor-v1"),
                        (cursor: "\(account.accountID)-cursor-v1", messages: [], nextCursor: "\(account.accountID)-cursor-v1")
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
                        (cursor: nil, messages: [message], nextCursor: "\(account.accountID)-cursor-v1"),
                        (cursor: "\(account.accountID)-cursor-v1", messages: [], nextCursor: "\(account.accountID)-cursor-v1")
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
}
