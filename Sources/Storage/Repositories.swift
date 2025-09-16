import CoreContracts
import CryptoKit
import Foundation

public enum StorageProvider: String, Sendable {
    case gmail
    case outlook
}

public struct ProviderCursorRecord: Sendable {
    public var provider: StorageProvider
    public var accountID: String
    public var primary: String
    public var secondary: String?

    public init(provider: StorageProvider, accountID: String, primary: String, secondary: String? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.primary = primary
        self.secondary = secondary
    }
}

public final class ProviderCursorRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func get(provider: StorageProvider, accountID: String) throws -> ProviderCursorRecord? {
        let sql = """
        SELECT provider, account_id, cursor_primary, cursor_secondary
        FROM provider_cursors
        WHERE provider = '\(escape(provider.rawValue))'
          AND account_id = '\(escape(accountID))'
        LIMIT 1;
        """

        guard let row = try store.fetchRows(sql).first,
              let providerName = row["provider"],
              let storedAccountID = row["account_id"],
              let primary = row["cursor_primary"],
              let parsedProvider = StorageProvider(rawValue: providerName)
        else {
            return nil
        }

        return ProviderCursorRecord(
            provider: parsedProvider,
            accountID: storedAccountID,
            primary: primary,
            secondary: row["cursor_secondary"]
        )
    }

    public func upsert(_ record: ProviderCursorRecord) throws {
        let secondarySQL = record.secondary.map { "'\(escape($0))'" } ?? "NULL"

        let sql = """
        INSERT INTO provider_cursors (provider, account_id, cursor_primary, cursor_secondary, updated_at_utc)
        VALUES (
          '\(escape(record.provider.rawValue))',
          '\(escape(record.accountID))',
          '\(escape(record.primary))',
          \(secondarySQL),
          '\(timestamp())'
        )
        ON CONFLICT(provider, account_id) DO UPDATE SET
          cursor_primary = excluded.cursor_primary,
          cursor_secondary = excluded.cursor_secondary,
          updated_at_utc = excluded.updated_at_utc;
        """

        try store.execute(sql)
    }

    public func list(for provider: StorageProvider) throws -> [ProviderCursorRecord] {
        let sql = """
        SELECT provider, account_id, cursor_primary, cursor_secondary
        FROM provider_cursors
        WHERE provider = '\(escape(provider.rawValue))'
        ORDER BY account_id;
        """

        return try store.fetchRows(sql).compactMap { row in
            guard
                let providerName = row["provider"],
                let accountID = row["account_id"],
                let primary = row["cursor_primary"],
                let parsedProvider = StorageProvider(rawValue: providerName)
            else {
                return nil
            }

            return ProviderCursorRecord(
                provider: parsedProvider,
                accountID: accountID,
                primary: primary,
                secondary: row["cursor_secondary"]
            )
        }
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
            let contentHash = stableContentHash(update.bodyText)
            let requiresConfirmation = update.requiresConfirmation ? 1 : 0

            let sql = """
            INSERT OR IGNORE INTO updates (
              update_id, source, account_id, message_id, thread_id,
              received_at_utc, sender, subject, body_text,
              links_json, tags_json, parser_method, parse_confidence,
              content_hash, requires_confirmation, created_at_utc
            ) VALUES (
              '\(escape(update.updateID.uuidString))',
              '\(escape(update.source.rawValue))',
              '\(escape(update.accountID))',
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

    public func count(source: UpdateSource? = nil, accountID: String? = nil) throws -> Int {
        var predicates: [String] = []
        if let source {
            predicates.append("source = '\(escape(source.rawValue))'")
        }
        if let accountID {
            predicates.append("account_id = '\(escape(accountID))'")
        }

        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let sql = "SELECT COUNT(*) AS n FROM updates\(whereClause);"
        return try store.fetchRows(sql).first?["n"].flatMap(Int.init) ?? 0
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

    private func stableContentHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
            let incomingTaskID = escape(task.taskID.uuidString)

            let sql = """
            INSERT INTO tasks (
              task_id, title, category, due_at_local,
              estimated_minutes, min_daily_minutes, priority,
              stress_weight, feasibility_state, status,
              dedupe_key, created_at_utc, updated_at_utc
            ) VALUES (
              '\(incomingTaskID)',
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
            ON CONFLICT(dedupe_key) DO UPDATE SET
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

            let resolvedTaskID = try resolvedTaskIDForDedupeKey(dedupeKey) ?? task.taskID.uuidString
            for source in task.sources {
                let sourceSQL = """
                INSERT OR REPLACE INTO task_sources (task_id, source, account_id, message_id, confidence)
                VALUES (
                  '\(escape(resolvedTaskID))',
                  '\(escape(source.source.rawValue))',
                  '\(escape(source.accountID))',
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

    public func listActive() throws -> [TaskItem] {
        let sql = """
        SELECT task_id, title, category, due_at_local, estimated_minutes, min_daily_minutes,
               priority, stress_weight, feasibility_state, status
        FROM tasks
        WHERE status IN ('todo', 'in_progress')
        ORDER BY priority DESC, due_at_local ASC, updated_at_utc DESC;
        """

        let formatter = ISO8601DateFormatter()
        return try store.fetchRows(sql).compactMap { row in
            guard
                let taskIDRaw = row["task_id"],
                let taskID = UUID(uuidString: taskIDRaw),
                let title = row["title"],
                let categoryRaw = row["category"],
                let category = TaskCategory(rawValue: categoryRaw),
                let estimatedRaw = row["estimated_minutes"],
                let estimatedMinutes = Int(estimatedRaw),
                let minDailyRaw = row["min_daily_minutes"],
                let minDailyMinutes = Int(minDailyRaw),
                let priorityRaw = row["priority"],
                let priority = Int(priorityRaw),
                let stressRaw = row["stress_weight"],
                let stressWeight = Double(stressRaw),
                let feasibilityRaw = row["feasibility_state"],
                let feasibility = FeasibilityState(rawValue: feasibilityRaw),
                let statusRaw = row["status"],
                let status = TaskStatus(rawValue: statusRaw)
            else {
                return nil
            }

            let dueAtLocal = row["due_at_local"].flatMap { value -> Date? in
                guard !value.isEmpty else { return nil }
                return formatter.date(from: value)
            }

            return TaskItem(
                taskID: taskID,
                title: title,
                category: category,
                dueAtLocal: dueAtLocal,
                estimatedMinutes: estimatedMinutes,
                minDailyMinutes: minDailyMinutes,
                priority: priority,
                stressWeight: stressWeight,
                feasibilityState: feasibility,
                sources: [],
                status: status
            )
        }
    }

    private func buildDedupeKey(_ task: TaskItem) -> String {
        let due = task.dueAtLocal.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        return "\(task.category.rawValue)|\(task.title.lowercased())|\(due)"
    }

    private func resolvedTaskIDForDedupeKey(_ dedupeKey: String) throws -> String? {
        let sql = """
        SELECT task_id
        FROM tasks
        WHERE dedupe_key = '\(escape(dedupeKey))'
        LIMIT 1;
        """

        return try store.fetchRows(sql).first?["task_id"]
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

public struct ConnectedEmailAccount: Sendable, Equatable {
    public var accountID: String
    public var provider: StorageProvider
    public var email: String
    public var isEnabled: Bool

    public init(accountID: String, provider: StorageProvider, email: String, isEnabled: Bool = true) {
        self.accountID = accountID
        self.provider = provider
        self.email = email
        self.isEnabled = isEnabled
    }
}

public final class AccountRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func upsert(_ account: ConnectedEmailAccount) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let enabled = account.isEnabled ? 1 : 0
        let sql = """
        INSERT INTO accounts (account_id, provider, email, is_enabled, created_at_utc, updated_at_utc)
        VALUES (
          '\(escape(account.accountID))',
          '\(escape(account.provider.rawValue))',
          '\(escape(account.email))',
          \(enabled),
          '\(now)',
          '\(now)'
        )
        ON CONFLICT(account_id) DO UPDATE SET
          provider = excluded.provider,
          email = excluded.email,
          is_enabled = excluded.is_enabled,
          updated_at_utc = excluded.updated_at_utc;
        """
        try store.execute(sql)
    }

    public func list(enabledOnly: Bool = false) throws -> [ConnectedEmailAccount] {
        let whereClause = enabledOnly ? " WHERE is_enabled = 1" : ""
        let sql = """
        SELECT account_id, provider, email, is_enabled
        FROM accounts\(whereClause)
        ORDER BY provider, email;
        """

        return try store.fetchRows(sql).compactMap { row in
            guard
                let accountID = row["account_id"],
                let providerRaw = row["provider"],
                let provider = StorageProvider(rawValue: providerRaw),
                let email = row["email"]
            else {
                return nil
            }

            let isEnabled = row["is_enabled"].flatMap(Int.init).map { $0 != 0 } ?? false
            return ConnectedEmailAccount(accountID: accountID, provider: provider, email: email, isEnabled: isEnabled)
        }
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

public final class PlanRevisionRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func latestRevisionID() throws -> Int {
        let sql = "SELECT COALESCE(MAX(revision_id), 0) AS n FROM plan_revisions;"
        return try store.fetchRows(sql).first?["n"].flatMap(Int.init) ?? 0
    }

    @discardableResult
    public func append(trigger: String, summary: PlanSummary) throws -> Int {
        let summaryJSON: String
        if let data = try? JSONEncoder().encode(summary), let text = String(data: data, encoding: .utf8) {
            summaryJSON = text
        } else {
            summaryJSON = "{\"createdBlocks\":0,\"movedBlocks\":0,\"deletedBlocks\":0}"
        }

        let sql = """
        INSERT INTO plan_revisions (trigger, summary_json, created_at_utc)
        VALUES (
          '\(escape(trigger))',
          '\(escape(summaryJSON))',
          '\(timestamp())'
        );
        """
        try store.execute(sql)

        let rowIDSQL = "SELECT last_insert_rowid() AS n;"
        return try store.fetchRows(rowIDSQL).first?["n"].flatMap(Int.init) ?? 0
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

public struct StoredOperationRecord: Sendable {
    public var opID: String
    public var expectedPlanRevision: Int?
    public var appliedRevision: Int?
    public var intent: String
    public var status: String
    public var payloadJSON: String
    public var resultJSON: String?
    public var createdAtUTC: String

    public init(
        opID: String = UUID().uuidString,
        expectedPlanRevision: Int?,
        appliedRevision: Int?,
        intent: String,
        status: String,
        payloadJSON: String,
        resultJSON: String? = nil,
        createdAtUTC: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.opID = opID
        self.expectedPlanRevision = expectedPlanRevision
        self.appliedRevision = appliedRevision
        self.intent = intent
        self.status = status
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.createdAtUTC = createdAtUTC
    }
}

public final class OperationRepository {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func latestAppliedRevision() throws -> Int {
        let sql = "SELECT COALESCE(MAX(applied_revision), 0) AS n FROM operations WHERE applied_revision IS NOT NULL;"
        return try store.fetchRows(sql).first?["n"].flatMap(Int.init) ?? 0
    }

    public func insert(_ record: StoredOperationRecord) throws {
        let expectedSQL = record.expectedPlanRevision.map(String.init) ?? "NULL"
        let appliedSQL = record.appliedRevision.map(String.init) ?? "NULL"
        let resultSQL = record.resultJSON.map { "'\(escape($0))'" } ?? "NULL"

        let sql = """
        INSERT OR REPLACE INTO operations (
          op_id, expected_plan_revision, applied_revision, intent, status, payload_json, result_json, created_at_utc
        ) VALUES (
          '\(escape(record.opID))',
          \(expectedSQL),
          \(appliedSQL),
          '\(escape(record.intent))',
          '\(escape(record.status))',
          '\(escape(record.payloadJSON))',
          \(resultSQL),
          '\(escape(record.createdAtUTC))'
        );
        """
        try store.execute(sql)
    }

    public func latestUndoableOperation() throws -> StoredOperationRecord? {
        let sql = """
        SELECT op_id, expected_plan_revision, applied_revision, intent, status, payload_json, result_json, created_at_utc
        FROM operations
        WHERE status = 'applied'
          AND intent IN ('create_block', 'move_block')
        ORDER BY created_at_utc DESC
        LIMIT 1;
        """

        guard let row = try store.fetchRows(sql).first,
              let opID = row["op_id"],
              let intent = row["intent"],
              let status = row["status"],
              let payload = row["payload_json"],
              let createdAt = row["created_at_utc"]
        else {
            return nil
        }

        return StoredOperationRecord(
            opID: opID,
            expectedPlanRevision: row["expected_plan_revision"].flatMap(Int.init),
            appliedRevision: row["applied_revision"].flatMap(Int.init),
            intent: intent,
            status: status,
            payloadJSON: payload,
            resultJSON: row["result_json"],
            createdAtUTC: createdAt
        )
    }

    public func markUndone(opID: String) throws {
        let sql = """
        UPDATE operations
        SET status = 'undone'
        WHERE op_id = '\(escape(opID))';
        """
        try store.execute(sql)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
