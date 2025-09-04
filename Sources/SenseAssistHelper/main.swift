import CoreContracts
import EventKitAdapter
import Foundation
import LLMRuntime
import Orchestration
import ParserPipeline
import Planner
import RulesEngine
import SlackIntegration
import Storage

@main
struct SenseAssistHelperMain {
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
                let service = PlanCommandService(calendarStore: EventKitService())
                let response = await service.handle(commandText: command, now: Date())
                print(response.text)
                Foundation.exit(response.requiresConfirmation ? 2 : 0)
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
}
