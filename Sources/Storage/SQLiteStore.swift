import CoreContracts
import Foundation
import SQLite3

public enum StorageError: Error, LocalizedError {
    case openDatabase(path: String, message: String)
    case execute(statement: String, message: String)
    case prepare(statement: String, message: String)
    case step(statement: String, message: String)
    case migrationFailed(id: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .openDatabase(path, message):
            return "Failed to open database at \(path): \(message)"
        case let .execute(statement, message):
            return "Failed to execute SQL [\(statement)]: \(message)"
        case let .prepare(statement, message):
            return "Failed to prepare SQL [\(statement)]: \(message)"
        case let .step(statement, message):
            return "Failed to step SQL [\(statement)]: \(message)"
        case let .migrationFailed(id, message):
            return "Failed migration \(id): \(message)"
        }
    }
}

public struct SQLMigration: Sendable {
    public let id: String
    public let statements: [String]

    public init(id: String, statements: [String]) {
        self.id = id
        self.statements = statements
    }
}

public final class SQLiteStore {
    private let databasePath: String
    private var db: OpaquePointer?
    private let logger: Logging

    public init(databasePath: String, logger: Logging) {
        self.databasePath = databasePath
        self.logger = logger
    }

    deinit {
        close()
    }

    public func initialize(with migrations: [SQLMigration] = DefaultMigrations.all) throws {
        try ensureParentDirectoryExists()
        try openIfNeeded()
        try createMigrationsTable()
        try apply(migrations)
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func healthCheck() throws -> Bool {
        try openIfNeeded()
        let statement = "SELECT 1;"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &query, nil) == SQLITE_OK else {
            throw StorageError.prepare(statement: statement, message: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(query) }

        let result = sqlite3_step(query)
        guard result == SQLITE_ROW else {
            throw StorageError.step(statement: statement, message: sqliteErrorMessage())
        }

        return sqlite3_column_int(query, 0) == 1
    }

    public func execute(_ statement: String) throws {
        try openIfNeeded()

        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.execute(statement: statement, message: sqliteErrorMessage())
        }
    }

    private func ensureParentDirectoryExists() throws {
        let url = URL(fileURLWithPath: databasePath)
        let directory = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func openIfNeeded() throws {
        if db != nil {
            return
        }

        if sqlite3_open(databasePath, &db) != SQLITE_OK {
            let message = sqliteErrorMessage()
            close()
            throw StorageError.openDatabase(path: databasePath, message: message)
        }

        logger.log(.info, "Opened SQLite database at \(databasePath)", category: "storage")
    }

    private func createMigrationsTable() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
              id TEXT PRIMARY KEY,
              applied_at_utc TEXT NOT NULL
            );
            """
        )
    }

    private func apply(_ migrations: [SQLMigration]) throws {
        for migration in migrations {
            guard try !isMigrationApplied(id: migration.id) else {
                continue
            }

            logger.log(.info, "Applying migration \(migration.id)", category: "storage")
            do {
                try execute("BEGIN TRANSACTION;")
                for statement in migration.statements {
                    try execute(statement)
                }

                let appliedAt = ISO8601DateFormatter().string(from: Date())
                try execute(
                    "INSERT INTO schema_migrations (id, applied_at_utc) VALUES ('\(migration.id)', '\(appliedAt)');"
                )
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw StorageError.migrationFailed(id: migration.id, message: error.localizedDescription)
            }
        }
    }

    private func isMigrationApplied(id: String) throws -> Bool {
        let statement = "SELECT COUNT(*) FROM schema_migrations WHERE id = ?;"
        var query: OpaquePointer?

        guard sqlite3_prepare_v2(db, statement, -1, &query, nil) == SQLITE_OK else {
            throw StorageError.prepare(statement: statement, message: sqliteErrorMessage())
        }

        defer { sqlite3_finalize(query) }

        sqlite3_bind_text(query, 1, id, -1, nil)

        guard sqlite3_step(query) == SQLITE_ROW else {
            throw StorageError.step(statement: statement, message: sqliteErrorMessage())
        }

        return sqlite3_column_int(query, 0) > 0
    }

    private func sqliteErrorMessage() -> String {
        guard let db else { return "No database handle" }
        guard let cString = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: cString)
    }
}

public enum DefaultMigrations {
    public static let all: [SQLMigration] = [
        SQLMigration(
            id: "001_core_tables",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS updates (
                  update_id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  message_id TEXT NOT NULL,
                  thread_id TEXT,
                  received_at_utc TEXT NOT NULL,
                  sender TEXT NOT NULL,
                  subject TEXT NOT NULL,
                  body_text TEXT,
                  links_json TEXT NOT NULL,
                  tags_json TEXT NOT NULL,
                  parser_method TEXT NOT NULL,
                  parse_confidence REAL NOT NULL,
                  content_hash TEXT NOT NULL,
                  requires_confirmation INTEGER NOT NULL DEFAULT 0,
                  created_at_utc TEXT NOT NULL
                );
                """,
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_updates_provider ON updates(source, message_id);",
                """
                CREATE TABLE IF NOT EXISTS tasks (
                  task_id TEXT PRIMARY KEY,
                  title TEXT NOT NULL,
                  category TEXT NOT NULL,
                  due_at_local TEXT,
                  estimated_minutes INTEGER NOT NULL,
                  min_daily_minutes INTEGER NOT NULL,
                  priority INTEGER NOT NULL,
                  stress_weight REAL NOT NULL,
                  feasibility_state TEXT NOT NULL,
                  status TEXT NOT NULL,
                  dedupe_key TEXT NOT NULL,
                  created_at_utc TEXT NOT NULL,
                  updated_at_utc TEXT NOT NULL
                );
                """,
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_dedupe ON tasks(dedupe_key);",
                """
                CREATE TABLE IF NOT EXISTS blocks (
                  block_id TEXT PRIMARY KEY,
                  task_id TEXT,
                  title TEXT NOT NULL,
                  start_local TEXT NOT NULL,
                  end_local TEXT NOT NULL,
                  ek_event_id TEXT,
                  calendar_name TEXT NOT NULL,
                  managed_by_agent INTEGER NOT NULL DEFAULT 1,
                  lock_level TEXT NOT NULL,
                  plan_revision INTEGER NOT NULL,
                  created_at_utc TEXT NOT NULL,
                  updated_at_utc TEXT NOT NULL
                );
                """,
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_blocks_event ON blocks(ek_event_id);",
                """
                CREATE TABLE IF NOT EXISTS plan_revisions (
                  revision_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  trigger TEXT NOT NULL,
                  summary_json TEXT NOT NULL,
                  created_at_utc TEXT NOT NULL
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS operations (
                  op_id TEXT PRIMARY KEY,
                  expected_plan_revision INTEGER,
                  applied_revision INTEGER,
                  intent TEXT NOT NULL,
                  status TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  result_json TEXT,
                  created_at_utc TEXT NOT NULL
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS provider_cursors (
                  provider TEXT PRIMARY KEY,
                  cursor_primary TEXT NOT NULL,
                  cursor_secondary TEXT,
                  updated_at_utc TEXT NOT NULL
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS preferences (
                  key TEXT PRIMARY KEY,
                  value_json TEXT NOT NULL,
                  updated_at_utc TEXT NOT NULL
                );
                """,
                """
                CREATE TABLE IF NOT EXISTS audit_log (
                  log_id TEXT PRIMARY KEY,
                  category TEXT NOT NULL,
                  severity TEXT NOT NULL,
                  message TEXT NOT NULL,
                  context_json TEXT NOT NULL,
                  created_at_utc TEXT NOT NULL
                );
                """
            ]
        )
    ]
}
