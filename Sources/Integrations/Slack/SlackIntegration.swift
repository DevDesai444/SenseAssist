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
