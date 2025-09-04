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
    private let pages: [(cursor: String?, messages: [GmailMessage], nextCursor: String?)]

    public init(pages: [(cursor: String?, messages: [GmailMessage], nextCursor: String?)] = []) {
        self.pages = pages
    }

    public func fetchMessages(since cursor: String?) async throws -> ([GmailMessage], nextCursor: String?) {
        if let page = pages.first(where: { $0.cursor == cursor }) {
            return (page.messages, page.nextCursor)
        }

        return ([], cursor)
    }
}
