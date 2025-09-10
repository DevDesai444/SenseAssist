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

public enum SlackClientError: Error, LocalizedError {
    case invalidResponse
    case apiError(code: Int, body: String)
    case socketURLUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Slack API"
        case let .apiError(code, body):
            return "Slack API error \(code): \(body)"
        case .socketURLUnavailable:
            return "Slack Socket Mode URL unavailable"
        }
    }
}

public actor SlackWebAPIClient: SlackSocketClient {
    private let botToken: String
    private let appLevelToken: String?
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?

    public init(botToken: String, appLevelToken: String? = nil, session: URLSession = .shared) {
        self.botToken = botToken
        self.appLevelToken = appLevelToken
        self.session = session
    }

    public func connect() async throws {
        guard let appLevelToken else {
            return
        }

        var request = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appLevelToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SlackClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SlackClientError.apiError(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let socketResponse = try JSONDecoder().decode(SocketOpenResponse.self, from: data)
        guard socketResponse.ok, let urlString = socketResponse.url, let url = URL(string: urlString) else {
            throw SlackClientError.socketURLUnavailable
        }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socketTask = socket
        receiveLoop()
    }

    public func disconnect() async {
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    public func sendMessage(_ text: String, channelID: String) async throws {
        let url = URL(string: "https://slack.com/api/chat.postMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(PostMessageRequest(channel: channelID, text: text))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SlackClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SlackClientError.apiError(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let apiResponse = try JSONDecoder().decode(ChatPostMessageResponse.self, from: data)
        if !apiResponse.ok {
            throw SlackClientError.apiError(code: http.statusCode, body: apiResponse.error ?? "unknown_error")
        }
    }

    private func receiveLoop() {
        guard let socketTask else { return }

        socketTask.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleSocketMessage(result) }
            Task { await self.receiveLoop() }
        }
    }

    private func handleSocketMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        guard case let .success(message) = result else { return }
        let payloadData: Data?
        switch message {
        case let .string(text):
            payloadData = text.data(using: .utf8)
        case let .data(data):
            payloadData = data
        @unknown default:
            payloadData = nil
        }

        guard let payloadData,
              let envelope = try? JSONDecoder().decode(SocketEnvelope.self, from: payloadData),
              let envelopeID = envelope.envelopeID else {
            return
        }

        do {
            try await sendSocketAck(envelopeID: envelopeID)
        } catch {
            // Ignore ack failures; reconnect strategy handled externally.
        }
    }

    private func sendSocketAck(envelopeID: String) async throws {
        guard let socketTask else { return }
        let ack = SocketAck(envelopeID: envelopeID)
        let data = try JSONEncoder().encode(ack)
        let text = String(data: data, encoding: .utf8) ?? "{\"envelope_id\":\"\(envelopeID)\"}"
        try await socketTask.send(.string(text))
    }
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

private struct PostMessageRequest: Encodable {
    let channel: String
    let text: String
}

private struct ChatPostMessageResponse: Decodable {
    let ok: Bool
    let error: String?
}

private struct SocketOpenResponse: Decodable {
    let ok: Bool
    let url: String?
}

private struct SocketEnvelope: Decodable {
    let envelopeID: String?

    enum CodingKeys: String, CodingKey {
        case envelopeID = "envelope_id"
    }
}

private struct SocketAck: Encodable {
    let envelopeID: String

    enum CodingKeys: String, CodingKey {
        case envelopeID = "envelope_id"
    }
}

public enum PlanCommand: Sendable, Equatable {
    case today
    case add(title: String, start: Date, durationMinutes: Int)
    case move(title: String, start: Date, durationMinutes: Int?)
    case undo
    case help
}

public enum PlanCommandParseError: Error, LocalizedError {
    case missingCommand
    case invalidAddSyntax
    case invalidMoveSyntax
    case invalidDuration
    case invalidDateTime

    public var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "No plan command provided"
        case .invalidAddSyntax:
            return "Invalid add command. Use: add \"Title\" 60m [today|tomorrow] [7:00pm]"
        case .invalidMoveSyntax:
            return "Invalid move command. Use: move \"Title\" [today|tomorrow] 7:00pm [60m]"
        case .invalidDuration:
            return "Duration must be provided in minutes, such as 45m"
        case .invalidDateTime:
            return "Could not parse date/time"
        }
    }
}

public enum PlanCommandParser {
    public static func parse(_ rawText: String, now: Date, calendar: Calendar = .current) throws -> PlanCommand {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlanCommandParseError.missingCommand
        }

        let lower = trimmed.lowercased()
        if lower == "today" {
            return .today
        }

        if lower == "help" {
            return .help
        }

        if lower == "undo" {
            return .undo
        }

        if lower.hasPrefix("add ") {
            return try parseAdd(trimmed, now: now, calendar: calendar)
        }

        if lower.hasPrefix("move ") {
            return try parseMove(trimmed, now: now, calendar: calendar)
        }

        throw PlanCommandParseError.missingCommand
    }

    private static func parseAdd(_ text: String, now: Date, calendar: Calendar) throws -> PlanCommand {
        let pattern = #"^add\s+"([^"]+)"\s+(\d+)m(?:\s+(today|tomorrow))?(?:\s+([0-9]{1,2}(?::[0-9]{2})?(?:am|pm)?))?$"#
        let match = try firstMatch(pattern: pattern, in: text)

        guard let match else {
            throw PlanCommandParseError.invalidAddSyntax
        }

        let title = capture(match: match, in: text, group: 1)
        let durationRaw = capture(match: match, in: text, group: 2)
        let dayToken = capture(match: match, in: text, group: 3)
        let timeToken = capture(match: match, in: text, group: 4)

        guard let title, let durationRaw, let durationMinutes = Int(durationRaw), durationMinutes > 0 else {
            throw PlanCommandParseError.invalidDuration
        }

        let start = try resolveDate(dayToken: dayToken, timeToken: timeToken, now: now, calendar: calendar)
        return .add(title: title, start: start, durationMinutes: durationMinutes)
    }

    private static func parseMove(_ text: String, now: Date, calendar: Calendar) throws -> PlanCommand {
        let pattern = #"^move\s+"([^"]+)"\s+(today|tomorrow)\s+([0-9]{1,2}(?::[0-9]{2})?(?:am|pm)?)(?:\s+(\d+)m)?$"#
        let match = try firstMatch(pattern: pattern, in: text)

        guard let match else {
            throw PlanCommandParseError.invalidMoveSyntax
        }

        let title = capture(match: match, in: text, group: 1)
        let dayToken = capture(match: match, in: text, group: 2)
        let timeToken = capture(match: match, in: text, group: 3)
        let durationRaw = capture(match: match, in: text, group: 4)

        guard let title, let dayToken, let timeToken else {
            throw PlanCommandParseError.invalidMoveSyntax
        }

        let start = try resolveDate(dayToken: dayToken, timeToken: timeToken, now: now, calendar: calendar)
        let duration = durationRaw.flatMap(Int.init)

        return .move(title: title, start: start, durationMinutes: duration)
    }

    private static func resolveDate(
        dayToken: String?,
        timeToken: String?,
        now: Date,
        calendar: Calendar
    ) throws -> Date {
        var baseDate = calendar.startOfDay(for: now)

        if let dayToken {
            let normalized = dayToken.lowercased()
            if normalized == "tomorrow" {
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: baseDate) else {
                    throw PlanCommandParseError.invalidDateTime
                }
                baseDate = tomorrow
            }
        }

        guard let timeToken else {
            guard let defaultStart = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: baseDate) else {
                throw PlanCommandParseError.invalidDateTime
            }
            return defaultStart
        }

        let normalized = normalizeTimeToken(timeToken)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone

        for format in ["h:mma", "ha", "H:mm", "H"] {
            formatter.dateFormat = format
            if let parsedTime = formatter.date(from: normalized) {
                let components = calendar.dateComponents([.hour, .minute], from: parsedTime)
                guard let hour = components.hour,
                      let minute = components.minute,
                      let resolved = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
                else {
                    throw PlanCommandParseError.invalidDateTime
                }

                return resolved
            }
        }

        throw PlanCommandParseError.invalidDateTime
    }

    private static func normalizeTimeToken(_ raw: String) -> String {
        var token = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if token.hasSuffix("am") || token.hasSuffix("pm") {
            token = token.replacingOccurrences(of: "am", with: "AM")
            token = token.replacingOccurrences(of: "pm", with: "PM")
        }
        return token
    }

    private static func firstMatch(pattern: String, in text: String) throws -> NSTextCheckingResult? {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private static func capture(match: NSTextCheckingResult, in text: String, group: Int) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
