import CoreContracts
import Foundation

public struct GmailSyncCursor: Codable, Equatable, Sendable {
    public var internalDateSeconds: Int
    public var messageID: String?

    public init(internalDateSeconds: Int, messageID: String? = nil) {
        self.internalDateSeconds = internalDateSeconds
        self.messageID = messageID
    }
}

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
    func fetchMessages(since cursor: GmailSyncCursor?) async throws -> ([GmailMessage], nextCursor: GmailSyncCursor?)
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

    public func fetchMessages(since cursor: GmailSyncCursor?) async throws -> ([GmailMessage], nextCursor: GmailSyncCursor?) {
        var pageToken: String?
        var fetched: [GmailMessage] = []
        var seenMessageIDs = Set<String>()

        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "maxResults", value: "\(maxResults)")
            ]

            if let cursor {
                // Use a 1-second overlap to avoid dropping same-second arrivals.
                let safeAfter = max(0, cursor.internalDateSeconds - 1)
                queryItems.append(URLQueryItem(name: "q", value: "after:\(safeAfter)"))
            }

            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            components?.queryItems = queryItems
            guard let listURL = components?.url else {
                throw GmailClientError.invalidURL
            }

            let listData = try await authorizedGET(listURL)
            let listResponse = try JSONDecoder().decode(GmailListResponse.self, from: listData)

            let ids = listResponse.messages ?? []
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

                guard seenMessageIDs.insert(gmailMessage.messageID).inserted else {
                    continue
                }

                if isAfterCursor(gmailMessage, cursor: cursor) {
                    fetched.append(gmailMessage)
                }
            }

            pageToken = listResponse.nextPageToken
        } while pageToken != nil

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
            throw GmailClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw GmailClientError.apiError(code: http.statusCode, body: body)
        }

        return data
    }

    private func isAfterCursor(_ message: GmailMessage, cursor: GmailSyncCursor?) -> Bool {
        guard let cursor else {
            return true
        }

        let seconds = Int(message.internalDate.timeIntervalSince1970)
        if seconds > cursor.internalDateSeconds {
            return true
        }

        if seconds < cursor.internalDateSeconds {
            return false
        }

        let cursorMessageID = cursor.messageID ?? ""
        return message.messageID > cursorMessageID
    }

    private func messageTupleCompare(lhs: GmailMessage, rhs: GmailMessage) -> Bool {
        let lSeconds = Int(lhs.internalDate.timeIntervalSince1970)
        let rSeconds = Int(rhs.internalDate.timeIntervalSince1970)

        if lSeconds != rSeconds {
            return lSeconds < rSeconds
        }

        return lhs.messageID < rhs.messageID
    }

    private func maxCursor(_ current: GmailSyncCursor?, message: GmailMessage) -> GmailSyncCursor {
        let seconds = Int(message.internalDate.timeIntervalSince1970)
        let candidate = GmailSyncCursor(internalDateSeconds: seconds, messageID: message.messageID)
        guard let current else {
            return candidate
        }

        if candidate.internalDateSeconds > current.internalDateSeconds {
            return candidate
        }

        if candidate.internalDateSeconds < current.internalDateSeconds {
            return current
        }

        if (candidate.messageID ?? "") > (current.messageID ?? "") {
            return candidate
        }

        return current
    }
}

public struct StubGmailClient: GmailClient {
    private let pages: [(cursor: GmailSyncCursor?, messages: [GmailMessage], nextCursor: GmailSyncCursor?)]

    public init(pages: [(cursor: GmailSyncCursor?, messages: [GmailMessage], nextCursor: GmailSyncCursor?)] = []) {
        self.pages = pages
    }

    public func fetchMessages(since cursor: GmailSyncCursor?) async throws -> ([GmailMessage], nextCursor: GmailSyncCursor?) {
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
    let nextPageToken: String?
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
