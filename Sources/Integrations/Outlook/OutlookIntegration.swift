import CoreContracts
import Foundation

public struct OutlookSyncCursor: Codable, Equatable, Sendable {
    public var receivedDateTimeISO8601: String
    public var messageID: String?

    public init(receivedDateTimeISO8601: String, messageID: String? = nil) {
        self.receivedDateTimeISO8601 = receivedDateTimeISO8601
        self.messageID = messageID
    }
}

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
    func fetchMessages(since cursor: OutlookSyncCursor?) async throws -> ([OutlookMessage], nextCursor: OutlookSyncCursor?)
}

public enum OutlookClientError: Error, LocalizedError {
    case invalidURL
    case apiError(code: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Outlook Graph URL"
        case let .apiError(code, body):
            return "Outlook Graph API error \(code): \(body)"
        case .invalidResponse:
            return "Invalid Outlook API response"
        }
    }
}

public struct MicrosoftGraphOutlookClient: OutlookClient {
    private let accessToken: String
    private let session: URLSession
    private let top: Int

    public init(accessToken: String, session: URLSession = .shared, top: Int = 50) {
        self.accessToken = accessToken
        self.session = session
        self.top = max(1, min(top, 100))
    }

    public func fetchMessages(since cursor: OutlookSyncCursor?) async throws -> ([OutlookMessage], nextCursor: OutlookSyncCursor?) {
        var nextPageURL: URL? = try initialPageURL(cursor: cursor)
        var fetched: [OutlookMessage] = []
        var seenMessageIDs = Set<String>()

        while let url = nextPageURL {
            let data = try await authorizedGET(url)
            let decoded = try JSONDecoder().decode(OutlookListResponse.self, from: data)

            let pageMessages: [OutlookMessage] = decoded.value.compactMap { item in
                guard let date = ISO8601DateFormatter().date(from: item.receivedDateTime) else {
                    return nil
                }

                let from = item.from.emailAddress.address
                let bodyText = stripHTML(item.body?.content ?? item.bodyPreview)
                let links = extractLinks(from: bodyText)

                return OutlookMessage(
                    messageID: item.id,
                    conversationID: item.conversationId,
                    receivedDateTime: date,
                    from: from,
                    subject: item.subject,
                    bodyText: bodyText,
                    links: links
                )
            }

            for message in pageMessages {
                guard seenMessageIDs.insert(message.messageID).inserted else {
                    continue
                }

                if isAfterCursor(message, cursor: cursor) {
                    fetched.append(message)
                }
            }

            nextPageURL = decoded.nextLink.flatMap(URL.init(string:))
        }

        fetched.sort(by: messageTupleCompare)

        var nextCursor = cursor
        for message in fetched {
            nextCursor = maxCursor(nextCursor, message: message)
        }

        return (fetched, nextCursor)
    }

    private func authorizedGET(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OutlookClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw OutlookClientError.apiError(code: http.statusCode, body: body)
        }

        return data
    }

    private func initialPageURL(cursor: OutlookSyncCursor?) throws -> URL {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "$top", value: "\(top)"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime asc,id asc"),
            URLQueryItem(name: "$select", value: "id,conversationId,receivedDateTime,subject,bodyPreview,body,from")
        ]

        if let cursor,
           let cursorDate = ISO8601DateFormatter().date(from: cursor.receivedDateTimeISO8601) {
            let filterISO = ISO8601DateFormatter().string(from: cursorDate)
            // Inclusive lower bound + local tuple filtering avoids missing same-timestamp messages.
            queryItems.append(URLQueryItem(name: "$filter", value: "receivedDateTime ge \(filterISO)"))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OutlookClientError.invalidURL
        }
        return url
    }

    private func isAfterCursor(_ message: OutlookMessage, cursor: OutlookSyncCursor?) -> Bool {
        guard let cursor,
              let cursorDate = ISO8601DateFormatter().date(from: cursor.receivedDateTimeISO8601)
        else {
            return true
        }

        if message.receivedDateTime > cursorDate {
            return true
        }

        if message.receivedDateTime < cursorDate {
            return false
        }

        return message.messageID > (cursor.messageID ?? "")
    }

    private func messageTupleCompare(lhs: OutlookMessage, rhs: OutlookMessage) -> Bool {
        if lhs.receivedDateTime != rhs.receivedDateTime {
            return lhs.receivedDateTime < rhs.receivedDateTime
        }

        return lhs.messageID < rhs.messageID
    }

    private func maxCursor(_ current: OutlookSyncCursor?, message: OutlookMessage) -> OutlookSyncCursor {
        let candidate = OutlookSyncCursor(
            receivedDateTimeISO8601: ISO8601DateFormatter().string(from: message.receivedDateTime),
            messageID: message.messageID
        )

        guard let current else {
            return candidate
        }

        guard let currentDate = ISO8601DateFormatter().date(from: current.receivedDateTimeISO8601),
              let candidateDate = ISO8601DateFormatter().date(from: candidate.receivedDateTimeISO8601)
        else {
            return candidate
        }

        if candidateDate > currentDate {
            return candidate
        }

        if candidateDate < currentDate {
            return current
        }

        if (candidate.messageID ?? "") > (current.messageID ?? "") {
            return candidate
        }

        return current
    }

    private func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let withoutEntities = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return withoutEntities.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractLinks(from text: String) -> [String] {
        let pattern = #"https?://[^\s\"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap {
            guard let swiftRange = Range($0.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}

public struct StubOutlookClient: OutlookClient {
    private let pages: [(cursor: OutlookSyncCursor?, messages: [OutlookMessage], nextCursor: OutlookSyncCursor?)]

    public init(pages: [(cursor: OutlookSyncCursor?, messages: [OutlookMessage], nextCursor: OutlookSyncCursor?)] = []) {
        self.pages = pages
    }

    public func fetchMessages(since cursor: OutlookSyncCursor?) async throws -> ([OutlookMessage], nextCursor: OutlookSyncCursor?) {
        if let page = pages.first(where: { $0.cursor == cursor }) {
            return (page.messages, page.nextCursor)
        }

        return ([], cursor)
    }
}

private struct OutlookListResponse: Decodable {
    struct Item: Decodable {
        struct Sender: Decodable {
            struct EmailAddress: Decodable {
                let address: String
            }
            let emailAddress: EmailAddress
        }

        struct Body: Decodable {
            let contentType: String?
            let content: String
        }

        let id: String
        let conversationId: String?
        let receivedDateTime: String
        let subject: String
        let bodyPreview: String
        let body: Body?
        let from: Sender
    }

    let value: [Item]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}
