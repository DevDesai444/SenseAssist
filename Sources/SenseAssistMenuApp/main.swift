import CoreContracts
import Foundation
import Storage

@main
struct SenseAssistMenuMain {
    static func main() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.currentDirectoryPath
        let config = SenseAssistConfiguration.default(homeDirectory: home)
        print("SenseAssist menu app placeholder")
        print("Database: \(config.databasePath)")
    }
}
