import Foundation

public struct PlannerConstraints: Codable, Equatable, Sendable {
    public var workdayStartHour24: Int
    public var workdayEndHour24: Int
    public var sleepStart: String
    public var sleepEnd: String
    public var maxDeepWorkMinutesPerDay: Int
    public var breakEveryMinutes: Int
    public var breakDurationMinutes: Int
    public var avoidAfterHour24: Int
    public var freeSpaceBufferMinutes: Int

    public init(
        workdayStartHour24: Int = 9,
        workdayEndHour24: Int = 22,
        sleepStart: String = "00:30",
        sleepEnd: String = "08:00",
        maxDeepWorkMinutesPerDay: Int = 240,
        breakEveryMinutes: Int = 90,
        breakDurationMinutes: Int = 10,
        avoidAfterHour24: Int = 23,
        freeSpaceBufferMinutes: Int = 45
    ) {
        self.workdayStartHour24 = workdayStartHour24
        self.workdayEndHour24 = workdayEndHour24
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.maxDeepWorkMinutesPerDay = maxDeepWorkMinutesPerDay
        self.breakEveryMinutes = breakEveryMinutes
        self.breakDurationMinutes = breakDurationMinutes
        self.avoidAfterHour24 = avoidAfterHour24
        self.freeSpaceBufferMinutes = freeSpaceBufferMinutes
    }
}

public struct SyncConfiguration: Codable, Equatable, Sendable {
    public var activePollingMinutes: Int
    public var normalPollingMinutes: Int
    public var idlePollingMinutes: Int
    public var maxBackoffMinutes: Int

    public init(
        activePollingMinutes: Int = 10,
        normalPollingMinutes: Int = 15,
        idlePollingMinutes: Int = 45,
        maxBackoffMinutes: Int = 120
    ) {
        self.activePollingMinutes = activePollingMinutes
        self.normalPollingMinutes = normalPollingMinutes
        self.idlePollingMinutes = idlePollingMinutes
        self.maxBackoffMinutes = maxBackoffMinutes
    }
}

public struct SenseAssistConfiguration: Codable, Equatable, Sendable {
    public var databasePath: String
    public var logLevel: LogLevel
    public var confidenceThreshold: Double
    public var constraints: PlannerConstraints
    public var sync: SyncConfiguration

    public init(
        databasePath: String,
        logLevel: LogLevel = .info,
        confidenceThreshold: Double = 0.80,
        constraints: PlannerConstraints = PlannerConstraints(),
        sync: SyncConfiguration = SyncConfiguration()
    ) {
        self.databasePath = databasePath
        self.logLevel = logLevel
        self.confidenceThreshold = confidenceThreshold
        self.constraints = constraints
        self.sync = sync
    }

    public static func `default`(homeDirectory: String) -> SenseAssistConfiguration {
        let dbPath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".senseassist")
            .appendingPathComponent("senseassist.sqlite")
            .path

        return SenseAssistConfiguration(databasePath: dbPath)
    }
}

public enum LogLevel: String, Codable, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
