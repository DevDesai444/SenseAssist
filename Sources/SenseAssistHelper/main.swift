import CoreContracts
import Foundation
import LLMRuntime
import ParserPipeline
import Planner
import RulesEngine
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

            logger.log(.info, "SenseAssist helper initialized", category: "helper")

            // Minimal runtime loop for Milestone 0.
            while true {
                try await Task.sleep(for: .seconds(config.sync.normalPollingMinutes * 60))
                logger.log(.debug, "heartbeat", category: "helper")
            }
        } catch {
            fputs("Helper failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
