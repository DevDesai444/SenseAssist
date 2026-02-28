import CoreContracts
import Foundation

public struct GmailMessage: Sendable {
    public var messageID: String
    public var threadID: String?
    public var internalDate: Date
    public var from: String
    public var subject: String
    public var bodyText: String
    public var links: [String]

    public init(
        messageID: String,
        threadID: String? = nil,
        internalDate: Date,
        from: String,
        subject: String,
        bodyText: String,
        links: [String] = []
    ) {
        self.messageID = messageID
        self.threadID = threadID
        self.internalDate = internalDate
        self.from = from
        self.subject = subject
        self.bodyText = bodyText
        self.links = links
    }
}

public protocol GmailClient: Sendable {
    func fetchMessages(since cursor: String?) async throws -> ([GmailMessage], nextCursor: String?)
}

public struct StubGmailClient: GmailClient {
    public init() {}

    public func fetchMessages(since cursor: String?) async throws -> ([GmailMessage], nextCursor: String?) {
        _ = cursor
        return ([], cursor)
    }
}
