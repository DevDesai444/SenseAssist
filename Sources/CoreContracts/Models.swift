import Foundation

public enum UpdateSource: String, Codable, Sendable {
    case gmail
    case outlook
    case ublearnsEmail = "ublearns_email"
    case piazzaEmail = "piazza_email"
}

public struct ProviderIDs: Codable, Equatable, Sendable {
    public var messageID: String
    public var threadID: String?

    public init(messageID: String, threadID: String? = nil) {
        self.messageID = messageID
        self.threadID = threadID
    }
}

public enum ParserMethod: String, Codable, Sendable {
    case ruleBased = "rule_based"
    case llmFallback = "llm_fallback"
}

public struct UpdateCard: Codable, Equatable, Sendable {
    public var updateID: UUID
    public var accountID: String
    public var source: UpdateSource
    public var providerIDs: ProviderIDs
    public var receivedAtUTC: Date
    public var from: String
    public var subject: String
    public var bodyText: String
    public var links: [String]
    public var tags: [String]
    public var parserMethod: ParserMethod
    public var parseConfidence: Double
    public var evidence: [String]
    public var requiresConfirmation: Bool

    public init(
        updateID: UUID = UUID(),
        accountID: String = "default",
        source: UpdateSource,
        providerIDs: ProviderIDs,
        receivedAtUTC: Date,
        from: String,
        subject: String,
        bodyText: String,
        links: [String] = [],
        tags: [String] = [],
        parserMethod: ParserMethod,
        parseConfidence: Double,
        evidence: [String] = [],
        requiresConfirmation: Bool = false
    ) {
        self.updateID = updateID
        self.accountID = accountID
        self.source = source
        self.providerIDs = providerIDs
        self.receivedAtUTC = receivedAtUTC
        self.from = from
        self.subject = subject
        self.bodyText = bodyText
        self.links = links
        self.tags = tags
        self.parserMethod = parserMethod
        self.parseConfidence = parseConfidence
        self.evidence = evidence
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum TaskCategory: String, Codable, Sendable {
    case assignment
    case quiz
    case emailReply = "email_reply"
    case application
    case leetcode
    case project
    case admin
}

public enum TaskStatus: String, Codable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done
    case ignored
}

public enum FeasibilityState: String, Codable, Sendable {
    case onTrack = "on_track"
    case atRisk = "at_risk"
    case infeasible
}

public struct TaskSource: Codable, Equatable, Sendable {
    public var source: UpdateSource
    public var accountID: String
    public var messageID: String
    public var confidence: Double

    public init(source: UpdateSource, accountID: String = "default", messageID: String, confidence: Double) {
        self.source = source
        self.accountID = accountID
        self.messageID = messageID
        self.confidence = confidence
    }
}

public struct TaskItem: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var title: String
    public var category: TaskCategory
    public var dueAtLocal: Date?
    public var estimatedMinutes: Int
    public var minDailyMinutes: Int
    public var priority: Int
    public var stressWeight: Double
    public var feasibilityState: FeasibilityState
    public var sources: [TaskSource]
    public var status: TaskStatus

    public init(
        taskID: UUID = UUID(),
        title: String,
        category: TaskCategory,
        dueAtLocal: Date?,
        estimatedMinutes: Int,
        minDailyMinutes: Int,
        priority: Int,
        stressWeight: Double,
        feasibilityState: FeasibilityState = .onTrack,
        sources: [TaskSource] = [],
        status: TaskStatus = .todo
    ) {
        self.taskID = taskID
        self.title = title
        self.category = category
        self.dueAtLocal = dueAtLocal
        self.estimatedMinutes = estimatedMinutes
        self.minDailyMinutes = minDailyMinutes
        self.priority = priority
        self.stressWeight = stressWeight
        self.feasibilityState = feasibilityState
        self.sources = sources
        self.status = status
    }
}

public enum BlockLockLevel: String, Codable, Sendable {
    case flexible
    case locked
}

public struct CalendarBlock: Codable, Equatable, Sendable {
    public var blockID: UUID
    public var taskID: UUID?
    public var title: String
    public var startLocal: Date
    public var endLocal: Date
    public var ekEventID: String?
    public var calendarName: String
    public var managedByAgent: Bool
    public var lockLevel: BlockLockLevel
    public var planRevision: Int

    public init(
        blockID: UUID = UUID(),
        taskID: UUID? = nil,
        title: String,
        startLocal: Date,
        endLocal: Date,
        ekEventID: String? = nil,
        calendarName: String = "SenseAssist",
        managedByAgent: Bool = true,
        lockLevel: BlockLockLevel = .flexible,
        planRevision: Int
    ) {
        self.blockID = blockID
        self.taskID = taskID
        self.title = title
        self.startLocal = startLocal
        self.endLocal = endLocal
        self.ekEventID = ekEventID
        self.calendarName = calendarName
        self.managedByAgent = managedByAgent
        self.lockLevel = lockLevel
        self.planRevision = planRevision
    }
}

public enum EditIntent: String, Codable, Sendable {
    case createBlock = "create_block"
    case moveBlock = "move_block"
    case resizeBlock = "resize_block"
    case deleteBlock = "delete_block"
    case lockSleep = "lock_sleep"
    case regeneratePlan = "regenerate_plan"
    case markDone = "mark_done"
}

public struct EditTarget: Codable, Equatable, Sendable {
    public var ekEventID: String?
    public var fuzzyTitle: String?
    public var dateLocal: String?

    public init(ekEventID: String? = nil, fuzzyTitle: String? = nil, dateLocal: String? = nil) {
        self.ekEventID = ekEventID
        self.fuzzyTitle = fuzzyTitle
        self.dateLocal = dateLocal
    }
}

public struct EditTime: Codable, Equatable, Sendable {
    public var startLocal: Date?
    public var endLocal: Date?

    public init(startLocal: Date? = nil, endLocal: Date? = nil) {
        self.startLocal = startLocal
        self.endLocal = endLocal
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

public struct EditParameters: Codable, Equatable, Sendable {
    public var sleepWindow: SleepWindow?
    public var minDailyMinutes: Int?

    public init(sleepWindow: SleepWindow? = nil, minDailyMinutes: Int? = nil) {
        self.sleepWindow = sleepWindow
        self.minDailyMinutes = minDailyMinutes
    }
}

public struct EditOperation: Codable, Equatable, Sendable {
    public var opID: UUID
    public var expectedPlanRevision: Int
    public var intent: EditIntent
    public var target: EditTarget
    public var time: EditTime
    public var parameters: EditParameters
    public var requiresConfirmation: Bool
    public var ambiguityReason: String?
    public var notes: String

    public init(
        opID: UUID = UUID(),
        expectedPlanRevision: Int,
        intent: EditIntent,
        target: EditTarget,
        time: EditTime,
        parameters: EditParameters = EditParameters(),
        requiresConfirmation: Bool = false,
        ambiguityReason: String? = nil,
        notes: String = ""
    ) {
        self.opID = opID
        self.expectedPlanRevision = expectedPlanRevision
        self.intent = intent
        self.target = target
        self.time = time
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.ambiguityReason = ambiguityReason
        self.notes = notes
    }
}

public struct PlanSummary: Codable, Equatable, Sendable {
    public var createdBlocks: Int
    public var movedBlocks: Int
    public var deletedBlocks: Int

    public init(createdBlocks: Int, movedBlocks: Int, deletedBlocks: Int) {
        self.createdBlocks = createdBlocks
        self.movedBlocks = movedBlocks
        self.deletedBlocks = deletedBlocks
    }
}

public struct PlanRevision: Codable, Equatable, Sendable {
    public var revisionID: Int
    public var createdAtUTC: Date
    public var trigger: String
    public var summary: PlanSummary
    public var undoOperationID: UUID?

    public init(
        revisionID: Int,
        createdAtUTC: Date,
        trigger: String,
        summary: PlanSummary,
        undoOperationID: UUID? = nil
    ) {
        self.revisionID = revisionID
        self.createdAtUTC = createdAtUTC
        self.trigger = trigger
        self.summary = summary
        self.undoOperationID = undoOperationID
    }
}
