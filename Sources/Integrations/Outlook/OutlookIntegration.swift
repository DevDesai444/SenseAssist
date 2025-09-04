import CoreContracts
import Foundation

public struct OutlookMessage: Sendable {
    public var messageID: String
    public var conversationID: String?
    public var receivedDateTime: Date
    public var from: String
    public var subject: String
    public var bodyText: String
    public var links: [String]

    public init(
        messageID: String,
        conversationID: String? = nil,
        receivedDateTime: Date,
        from: String,
        subject: String,
        bodyText: String,
        links: [String] = []
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.receivedDateTime = receivedDateTime
        self.from = from
        self.subject = subject
        self.bodyText = bodyText
        self.links = links
    }
}

public protocol OutlookClient: Sendable {
    func fetchMessages(since cursor: String?) async throws -> ([OutlookMessage], nextCursor: String?)
}

public struct StubOutlookClient: OutlookClient {
    public init() {}

    public func fetchMessages(since cursor: String?) async throws -> ([OutlookMessage], nextCursor: String?) {
        _ = cursor
        return ([], cursor)
    }
}
