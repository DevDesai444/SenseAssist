import Foundation

public struct PlannerInputSnapshot: Codable, Equatable, Sendable {
    public var meta: Meta
    public var constraints: Constraints
    public var busyBlocks: [BusyBlock]
    public var tasks: [Task]

    public init(meta: Meta, constraints: Constraints, busyBlocks: [BusyBlock], tasks: [Task]) {
        self.meta = meta
        self.constraints = constraints
        self.busyBlocks = busyBlocks
        self.tasks = tasks
    }

    enum CodingKeys: String, CodingKey {
        case meta
        case constraints
        case busyBlocks = "busy_blocks"
        case tasks
    }

    public struct Meta: Codable, Equatable, Sendable {
        public var generatedAtUTC: Date
        public var planningDateLocal: String
        public var timeZone: String
        public var planRevision: Int

        public init(generatedAtUTC: Date, planningDateLocal: String, timeZone: String, planRevision: Int) {
            self.generatedAtUTC = generatedAtUTC
            self.planningDateLocal = planningDateLocal
            self.timeZone = timeZone
            self.planRevision = planRevision
        }

        enum CodingKeys: String, CodingKey {
            case generatedAtUTC = "generated_at_utc"
            case planningDateLocal = "planning_date_local"
            case timeZone = "time_zone"
            case planRevision = "plan_revision"
        }
    }

    public struct Constraints: Codable, Equatable, Sendable {
        public var dayStartLocal: Date
        public var dayEndLocal: Date
        public var maxDeepWorkMinutesPerDay: Int
        public var breakEveryMinutes: Int
        public var breakDurationMinutes: Int
        public var freeSpaceBufferMinutes: Int
        public var sleepWindow: SleepWindow

        public init(
            dayStartLocal: Date,
            dayEndLocal: Date,
            maxDeepWorkMinutesPerDay: Int,
            breakEveryMinutes: Int,
            breakDurationMinutes: Int,
            freeSpaceBufferMinutes: Int,
            sleepWindow: SleepWindow
        ) {
            self.dayStartLocal = dayStartLocal
            self.dayEndLocal = dayEndLocal
            self.maxDeepWorkMinutesPerDay = maxDeepWorkMinutesPerDay
            self.breakEveryMinutes = breakEveryMinutes
            self.breakDurationMinutes = breakDurationMinutes
            self.freeSpaceBufferMinutes = freeSpaceBufferMinutes
            self.sleepWindow = sleepWindow
        }

        enum CodingKeys: String, CodingKey {
            case dayStartLocal = "day_start_local"
            case dayEndLocal = "day_end_local"
            case maxDeepWorkMinutesPerDay = "max_deep_work_minutes_per_day"
            case breakEveryMinutes = "break_every_minutes"
            case breakDurationMinutes = "break_duration_minutes"
            case freeSpaceBufferMinutes = "free_space_buffer_minutes"
            case sleepWindow = "sleep_window"
        }
    }

    public struct SleepWindow: Codable, Equatable, Sendable {
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public struct BusyBlock: Codable, Equatable, Sendable {
        public var title: String
        public var startLocal: Date
        public var endLocal: Date
        public var lockLevel: String
        public var managedByAgent: Bool

        public init(title: String, startLocal: Date, endLocal: Date, lockLevel: String, managedByAgent: Bool) {
            self.title = title
            self.startLocal = startLocal
            self.endLocal = endLocal
            self.lockLevel = lockLevel
            self.managedByAgent = managedByAgent
        }

        enum CodingKeys: String, CodingKey {
            case title
            case startLocal = "start_local"
            case endLocal = "end_local"
            case lockLevel = "lock_level"
            case managedByAgent = "managed_by_agent"
        }
    }

    public struct Task: Codable, Equatable, Sendable {
        public var taskID: String
        public var title: String
        public var category: String
        public var dueAtLocal: Date?
        public var estimatedMinutes: Int
        public var minDailyMinutes: Int
        public var priority: Int
        public var stressWeight: Double
        public var confidence: Double
        public var isLargeAssignment: Bool
        public var shouldDeferUntilDayBeforeDue: Bool
        public var sources: [Source]

        public init(
            taskID: String,
            title: String,
            category: String,
            dueAtLocal: Date?,
            estimatedMinutes: Int,
            minDailyMinutes: Int,
            priority: Int,
            stressWeight: Double,
            confidence: Double,
            isLargeAssignment: Bool,
            shouldDeferUntilDayBeforeDue: Bool,
            sources: [Source]
        ) {
            self.taskID = taskID
            self.title = title
            self.category = category
            self.dueAtLocal = dueAtLocal
            self.estimatedMinutes = estimatedMinutes
            self.minDailyMinutes = minDailyMinutes
            self.priority = priority
            self.stressWeight = stressWeight
            self.confidence = confidence
            self.isLargeAssignment = isLargeAssignment
            self.shouldDeferUntilDayBeforeDue = shouldDeferUntilDayBeforeDue
            self.sources = sources
        }

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case title
            case category
            case dueAtLocal = "due_at_local"
            case estimatedMinutes = "estimated_minutes"
            case minDailyMinutes = "min_daily_minutes"
            case priority
            case stressWeight = "stress_weight"
            case confidence
            case isLargeAssignment = "is_large_assignment"
            case shouldDeferUntilDayBeforeDue = "should_defer_until_day_before_due"
            case sources
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public var provider: String
        public var accountID: String
        public var messageID: String
        public var confidence: Double

        public init(provider: String, accountID: String, messageID: String, confidence: Double) {
            self.provider = provider
            self.accountID = accountID
            self.messageID = messageID
            self.confidence = confidence
        }

        enum CodingKeys: String, CodingKey {
            case provider
            case accountID = "account_id"
            case messageID = "message_id"
            case confidence
        }
    }
}
