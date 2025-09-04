import CoreContracts
import Foundation

public struct InboundMessage: Sendable {
    public var source: UpdateSource
    public var messageID: String
    public var threadID: String?
    public var receivedAtUTC: Date
    public var from: String
    public var subject: String
    public var bodyText: String
    public var links: [String]

    public init(
        source: UpdateSource,
        messageID: String,
        threadID: String? = nil,
        receivedAtUTC: Date,
        from: String,
        subject: String,
        bodyText: String,
        links: [String] = []
    ) {
        self.source = source
        self.messageID = messageID
        self.threadID = threadID
        self.receivedAtUTC = receivedAtUTC
        self.from = from
        self.subject = subject
        self.bodyText = bodyText
        self.links = links
    }
}

public struct ParsedUpdate: Sendable {
    public var card: UpdateCard
    public var extractedDueDateText: String?
    public var templateType: String

    public init(card: UpdateCard, extractedDueDateText: String? = nil, templateType: String = "generic") {
        self.card = card
        self.extractedDueDateText = extractedDueDateText
        self.templateType = templateType
    }
}

public struct ParsingConfiguration: Sendable {
    public var trustedSenderPatterns: [String]

    public init(trustedSenderPatterns: [String] = ["@buffalo.edu", "@piazza.com", "instructure", "ublearns"]) {
        self.trustedSenderPatterns = trustedSenderPatterns
    }
}

public enum ParserPipeline {
    public static func parse(message: InboundMessage, config: ParsingConfiguration = ParsingConfiguration()) -> [ParsedUpdate] {
        guard isTrustedSender(message.from, patterns: config.trustedSenderPatterns) else {
            return [
                ParsedUpdate(
                    card: UpdateCard(
                        source: message.source,
                        providerIDs: ProviderIDs(messageID: message.messageID, threadID: message.threadID),
                        receivedAtUTC: message.receivedAtUTC,
                        from: message.from,
                        subject: message.subject,
                        bodyText: message.bodyText,
                        links: message.links,
                        tags: ["type:untrusted_source"],
                        parserMethod: .ruleBased,
                        parseConfidence: 0.20,
                        evidence: ["sender_untrusted"],
                        requiresConfirmation: true
                    )
                )
            ]
        }

        let digestItems = splitDigest(subject: message.subject, body: message.bodyText)
        if digestItems.count > 1 {
            return digestItems.enumerated().map { index, item in
                parseSingle(
                    message: message,
                    overrideBody: item,
                    syntheticSuffix: "-\(index + 1)"
                )
            }
        }

        return [parseSingle(message: message, overrideBody: nil, syntheticSuffix: nil)]
    }

    private static func parseSingle(message: InboundMessage, overrideBody: String?, syntheticSuffix: String?) -> ParsedUpdate {
        let body = overrideBody ?? message.bodyText
        let template = classifyTemplate(source: message.source, sender: message.from, subject: message.subject, body: body)
        var tags = classifyTags(subject: message.subject, body: body)
        tags.append("template:\(template)")
        let dueDateText = extractDueDateText(from: message.subject + "\n" + body)
        let requiresConfirmation = dueDateText == nil && (
            tags.contains("type:assignment") || template.contains("digest") || template == "unknown"
        )

        let confidence = confidenceScore(
            hasDueDate: dueDateText != nil,
            hasCourseTag: tags.contains(where: { $0.hasPrefix("course:") }),
            hasKnownTemplate: template != "unknown",
            requiresConfirmation: requiresConfirmation
        )

        let card = UpdateCard(
            source: message.source,
            providerIDs: ProviderIDs(
                messageID: message.messageID + (syntheticSuffix ?? ""),
                threadID: message.threadID
            ),
            receivedAtUTC: message.receivedAtUTC,
            from: message.from,
            subject: message.subject,
            bodyText: body,
            links: message.links,
            tags: tags,
            parserMethod: .ruleBased,
            parseConfidence: confidence,
            evidence: dueDateText.map { ["due_date:\($0)"] } ?? [],
            requiresConfirmation: requiresConfirmation
        )

        return ParsedUpdate(card: card, extractedDueDateText: dueDateText, templateType: template)
    }

    private static func isTrustedSender(_ sender: String, patterns: [String]) -> Bool {
        let normalized = sender.lowercased()
        return patterns.contains { normalized.contains($0.lowercased()) }
    }

    private static func splitDigest(subject: String, body: String) -> [String] {
        let lower = subject.lowercased()
        guard lower.contains("digest") || lower.contains("summary") else {
            return [body]
        }

        let lines = body.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let bullets = lines.filter {
            $0.hasPrefix("-") || $0.hasPrefix("*") || $0.hasPrefix("•") || $0.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
        }
        return bullets.isEmpty ? [body] : bullets
    }

    private static func classifyTags(subject: String, body: String) -> [String] {
        let text = (subject + "\n" + body).lowercased()
        var tags: [String] = []

        if let course = extractCourseCode(from: text) {
            tags.append("course:\(course)")
        }

        if text.contains("assignment") || text.contains("homework") {
            tags.append("type:assignment")
        } else if text.contains("quiz") || text.contains("exam") {
            tags.append("type:quiz")
        } else if text.contains("reply") || text.contains("rsvp") || text.contains("confirm by") {
            tags.append("type:response_required")
        } else {
            tags.append("type:announcement")
        }

        return tags
    }

    private static func extractCourseCode(from text: String) -> String? {
        let pattern = #"\b([a-z]{3}\s?\d{3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let codeRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[codeRange]).replacingOccurrences(of: " ", with: "").uppercased()
    }

    private static func extractDueDateText(from text: String) -> String? {
        let pattern = #"((due|by)\s+(on\s+)?[a-z]{3,9}\s+\d{1,2}(,\s*\d{4})?(\s+at\s+\d{1,2}:?\d{0,2}\s*(am|pm)?)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let dueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[dueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func classifyTemplate(source: UpdateSource, sender: String, subject: String, body: String) -> String {
        let normalizedSender = sender.lowercased()
        let normalizedSubject = subject.lowercased()
        let normalizedBody = body.lowercased()

        if source == .piazzaEmail || normalizedSender.contains("piazza") {
            if normalizedSubject.contains("digest") || normalizedSubject.contains("summary") {
                return "piazza_digest"
            }
            if normalizedSubject.contains("new post") || normalizedBody.contains("instructor note") {
                return "piazza_realtime"
            }
            return "piazza_generic"
        }

        if source == .ublearnsEmail || normalizedSender.contains("buffalo.edu") || normalizedSender.contains("instructure") || normalizedSender.contains("ublearns") {
            if normalizedSubject.contains("assignment") {
                return "ublearns_assignment"
            }
            if normalizedSubject.contains("quiz") || normalizedSubject.contains("exam") {
                return "ublearns_quiz"
            }
            if normalizedSubject.contains("announcement") {
                return "ublearns_announcement"
            }
            return "ublearns_generic"
        }

        return "unknown"
    }

    private static func confidenceScore(hasDueDate: Bool, hasCourseTag: Bool, hasKnownTemplate: Bool, requiresConfirmation: Bool) -> Double {
        var score = 0.50
        if hasDueDate { score += 0.25 }
        if hasCourseTag { score += 0.20 }
        if hasKnownTemplate { score += 0.10 }
        if requiresConfirmation { score -= 0.25 }
        return max(0.0, min(score, 0.99))
    }
}
