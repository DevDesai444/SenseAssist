import CoreContracts
import Foundation

public struct StorageBootstrapResult: Sendable {
    public let databasePath: String
    public let healthy: Bool

    public init(databasePath: String, healthy: Bool) {
        self.databasePath = databasePath
        self.healthy = healthy
    }
}

public enum StorageBootstrap {
    public static func run(config: SenseAssistConfiguration, logger: Logging) throws -> StorageBootstrapResult {
        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()
        let healthy = try store.healthCheck()
        store.close()

        return StorageBootstrapResult(databasePath: config.databasePath, healthy: healthy)
    }
}
