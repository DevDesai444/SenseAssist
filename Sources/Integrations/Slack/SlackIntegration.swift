import CoreContracts
import Foundation

public struct SlackCommand: Sendable {
    public var userID: String
    public var channelID: String
    public var text: String

    public init(userID: String, channelID: String, text: String) {
        self.userID = userID
        self.channelID = channelID
        self.text = text
    }
}

public protocol SlackSocketClient: Sendable {
    func connect() async throws
    func disconnect() async
    func sendMessage(_ text: String, channelID: String) async throws
}

public actor StubSlackSocketClient: SlackSocketClient {
    public private(set) var isConnected: Bool = false

    public init() {}

    public func connect() async throws {
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
    }

    public func sendMessage(_ text: String, channelID: String) async throws {
        _ = "[stub] send to \(channelID): \(text)"
    }
}
