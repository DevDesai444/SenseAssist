import CoreContracts
import Foundation

public enum LLMRuntimeError: Error, LocalizedError {
    case unsupportedPrompt
    case invalidJSON
    case invalidURL
    case requestFailed(code: Int, body: String)
    case missingResponse
    case runnerNotFound(path: String)
    case runnerLaunchFailed(message: String)
    case runnerExecutionFailed(code: Int32, stderr: String)
    case runnerInvalidOutput

    public var errorDescription: String? {
        switch self {
        case .unsupportedPrompt:
            return "Unsupported prompt for stub LLM runtime"
        case .invalidJSON:
            return "Invalid JSON payload"
        case .invalidURL:
            return "Invalid LLM endpoint URL"
        case let .requestFailed(code, body):
            return "LLM request failed \(code): \(body)"
        case .missingResponse:
            return "Missing response from LLM"
        case let .runnerNotFound(path):
            return "ONNX runner script not found at \(path)"
        case let .runnerLaunchFailed(message):
            return "Failed to launch ONNX runner: \(message)"
        case let .runnerExecutionFailed(code, stderr):
            return "ONNX runner failed (\(code)): \(stderr)"
        case .runnerInvalidOutput:
            return "ONNX runner returned invalid output"
        }
    }
}

public protocol LLMRuntimeClient: Sendable {
    func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem]
    func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation
    func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan
}

public struct ONNXGenAILLMRuntime: LLMRuntimeClient {
    private let modelPath: String
    private let runnerScriptPath: String
    private let pythonExecutable: String
    private let maxNewTokens: Int
    private let temperature: Double
    private let topP: Double
    private let provider: String?

    public init(
        modelPath: String,
        runnerScriptPath: String,
        pythonExecutable: String = "/usr/bin/python3",
        maxNewTokens: Int = 512,
        temperature: Double = 0.2,
        topP: Double = 0.95,
        provider: String? = nil
    ) {
        self.modelPath = modelPath
        self.runnerScriptPath = runnerScriptPath
        self.pythonExecutable = pythonExecutable
        self.maxNewTokens = max(64, maxNewTokens)
        self.temperature = max(0.0, temperature)
        self.topP = min(max(topP, 0.0), 1.0)
        self.provider = provider
    }

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        if updates.isEmpty {
            return []
        }

        let simplifiedUpdates = updates.map { update in
            [
                "account_id": update.accountID,
                "source": update.source.rawValue,
                "message_id": update.providerIDs.messageID,
                "subject": update.subject,
                "body_text": String(update.bodyText.prefix(4000)),
                "tags": update.tags
            ] as [String: Any]
        }

        let prompt = """
        You are an extraction engine. Convert email updates into actionable tasks.
        Return ONLY valid JSON array matching this schema exactly:
        [
          {
            "source_message_id": "string",
            "title": "string",
            "category": "assignment|quiz|email_reply|application|leetcode|project|admin",
            "due_at_local": "ISO-8601 datetime string or null",
            "estimated_minutes": number,
            "min_daily_minutes": number,
            "priority": number,
            "stress_weight": number,
            "status": "todo|in_progress|done|ignored"
          }
        ]
        Do not include markdown.

        Updates JSON:
        \(jsonString(simplifiedUpdates))
        """

        let raw = try generate(prompt: prompt)
        let json = try extractJSONArray(from: raw)
        let decoded = try JSONDecoder().decode([ExtractedTaskPayload].self, from: Data(json.utf8))
        let updateByMessageID = Dictionary(uniqueKeysWithValues: updates.map { ($0.providerIDs.messageID, $0) })

        return decoded.compactMap { payload in
            guard let sourceUpdate = payload.sourceMessageID.flatMap({ updateByMessageID[$0] }) ?? updates.first else {
                return nil
            }

            return TaskItem(
                title: payload.title,
                category: payload.category,
                dueAtLocal: parseDueDate(payload.dueAtLocal),
                estimatedMinutes: max(15, payload.estimatedMinutes),
                minDailyMinutes: max(15, payload.minDailyMinutes),
                priority: max(1, payload.priority),
                stressWeight: min(max(payload.stressWeight, 0.0), 1.0),
                sources: [
                    TaskSource(
                        source: sourceUpdate.source,
                        accountID: sourceUpdate.accountID,
                        messageID: sourceUpdate.providerIDs.messageID,
                        confidence: 0.85
                    )
                ],
                status: payload.status
            )
        }
    }

    public func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        let prompt = """
        You are a command parser for planning operations.
        Return ONLY valid JSON object with this schema:
        {
          "intent": "create_block|move_block|resize_block|delete_block|lock_sleep|regenerate_plan|mark_done",
          "target": {"ek_event_id": string|null, "fuzzy_title": string|null, "date_local": string|null},
          "time": {"start_local": string|null, "end_local": string|null},
          "requires_confirmation": boolean,
          "notes": string
        }
        Parse this text:
        \(messageText)
        """

        let raw = try generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        let payload = try JSONDecoder().decode(SlackEditPayload.self, from: Data(json.utf8))

        let iso = ISO8601DateFormatter()
        let start = payload.time.startLocal.flatMap(iso.date(from:))
        let end = payload.time.endLocal.flatMap(iso.date(from:))

        guard let intent = EditIntent(rawValue: payload.intent) else {
            throw LLMRuntimeError.invalidJSON
        }

        return EditOperation(
            expectedPlanRevision: expectedPlanRevision,
            intent: intent,
            target: EditTarget(
                ekEventID: payload.target.ekEventID,
                fuzzyTitle: payload.target.fuzzyTitle,
                dateLocal: payload.target.dateLocal
            ),
            time: EditTime(startLocal: start, endLocal: end),
            parameters: EditParameters(),
            requiresConfirmation: payload.requiresConfirmation,
            notes: payload.notes
        )
    }

    public func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        let activeTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }
        guard !activeTasks.isEmpty else {
            return SchedulePlan(blocks: [], feasibilityState: .onTrack, unscheduledTaskIDs: [])
        }

        let prompt = buildSchedulePrompt(
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )

        let raw = try generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        let payload = try JSONDecoder().decode(SchedulePlanPayload.self, from: Data(json.utf8))
        return try materializeSchedulePlan(
            payload: payload,
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func generate(prompt: String) throws -> String {
        guard FileManager.default.fileExists(atPath: runnerScriptPath) else {
            throw LLMRuntimeError.runnerNotFound(path: runnerScriptPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = [runnerScriptPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let request = ONNXRunnerRequest(
            modelPath: modelPath,
            prompt: prompt,
            maxNewTokens: maxNewTokens,
            temperature: temperature,
            topP: topP,
            provider: provider
        )

        do {
            try process.run()
        } catch {
            throw LLMRuntimeError.runnerLaunchFailed(message: error.localizedDescription)
        }

        do {
            let encoded = try JSONEncoder().encode(request)
            try stdinPipe.fileHandleForWriting.write(contentsOf: encoded)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw LLMRuntimeError.runnerLaunchFailed(message: "Failed to send request to ONNX runner")
        }

        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw LLMRuntimeError.runnerExecutionFailed(code: process.terminationStatus, stderr: stderrText)
        }

        guard let response = try? JSONDecoder().decode(ONNXRunnerResponse.self, from: outputData) else {
            throw LLMRuntimeError.runnerInvalidOutput
        }

        return response.text
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    private func extractJSONArray(from text: String) throws -> String {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else {
            throw LLMRuntimeError.invalidJSON
        }
        return String(text[start...end])
    }

    private func extractJSONObject(from text: String) throws -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            throw LLMRuntimeError.invalidJSON
        }
        return String(text[start...end])
    }

    private func parseDueDate(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}

public struct OllamaLLMRuntime: LLMRuntimeClient {
    private let endpointURL: URL
    private let model: String
    private let session: URLSession

    public init(endpointURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String, session: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.model = model
        self.session = session
    }

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        if updates.isEmpty {
            return []
        }

        let simplifiedUpdates = updates.map { update in
            [
                "account_id": update.accountID,
                "source": update.source.rawValue,
                "message_id": update.providerIDs.messageID,
                "subject": update.subject,
                "body_text": String(update.bodyText.prefix(4000)),
                "tags": update.tags
            ] as [String: Any]
        }

        let prompt = """
        You are an extraction engine. Convert email updates into actionable tasks.
        Return ONLY valid JSON array matching this schema exactly:
        [
          {
            "source_message_id": "string",
            "title": "string",
            "category": "assignment|quiz|email_reply|application|leetcode|project|admin",
            "due_at_local": "ISO-8601 datetime string or null",
            "estimated_minutes": number,
            "min_daily_minutes": number,
            "priority": number,
            "stress_weight": number,
            "status": "todo|in_progress|done|ignored"
          }
        ]
        Do not include markdown.

        Updates JSON:
        \(jsonString(simplifiedUpdates))
        """

        let raw = try await generate(prompt: prompt)
        let json = try extractJSONArray(from: raw)

        let decoded = try JSONDecoder().decode([ExtractedTaskPayload].self, from: Data(json.utf8))
        let updateByMessageID = Dictionary(uniqueKeysWithValues: updates.map { ($0.providerIDs.messageID, $0) })

        return decoded.compactMap { payload in
            guard let sourceUpdate = payload.sourceMessageID.flatMap({ updateByMessageID[$0] }) ?? updates.first else {
                return nil
            }

            return TaskItem(
                title: payload.title,
                category: payload.category,
                dueAtLocal: parseDueDate(payload.dueAtLocal),
                estimatedMinutes: max(15, payload.estimatedMinutes),
                minDailyMinutes: max(15, payload.minDailyMinutes),
                priority: max(1, payload.priority),
                stressWeight: min(max(payload.stressWeight, 0.0), 1.0),
                sources: [
                    TaskSource(
                        source: sourceUpdate.source,
                        accountID: sourceUpdate.accountID,
                        messageID: sourceUpdate.providerIDs.messageID,
                        confidence: 0.85
                    )
                ],
                status: payload.status
            )
        }
    }

    public func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        let prompt = """
        You are a command parser for planning operations.
        Return ONLY valid JSON object with this schema:
        {
          "intent": "create_block|move_block|resize_block|delete_block|lock_sleep|regenerate_plan|mark_done",
          "target": {"ek_event_id": string|null, "fuzzy_title": string|null, "date_local": string|null},
          "time": {"start_local": string|null, "end_local": string|null},
          "requires_confirmation": boolean,
          "notes": string
        }
        Parse this text:
        \(messageText)
        """

        let raw = try await generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        let payload = try JSONDecoder().decode(SlackEditPayload.self, from: Data(json.utf8))

        let iso = ISO8601DateFormatter()
        let start = payload.time.startLocal.flatMap(iso.date(from:))
        let end = payload.time.endLocal.flatMap(iso.date(from:))

        guard let intent = EditIntent(rawValue: payload.intent) else {
            throw LLMRuntimeError.invalidJSON
        }

        return EditOperation(
            expectedPlanRevision: expectedPlanRevision,
            intent: intent,
            target: EditTarget(
                ekEventID: payload.target.ekEventID,
                fuzzyTitle: payload.target.fuzzyTitle,
                dateLocal: payload.target.dateLocal
            ),
            time: EditTime(startLocal: start, endLocal: end),
            parameters: EditParameters(),
            requiresConfirmation: payload.requiresConfirmation,
            notes: payload.notes
        )
    }

    public func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        let activeTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }
        guard !activeTasks.isEmpty else {
            return SchedulePlan(blocks: [], feasibilityState: .onTrack, unscheduledTaskIDs: [])
        }

        let prompt = buildSchedulePrompt(
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )

        let raw = try await generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        let payload = try JSONDecoder().decode(SchedulePlanPayload.self, from: Data(json.utf8))
        return try materializeSchedulePlan(
            payload: payload,
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func generate(prompt: String) async throws -> String {
        let url = endpointURL.appendingPathComponent("/api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaGenerateRequest(model: model, prompt: prompt, stream: false)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMRuntimeError.missingResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw LLMRuntimeError.requestFailed(code: http.statusCode, body: responseBody)
        }

        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return decoded.response
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    private func extractJSONArray(from text: String) throws -> String {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else {
            throw LLMRuntimeError.invalidJSON
        }
        return String(text[start...end])
    }

    private func extractJSONObject(from text: String) throws -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            throw LLMRuntimeError.invalidJSON
        }
        return String(text[start...end])
    }

    private func parseDueDate(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}

public struct StubLLMRuntime: LLMRuntimeClient {
    public init() {}

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        updates.map { update in
            TaskItem(
                title: update.subject,
                category: .assignment,
                dueAtLocal: extractDueDate(from: "\(update.subject)\n\(update.bodyText)"),
                estimatedMinutes: 60,
                minDailyMinutes: 30,
                priority: 1,
                stressWeight: 0.5,
                sources: [
                    TaskSource(
                        source: update.source,
                        accountID: update.accountID,
                        messageID: update.providerIDs.messageID,
                        confidence: update.parseConfidence
                    )
                ]
            )
        }
    }

    public func inferSlackEdit(messageText: String, expectedPlanRevision: Int) async throws -> EditOperation {
        let normalized = messageText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("today") || normalized.hasPrefix("regenerate") {
            return EditOperation(
                expectedPlanRevision: expectedPlanRevision,
                intent: .regeneratePlan,
                target: EditTarget(),
                time: EditTime(),
                notes: "Regenerate today's plan"
            )
        }

        if normalized.hasPrefix("lock sleep") {
            return EditOperation(
                expectedPlanRevision: expectedPlanRevision,
                intent: .lockSleep,
                target: EditTarget(),
                time: EditTime(),
                parameters: EditParameters(sleepWindow: SleepWindow(start: "00:30", end: "08:00")),
                notes: "Lock sleep window"
            )
        }

        throw LLMRuntimeError.unsupportedPrompt
    }

    public func inferSchedulePlan(
        date: Date,
        tasks: [TaskItem],
        existingBlocks: [CalendarBlock],
        constraints: PlannerConstraints,
        planRevision: Int,
        timeZoneIdentifier: String
    ) async throws -> SchedulePlan {
        let activeTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }
        guard !activeTasks.isEmpty else {
            return SchedulePlan(blocks: [], feasibilityState: .onTrack, unscheduledTaskIDs: [])
        }

        guard let window = planningWindow(for: date, constraints: constraints, timeZoneIdentifier: timeZoneIdentifier) else {
            return SchedulePlan(
                blocks: [],
                feasibilityState: .infeasible,
                unscheduledTaskIDs: activeTasks.map(\.taskID)
            )
        }

        let blocked = existingBlocks.filter { $0.lockLevel == .locked || !$0.managedByAgent }
        let sortedTasks = activeTasks.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return ($0.dueAtLocal ?? .distantFuture) < ($1.dueAtLocal ?? .distantFuture)
        }

        var planned: [CalendarBlock] = []
        var unscheduled = Set<UUID>()
        var remainingCapacity = constraints.maxDeepWorkMinutesPerDay

        for task in sortedTasks {
            let requested = min(max(30, task.minDailyMinutes), max(30, task.estimatedMinutes))
            let duration = min(requested, remainingCapacity)
            guard duration >= 25 else {
                unscheduled.insert(task.taskID)
                continue
            }

            guard let (start, end) = nextAvailableSlot(
                startingAt: window.start,
                durationMinutes: duration,
                dayEnd: window.end,
                blocked: blocked + planned
            ) else {
                unscheduled.insert(task.taskID)
                continue
            }

            planned.append(
                CalendarBlock(
                    taskID: task.taskID,
                    title: "Deep Work: \(task.title)",
                    startLocal: start,
                    endLocal: end,
                    planRevision: planRevision
                )
            )
            remainingCapacity -= duration
        }

        let feasibility: FeasibilityState
        if unscheduled.isEmpty {
            feasibility = .onTrack
        } else if unscheduled.count >= activeTasks.count {
            feasibility = .infeasible
        } else {
            feasibility = .atRisk
        }

        return SchedulePlan(
            blocks: planned.sorted { $0.startLocal < $1.startLocal },
            feasibilityState: feasibility,
            unscheduledTaskIDs: Array(unscheduled)
        )
    }

    private func extractDueDate(from text: String) -> Date? {
        let pattern = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})(,\s*(\d{4}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let monthRange = Range(match.range(at: 1), in: text),
              let dayRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }

        let month = String(text[monthRange])
        let day = String(text[dayRange])
        let year: String
        if match.range(at: 4).location != NSNotFound,
           let yearRange = Range(match.range(at: 4), in: text) {
            year = String(text[yearRange])
        } else {
            year = String(Calendar.current.component(.year, from: Date()))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(month) \(day) \(year)")
    }
}

private struct PlanningWindow {
    let calendar: Calendar
    let start: Date
    let end: Date
}

private func planningWindow(for date: Date, constraints: PlannerConstraints, timeZoneIdentifier: String) -> PlanningWindow? {
    let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let startOfDay = calendar.startOfDay(for: date)
    guard
        let dayStart = calendar.date(bySettingHour: constraints.workdayStartHour24, minute: 0, second: 0, of: startOfDay),
        let dayEndRaw = calendar.date(bySettingHour: constraints.workdayEndHour24, minute: 0, second: 0, of: startOfDay),
        let cutoff = calendar.date(bySettingHour: constraints.avoidAfterHour24, minute: 0, second: 0, of: startOfDay)
    else {
        return nil
    }

    let dayEnd = min(dayEndRaw, cutoff)
    guard dayStart < dayEnd else {
        return nil
    }

    return PlanningWindow(calendar: calendar, start: dayStart, end: dayEnd)
}

private func buildSchedulePrompt(
    date: Date,
    tasks: [TaskItem],
    existingBlocks: [CalendarBlock],
    constraints: PlannerConstraints,
    planRevision: Int,
    timeZoneIdentifier: String
) -> String {
    let window = planningWindow(for: date, constraints: constraints, timeZoneIdentifier: timeZoneIdentifier)
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
    iso.formatOptions = [.withInternetDateTime]

    let taskPayloads: [[String: Any]] = tasks.map { task in
        [
            "task_id": task.taskID.uuidString,
            "title": task.title,
            "category": task.category.rawValue,
            "due_at_local": task.dueAtLocal.map { iso.string(from: $0) } ?? NSNull(),
            "estimated_minutes": task.estimatedMinutes,
            "min_daily_minutes": task.minDailyMinutes,
            "priority": task.priority,
            "stress_weight": task.stressWeight
        ]
    }

    let busyPayloads: [[String: Any]] = existingBlocks
        .filter { $0.lockLevel == .locked || !$0.managedByAgent }
        .map {
            [
                "title": $0.title,
                "start_local": iso.string(from: $0.startLocal),
                "end_local": iso.string(from: $0.endLocal),
                "lock_level": $0.lockLevel.rawValue,
                "managed_by_agent": $0.managedByAgent
            ]
        }

    let constraintsPayload: [String: Any] = [
        "time_zone": timeZoneIdentifier,
        "plan_revision": planRevision,
        "day_start_local": window.map { iso.string(from: $0.start) } ?? NSNull(),
        "day_end_local": window.map { iso.string(from: $0.end) } ?? NSNull(),
        "max_deep_work_minutes_per_day": constraints.maxDeepWorkMinutesPerDay,
        "break_every_minutes": constraints.breakEveryMinutes,
        "break_duration_minutes": constraints.breakDurationMinutes,
        "free_space_buffer_minutes": constraints.freeSpaceBufferMinutes
    ]

    return """
    You are a scheduling engine. Build a focused one-day schedule from tasks.
    Return ONLY valid JSON object matching this schema exactly:
    {
      "feasibility_state": "on_track|at_risk|infeasible",
      "unscheduled_task_ids": ["uuid", ...],
      "blocks": [
        {
          "task_id": "uuid or null",
          "title": "string",
          "start_local": "ISO-8601 datetime",
          "end_local": "ISO-8601 datetime",
          "lock_level": "flexible|locked"
        }
      ]
    }
    Rules:
    - Schedule only within day_start_local/day_end_local.
    - Do not overlap with busy blocks.
    - Do not overlap generated blocks with each other.
    - Prioritize urgent/high-priority tasks first.
    - Split long work across multiple blocks if needed.
    - Use lock_level=\"flexible\" for generated work unless absolutely required.
    - Do not include markdown.

    Constraints JSON:
    \(scheduleJSONString(constraintsPayload))

    Tasks JSON:
    \(scheduleJSONString(taskPayloads))

    Busy blocks JSON:
    \(scheduleJSONString(busyPayloads))
    """
}

private func materializeSchedulePlan(
    payload: SchedulePlanPayload,
    date: Date,
    tasks: [TaskItem],
    existingBlocks: [CalendarBlock],
    constraints: PlannerConstraints,
    planRevision: Int,
    timeZoneIdentifier: String
) throws -> SchedulePlan {
    guard let window = planningWindow(for: date, constraints: constraints, timeZoneIdentifier: timeZoneIdentifier) else {
        throw LLMRuntimeError.invalidJSON
    }

    let activeTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }
    let activeTaskByID = Dictionary(uniqueKeysWithValues: activeTasks.map { ($0.taskID, $0) })
    let activeTaskIDs = Set(activeTaskByID.keys)
    let busyBlocks = existingBlocks.filter { $0.lockLevel == .locked || !$0.managedByAgent }

    let parsedCandidates = payload.blocks.compactMap { block -> (payload: ScheduleBlockPayload, start: Date, end: Date)? in
        guard
            let start = parseScheduleDate(block.startLocal, timeZone: window.calendar.timeZone),
            let end = parseScheduleDate(block.endLocal, timeZone: window.calendar.timeZone),
            start < end
        else {
            return nil
        }
        return (block, start, end)
    }
    .sorted { $0.start < $1.start }

    var normalizedBlocks: [CalendarBlock] = []
    var totalScheduledMinutes = 0

    for candidate in parsedCandidates {
        let durationMinutes = max(0, Int(candidate.end.timeIntervalSince(candidate.start) / 60.0))
        guard durationMinutes >= 25 else { continue }
        guard candidate.start >= window.start, candidate.end <= window.end else { continue }
        guard totalScheduledMinutes + durationMinutes <= constraints.maxDeepWorkMinutesPerDay else { continue }
        guard !intervalOverlaps(candidate.start, candidate.end, blocks: busyBlocks) else { continue }
        guard !intervalOverlaps(candidate.start, candidate.end, blocks: normalizedBlocks) else { continue }

        let resolvedTaskID: UUID?
        if let rawTaskID = candidate.payload.taskID,
           let parsed = UUID(uuidString: rawTaskID),
           activeTaskIDs.contains(parsed) {
            resolvedTaskID = parsed
        } else {
            resolvedTaskID = nil
        }

        let title: String
        let trimmedTitle = candidate.payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        } else if let resolvedTaskID, let task = activeTaskByID[resolvedTaskID] {
            title = "Deep Work: \(task.title)"
        } else {
            title = "Deep Work"
        }

        normalizedBlocks.append(
            CalendarBlock(
                taskID: resolvedTaskID,
                title: title,
                startLocal: candidate.start,
                endLocal: candidate.end,
                lockLevel: candidate.payload.lockLevel ?? .flexible,
                planRevision: planRevision
            )
        )
        totalScheduledMinutes += durationMinutes
    }

    let scheduledTaskIDs = Set(normalizedBlocks.compactMap(\.taskID))
    var unscheduledTaskIDs = Set(
        (payload.unscheduledTaskIDs ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter { activeTaskIDs.contains($0) }
    )
    for taskID in activeTaskIDs where !scheduledTaskIDs.contains(taskID) {
        unscheduledTaskIDs.insert(taskID)
    }

    let feasibility: FeasibilityState
    if let provided = payload.feasibilityState {
        feasibility = provided
    } else if unscheduledTaskIDs.isEmpty {
        feasibility = .onTrack
    } else if unscheduledTaskIDs.count >= activeTaskIDs.count {
        feasibility = .infeasible
    } else {
        feasibility = .atRisk
    }

    return SchedulePlan(
        blocks: normalizedBlocks.sorted { $0.startLocal < $1.startLocal },
        feasibilityState: feasibility,
        unscheduledTaskIDs: Array(unscheduledTaskIDs)
    )
}

private func parseScheduleDate(_ value: String, timeZone: TimeZone) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) {
        return date
    }

    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) {
        return date
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }

    return nil
}

private func intervalOverlaps(_ start: Date, _ end: Date, blocks: [CalendarBlock]) -> Bool {
    blocks.contains { block in
        max(start, block.startLocal) < min(end, block.endLocal)
    }
}

private func nextAvailableSlot(
    startingAt: Date,
    durationMinutes: Int,
    dayEnd: Date,
    blocked: [CalendarBlock]
) -> (Date, Date)? {
    let duration = TimeInterval(max(0, durationMinutes) * 60)
    guard duration > 0 else { return nil }

    let sortedBlocked = blocked.sorted { $0.startLocal < $1.startLocal }
    var cursor = startingAt

    for block in sortedBlocked {
        if block.endLocal <= cursor {
            continue
        }

        if block.startLocal > cursor {
            let candidateEnd = cursor.addingTimeInterval(duration)
            if candidateEnd <= min(block.startLocal, dayEnd) {
                return (cursor, candidateEnd)
            }
        }

        cursor = max(cursor, block.endLocal)
        if cursor >= dayEnd {
            return nil
        }
    }

    let end = cursor.addingTimeInterval(duration)
    guard end <= dayEnd else {
        return nil
    }
    return (cursor, end)
}

private func scheduleJSONString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return text
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct ONNXRunnerRequest: Encodable {
    let modelPath: String
    let prompt: String
    let maxNewTokens: Int
    let temperature: Double
    let topP: Double
    let provider: String?

    enum CodingKeys: String, CodingKey {
        case modelPath = "model_path"
        case prompt
        case maxNewTokens = "max_new_tokens"
        case temperature
        case topP = "top_p"
        case provider
    }
}

private struct ONNXRunnerResponse: Decodable {
    let text: String
}

private struct ExtractedTaskPayload: Decodable {
    let sourceMessageID: String?
    let title: String
    let category: TaskCategory
    let dueAtLocal: String?
    let estimatedMinutes: Int
    let minDailyMinutes: Int
    let priority: Int
    let stressWeight: Double
    let status: TaskStatus

    enum CodingKeys: String, CodingKey {
        case sourceMessageID = "source_message_id"
        case title
        case category
        case dueAtLocal = "due_at_local"
        case estimatedMinutes = "estimated_minutes"
        case minDailyMinutes = "min_daily_minutes"
        case priority
        case stressWeight = "stress_weight"
        case status
    }
}

private struct SchedulePlanPayload: Decodable {
    let feasibilityState: FeasibilityState?
    let unscheduledTaskIDs: [String]?
    let blocks: [ScheduleBlockPayload]

    enum CodingKeys: String, CodingKey {
        case feasibilityState = "feasibility_state"
        case unscheduledTaskIDs = "unscheduled_task_ids"
        case blocks
    }
}

private struct ScheduleBlockPayload: Decodable {
    let taskID: String?
    let title: String
    let startLocal: String
    let endLocal: String
    let lockLevel: BlockLockLevel?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case title
        case startLocal = "start_local"
        case endLocal = "end_local"
        case lockLevel = "lock_level"
    }
}

private struct SlackEditPayload: Decodable {
    struct Target: Decodable {
        let ekEventID: String?
        let fuzzyTitle: String?
        let dateLocal: String?

        enum CodingKeys: String, CodingKey {
            case ekEventID = "ek_event_id"
            case fuzzyTitle = "fuzzy_title"
            case dateLocal = "date_local"
        }
    }

    struct Time: Decodable {
        let startLocal: String?
        let endLocal: String?

        enum CodingKeys: String, CodingKey {
            case startLocal = "start_local"
            case endLocal = "end_local"
        }
    }

    let intent: String
    let target: Target
    let time: Time
    let requiresConfirmation: Bool
    let notes: String

    enum CodingKeys: String, CodingKey {
        case intent
        case target
        case time
        case requiresConfirmation = "requires_confirmation"
        case notes
    }
}
