import CoreContracts
import Foundation

public enum StorageProvider: String, Sendable {
    case gmail
    case outlook
}

public struct ProviderCursorRecord: Sendable {
    public var provider: StorageProvider
    public var primary: String
    public var secondary: String?

    public init(provider: StorageProvider, primary: String, secondary: String? = nil) {
        self.provider = provider
        self.primary = primary
        self.secondary = secondary
    }
}

public final class ProviderCursorRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func get(provider: StorageProvider) throws -> ProviderCursorRecord? {
        let sql = """
        SELECT provider, cursor_primary, cursor_secondary
        FROM provider_cursors
        WHERE provider = '\(escape(provider.rawValue))'
        LIMIT 1;
        """

        guard let row = try store.fetchRows(sql).first,
              let providerName = row["provider"],
              let primary = row["cursor_primary"],
              let parsedProvider = StorageProvider(rawValue: providerName)
        else {
            return nil
        }

        return ProviderCursorRecord(provider: parsedProvider, primary: primary, secondary: row["cursor_secondary"])
    }

    public func upsert(_ record: ProviderCursorRecord) throws {
        let secondarySQL = record.secondary.map { "'\(escape($0))'" } ?? "NULL"

        let sql = """
        INSERT INTO provider_cursors (provider, cursor_primary, cursor_secondary, updated_at_utc)
        VALUES ('\(escape(record.provider.rawValue))', '\(escape(record.primary))', \(secondarySQL), '\(timestamp())')
        ON CONFLICT(provider) DO UPDATE SET
          cursor_primary = excluded.cursor_primary,
          cursor_secondary = excluded.cursor_secondary,
          updated_at_utc = excluded.updated_at_utc;
        """

        try store.execute(sql)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public final class UpdateRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    @discardableResult
    public func upsert(_ updates: [UpdateCard]) throws -> Int {
        var inserted = 0
        for update in updates {
            let linksJSON = jsonArray(update.links)
            let tagsJSON = jsonArray(update.tags)
            let received = ISO8601DateFormatter().string(from: update.receivedAtUTC)
            let created = ISO8601DateFormatter().string(from: Date())
            let contentHash = "\(abs(update.bodyText.hashValue))"
            let requiresConfirmation = update.requiresConfirmation ? 1 : 0

            let sql = """
            INSERT OR IGNORE INTO updates (
              update_id, source, message_id, thread_id,
              received_at_utc, sender, subject, body_text,
              links_json, tags_json, parser_method, parse_confidence,
              content_hash, requires_confirmation, created_at_utc
            ) VALUES (
              '\(escape(update.updateID.uuidString))',
              '\(escape(update.source.rawValue))',
              '\(escape(update.providerIDs.messageID))',
              \(nullable(update.providerIDs.threadID)),
              '\(escape(received))',
              '\(escape(update.from))',
              '\(escape(update.subject))',
              '\(escape(update.bodyText))',
              '\(escape(linksJSON))',
              '\(escape(tagsJSON))',
              '\(escape(update.parserMethod.rawValue))',
              \(update.parseConfidence),
              '\(contentHash)',
              \(requiresConfirmation),
              '\(escape(created))'
            );
            """

            try store.execute(sql)
            let changes = try store.fetchRows("SELECT changes() AS n;").first?["n"].flatMap(Int.init) ?? 0
            inserted += changes
        }
        return inserted
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func nullable(_ value: String?) -> String {
        value.map { "'\(escape($0))'" } ?? "NULL"
    }

    private func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

public final class TaskRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    @discardableResult
    public func upsert(_ tasks: [TaskItem]) throws -> Int {
        var count = 0
        for task in tasks {
            let due = task.dueAtLocal.map { "'\(escape(ISO8601DateFormatter().string(from: $0)))'" } ?? "NULL"
            let now = ISO8601DateFormatter().string(from: Date())
            let dedupeKey = buildDedupeKey(task)

            let sql = """
            INSERT INTO tasks (
              task_id, title, category, due_at_local,
              estimated_minutes, min_daily_minutes, priority,
              stress_weight, feasibility_state, status,
              dedupe_key, created_at_utc, updated_at_utc
            ) VALUES (
              '\(escape(task.taskID.uuidString))',
              '\(escape(task.title))',
              '\(escape(task.category.rawValue))',
              \(due),
              \(task.estimatedMinutes),
              \(task.minDailyMinutes),
              \(task.priority),
              \(task.stressWeight),
              '\(escape(task.feasibilityState.rawValue))',
              '\(escape(task.status.rawValue))',
              '\(escape(dedupeKey))',
              '\(escape(now))',
              '\(escape(now))'
            )
            ON CONFLICT(task_id) DO UPDATE SET
              title = excluded.title,
              category = excluded.category,
              due_at_local = excluded.due_at_local,
              estimated_minutes = excluded.estimated_minutes,
              min_daily_minutes = excluded.min_daily_minutes,
              priority = excluded.priority,
              stress_weight = excluded.stress_weight,
              feasibility_state = excluded.feasibility_state,
              status = excluded.status,
              dedupe_key = excluded.dedupe_key,
              updated_at_utc = excluded.updated_at_utc;
            """

            try store.execute(sql)

            try store.execute("DELETE FROM task_sources WHERE task_id = '\(escape(task.taskID.uuidString))';")
            for source in task.sources {
                let sourceSQL = """
                INSERT OR REPLACE INTO task_sources (task_id, source, message_id, confidence)
                VALUES (
                  '\(escape(task.taskID.uuidString))',
                  '\(escape(source.source.rawValue))',
                  '\(escape(source.messageID))',
                  \(source.confidence)
                );
                """
                try store.execute(sourceSQL)
            }

            count += 1
        }

        return count
    }

    public func count() throws -> Int {
        let sql = "SELECT COUNT(*) AS n FROM tasks;"
        return try store.fetchRows(sql).first?["n"].flatMap(Int.init) ?? 0
    }

    private func buildDedupeKey(_ task: TaskItem) -> String {
        let due = task.dueAtLocal.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        return "\(task.category.rawValue)|\(task.title.lowercased())|\(due)"
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

public final class AuditLogRepository: @unchecked Sendable {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func log(category: String, severity: String, message: String, context: [String: String] = [:]) throws {
        let contextJSON: String
        if let data = try? JSONEncoder().encode(context), let json = String(data: data, encoding: .utf8) {
            contextJSON = json
        } else {
            contextJSON = "{}"
        }

        let sql = """
        INSERT INTO audit_log (log_id, category, severity, message, context_json, created_at_utc)
        VALUES (
          '\(UUID().uuidString)',
          '\(escape(category))',
          '\(escape(severity))',
          '\(escape(message))',
          '\(escape(contextJSON))',
          '\(ISO8601DateFormatter().string(from: Date()))'
        );
        """

        try store.execute(sql)
    }

    public func count(category: String? = nil) throws -> Int {
        let whereClause = category.map { " WHERE category = '\(escape($0))'" } ?? ""
        let sql = "SELECT COUNT(*) AS n FROM audit_log\(whereClause);"
        return try store.fetchRows(sql).first?["n"].flatMap(Int.init) ?? 0
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
