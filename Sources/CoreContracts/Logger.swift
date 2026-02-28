import Foundation

public protocol Logging: Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, category: String)
}

public struct ConsoleLogger: Logging {
    public let minimumLevel: LogLevel

    public init(minimumLevel: LogLevel) {
        self.minimumLevel = minimumLevel
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, category: String = "app") {
        guard level >= minimumLevel else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)] [\(level.rawValue.uppercased())] [\(category)] \(message())")
    }
}
