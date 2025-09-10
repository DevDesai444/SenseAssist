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

public enum GmailClientError: Error, LocalizedError {
    case invalidURL
    case apiError(code: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Gmail API URL"
        case let .apiError(code, body):
            return "Gmail API error \(code): \(body)"
        case .invalidResponse:
            return "Invalid Gmail API response"
        }
    }
}

public struct GoogleGmailAPIClient: GmailClient {
    private let accessToken: String
    private let session: URLSession
    private let maxResults: Int

    public init(accessToken: String, session: URLSession = .shared, maxResults: Int = 50) {
        self.accessToken = accessToken
        self.session = session
        self.maxResults = max(1, min(maxResults, 500))
    }

    public func fetchMessages(since cursor: String?) async throws -> ([GmailMessage], nextCursor: String?) {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: "\(maxResults)")
        ]

        if let cursor,
           let sinceSeconds = Int(cursor), sinceSeconds > 0 {
            queryItems.append(URLQueryItem(name: "q", value: "after:\(sinceSeconds)"))
        }

        components?.queryItems = queryItems
        guard let listURL = components?.url else {
            throw GmailClientError.invalidURL
        }

        let listData = try await authorizedGET(listURL)
        let listResponse = try JSONDecoder().decode(GmailListResponse.self, from: listData)

        let ids = listResponse.messages ?? []
        var messages: [GmailMessage] = []
        var maxInternalDateSeconds = Int(cursor ?? "0") ?? 0

        for id in ids {
            let detailURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id.id)?format=full")
            guard let detailURL else {
                throw GmailClientError.invalidURL
            }

            let detailData = try await authorizedGET(detailURL)
            let detail = try JSONDecoder().decode(GmailMessageResponse.self, from: detailData)
            guard let gmailMessage = detail.toDomainMessage() else {
                continue
            }

            messages.append(gmailMessage)
            let seconds = Int(gmailMessage.internalDate.timeIntervalSince1970)
            maxInternalDateSeconds = max(maxInternalDateSeconds, seconds)
        }

        let nextCursor = maxInternalDateSeconds > 0 ? String(maxInternalDateSeconds) : cursor
        return (messages, nextCursor)
    }

    private func authorizedGET(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw GmailClientError.apiError(code: http.statusCode, body: body)
        }

        return data
    }
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

private struct GmailListResponse: Decodable {
    struct MessageRef: Decodable {
        let id: String
    }

    let messages: [MessageRef]?
}

private struct GmailMessageResponse: Decodable {
    struct Header: Decodable {
        let name: String
        let value: String
    }

    struct Body: Decodable {
        let data: String?
    }

    struct Payload: Decodable {
        let headers: [Header]?
        let body: Body?
        let parts: [Payload]?
        let mimeType: String?
    }

    let id: String
    let threadId: String?
    let internalDate: String?
    let payload: Payload?

    func toDomainMessage() -> GmailMessage? {
        let dateMillis = Int(internalDate ?? "") ?? Int(Date().timeIntervalSince1970 * 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(dateMillis) / 1000.0)

        let headers = payload?.headers ?? []
        let from = headers.first(where: { $0.name.caseInsensitiveCompare("From") == .orderedSame })?.value ?? ""
        let subject = headers.first(where: { $0.name.caseInsensitiveCompare("Subject") == .orderedSame })?.value ?? ""

        let bodyText = extractText(from: payload)
        let links = extractLinks(from: bodyText)

        return GmailMessage(
            messageID: id,
            threadID: threadId,
            internalDate: date,
            from: from,
            subject: subject,
            bodyText: bodyText,
            links: links
        )
    }

    private func extractText(from payload: Payload?) -> String {
        guard let payload else { return "" }

        if let parts = payload.parts, !parts.isEmpty {
            for part in parts {
                if part.mimeType == "text/plain", let data = part.body?.data, let decoded = decodeBase64URL(data) {
                    return decoded
                }
            }
            for part in parts {
                let nested = extractText(from: part)
                if !nested.isEmpty {
                    return nested
                }
            }
        }

        if let data = payload.body?.data, let decoded = decodeBase64URL(data) {
            return decoded
        }

        return ""
    }

    private func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
