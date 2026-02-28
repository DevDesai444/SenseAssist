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
    private let pages: [(cursor: String?, messages: [OutlookMessage], nextCursor: String?)]

    public init(pages: [(cursor: String?, messages: [OutlookMessage], nextCursor: String?)] = []) {
        self.pages = pages
    }

    public func fetchMessages(since cursor: String?) async throws -> ([OutlookMessage], nextCursor: String?) {
        if let page = pages.first(where: { $0.cursor == cursor }) {
            return (page.messages, page.nextCursor)
        }

        return ([], cursor)
    }
}
