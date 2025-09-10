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

    public func fetchMessages(since cursor: String?) async throws -> ([OutlookMessage], nextCursor: String?) {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "$top", value: "\(top)"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
            URLQueryItem(name: "$select", value: "id,conversationId,receivedDateTime,subject,bodyPreview,body,from")
        ]

        if let cursor,
           let cursorDate = ISO8601DateFormatter().date(from: cursor) {
            let filterISO = ISO8601DateFormatter().string(from: cursorDate)
            queryItems.append(URLQueryItem(name: "$filter", value: "receivedDateTime gt \(filterISO)"))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw OutlookClientError.invalidURL
        }

        let data = try await authorizedGET(url)
        let decoded = try JSONDecoder().decode(OutlookListResponse.self, from: data)

        let messages: [OutlookMessage] = decoded.value.compactMap { item in
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

        let latest = messages.map(\.receivedDateTime).max()
        let nextCursor = latest.map { ISO8601DateFormatter().string(from: $0) } ?? cursor

        return (messages, nextCursor)
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
}
