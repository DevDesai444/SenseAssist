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
    private let plannerInputFilePath: String?

    public init(
        modelPath: String,
        runnerScriptPath: String,
        pythonExecutable: String = "/usr/bin/python3",
        maxNewTokens: Int = 512,
        temperature: Double = 0.2,
        topP: Double = 0.95,
        provider: String? = nil,
        plannerInputFilePath: String? = nil
    ) {
        self.modelPath = modelPath
        self.runnerScriptPath = runnerScriptPath
        self.pythonExecutable = pythonExecutable
        self.maxNewTokens = max(64, maxNewTokens)
        self.temperature = max(0.0, temperature)
        self.topP = min(max(topP, 0.0), 1.0)
        self.provider = provider
        self.plannerInputFilePath = plannerInputFilePath
    }

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        if updates.isEmpty {
            return []
        }

        let basePrompt = buildTaskExtractionPrompt(updates: updates)
        var prompt = basePrompt
        var decoded: [ExtractedTaskPayload] = []
        var lastRawOutput = ""
        var lastError: Error?

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                let raw = try generate(prompt: prompt)
                lastRawOutput = raw
                let json = try extractJSONArray(from: raw)
                decoded = try JSONDecoder().decode([ExtractedTaskPayload].self, from: Data(json.utf8))
                lastError = nil
                break
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }
                prompt = buildExtractionRepairPrompt(
                    basePrompt: basePrompt,
                    previousOutput: lastRawOutput,
                    errorDescription: error.localizedDescription
                )
            }
        }

        if let lastError {
            throw lastError
        }

        let updateByMessageID = Dictionary(uniqueKeysWithValues: updates.map { ($0.providerIDs.messageID, $0) })

        var mapped = decoded.compactMap { payload -> ExtractedTaskCandidate? in
            guard let sourceUpdate = payload.sourceMessageID.flatMap({ updateByMessageID[$0] }) ?? updates.first else {
                return nil
            }

            let dueFromLLM = parseDueDate(payload.dueAtLocal)
            let dueFromEvidence = parseDueDateFromEvidence(sourceUpdate.evidence, referenceDate: sourceUpdate.receivedAtUTC)
            return ExtractedTaskCandidate(
                payload: payload,
                sourceUpdate: sourceUpdate,
                dueAtLocal: dueFromLLM ?? dueFromEvidence
            )
        }

        let unresolved = mapped.filter {
            $0.dueAtLocal == nil && requiresDueDate(category: $0.payload.category)
        }
        if !unresolved.isEmpty {
            let repaired = try repairDueDates(for: unresolved.map(\.sourceUpdate))
            for index in mapped.indices {
                guard mapped[index].dueAtLocal == nil else { continue }
                let messageID = mapped[index].sourceUpdate.providerIDs.messageID
                guard let repairedValue = repaired[messageID] else { continue }
                mapped[index].dueAtLocal = parseDueDate(repairedValue)
            }
        }

        return mapped.map { candidate in
            let normalized = normalizeSchedulingFields(
                category: candidate.payload.category,
                estimatedMinutes: candidate.payload.estimatedMinutes,
                minDailyMinutes: candidate.payload.minDailyMinutes,
                priority: candidate.payload.priority,
                dueAtLocal: candidate.dueAtLocal,
                now: Date()
            )

            return TaskItem(
                title: candidate.payload.title,
                category: candidate.payload.category,
                dueAtLocal: candidate.dueAtLocal,
                estimatedMinutes: normalized.estimatedMinutes,
                minDailyMinutes: normalized.minDailyMinutes,
                priority: normalized.priority,
                stressWeight: min(max(candidate.payload.stressWeight, 0.0), 1.0),
                sources: [
                    TaskSource(
                        source: candidate.sourceUpdate.source,
                        accountID: candidate.sourceUpdate.accountID,
                        messageID: candidate.sourceUpdate.providerIDs.messageID,
                        confidence: min(max(candidate.sourceUpdate.parseConfidence, 0.0), 1.0)
                    )
                ],
                status: candidate.payload.status
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

        let basePrompt = buildSchedulePrompt(
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier,
            plannerInputFileContext: plannerInputContext(
                preferredPath: plannerInputFilePath,
                fallbackPath: ProcessInfo.processInfo.environment["SENSEASSIST_PLANNER_INPUT_PATH"]
            )
        )
        var prompt = basePrompt
        var lastRawOutput = ""
        var lastError: Error?

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                let raw = try generate(prompt: prompt)
                lastRawOutput = raw
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
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }
                prompt = buildScheduleRepairPrompt(
                    basePrompt: basePrompt,
                    previousOutput: lastRawOutput,
                    errorDescription: error.localizedDescription
                )
            }
        }

        throw lastError ?? LLMRuntimeError.invalidJSON
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
        parseLLMDueDate(value)
    }

    private func repairDueDates(for updates: [UpdateCard]) throws -> [String: String] {
        guard !updates.isEmpty else {
            return [:]
        }

        let prompt = buildDueDateRepairPrompt(updates: updates)
        let raw = try generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        return try decodeDueDateRepairMap(json: json)
    }
}

public struct OllamaLLMRuntime: LLMRuntimeClient {
    private let endpointURL: URL
    private let model: String
    private let session: URLSession
    private let plannerInputFilePath: String?

    public init(
        endpointURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String,
        session: URLSession = .shared,
        plannerInputFilePath: String? = nil
    ) {
        self.endpointURL = endpointURL
        self.model = model
        self.session = session
        self.plannerInputFilePath = plannerInputFilePath
    }

    public func inferExtractTasks(from updates: [UpdateCard]) async throws -> [TaskItem] {
        if updates.isEmpty {
            return []
        }

        let basePrompt = buildTaskExtractionPrompt(updates: updates)
        var prompt = basePrompt
        var decoded: [ExtractedTaskPayload] = []
        var lastRawOutput = ""
        var lastError: Error?

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                let raw = try await generate(prompt: prompt)
                lastRawOutput = raw
                let json = try extractJSONArray(from: raw)
                decoded = try JSONDecoder().decode([ExtractedTaskPayload].self, from: Data(json.utf8))
                lastError = nil
                break
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }
                prompt = buildExtractionRepairPrompt(
                    basePrompt: basePrompt,
                    previousOutput: lastRawOutput,
                    errorDescription: error.localizedDescription
                )
            }
        }

        if let lastError {
            throw lastError
        }

        let updateByMessageID = Dictionary(uniqueKeysWithValues: updates.map { ($0.providerIDs.messageID, $0) })

        var mapped = decoded.compactMap { payload -> ExtractedTaskCandidate? in
            guard let sourceUpdate = payload.sourceMessageID.flatMap({ updateByMessageID[$0] }) ?? updates.first else {
                return nil
            }

            let dueFromLLM = parseDueDate(payload.dueAtLocal)
            let dueFromEvidence = parseDueDateFromEvidence(sourceUpdate.evidence, referenceDate: sourceUpdate.receivedAtUTC)
            return ExtractedTaskCandidate(
                payload: payload,
                sourceUpdate: sourceUpdate,
                dueAtLocal: dueFromLLM ?? dueFromEvidence
            )
        }

        let unresolved = mapped.filter {
            $0.dueAtLocal == nil && requiresDueDate(category: $0.payload.category)
        }
        if !unresolved.isEmpty {
            let repaired = try await repairDueDates(for: unresolved.map(\.sourceUpdate))
            for index in mapped.indices {
                guard mapped[index].dueAtLocal == nil else { continue }
                let messageID = mapped[index].sourceUpdate.providerIDs.messageID
                guard let repairedValue = repaired[messageID] else { continue }
                mapped[index].dueAtLocal = parseDueDate(repairedValue)
            }
        }

        return mapped.map { candidate in
            let normalized = normalizeSchedulingFields(
                category: candidate.payload.category,
                estimatedMinutes: candidate.payload.estimatedMinutes,
                minDailyMinutes: candidate.payload.minDailyMinutes,
                priority: candidate.payload.priority,
                dueAtLocal: candidate.dueAtLocal,
                now: Date()
            )

            return TaskItem(
                title: candidate.payload.title,
                category: candidate.payload.category,
                dueAtLocal: candidate.dueAtLocal,
                estimatedMinutes: normalized.estimatedMinutes,
                minDailyMinutes: normalized.minDailyMinutes,
                priority: normalized.priority,
                stressWeight: min(max(candidate.payload.stressWeight, 0.0), 1.0),
                sources: [
                    TaskSource(
                        source: candidate.sourceUpdate.source,
                        accountID: candidate.sourceUpdate.accountID,
                        messageID: candidate.sourceUpdate.providerIDs.messageID,
                        confidence: min(max(candidate.sourceUpdate.parseConfidence, 0.0), 1.0)
                    )
                ],
                status: candidate.payload.status
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

        let basePrompt = buildSchedulePrompt(
            date: date,
            tasks: activeTasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier,
            plannerInputFileContext: plannerInputContext(
                preferredPath: plannerInputFilePath,
                fallbackPath: ProcessInfo.processInfo.environment["SENSEASSIST_PLANNER_INPUT_PATH"]
            )
        )
        var prompt = basePrompt
        var lastRawOutput = ""
        var lastError: Error?

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                let raw = try await generate(prompt: prompt)
                lastRawOutput = raw
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
            } catch {
                lastError = error
                guard attempt < maxAttempts else {
                    throw error
                }
                prompt = buildScheduleRepairPrompt(
                    basePrompt: basePrompt,
                    previousOutput: lastRawOutput,
                    errorDescription: error.localizedDescription
                )
            }
        }

        throw lastError ?? LLMRuntimeError.invalidJSON
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
        parseLLMDueDate(value)
    }

    private func repairDueDates(for updates: [UpdateCard]) async throws -> [String: String] {
        guard !updates.isEmpty else {
            return [:]
        }

        let prompt = buildDueDateRepairPrompt(updates: updates)
        let raw = try await generate(prompt: prompt)
        let json = try extractJSONObject(from: raw)
        return try decodeDueDateRepairMap(json: json)
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

private struct PlannerInputFileContext {
    let path: String
    let snapshot: PlannerInputSnapshot
    let rawJSON: String
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
    timeZoneIdentifier: String,
    plannerInputFileContext: PlannerInputFileContext?
) -> String {
    let window = planningWindow(for: date, constraints: constraints, timeZoneIdentifier: timeZoneIdentifier)
    let scheduleCalendar: Calendar = {
        if let window {
            return window.calendar
        }
        var fallback = Calendar(identifier: .gregorian)
        fallback.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
        return fallback
    }()
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
    iso.formatOptions = [.withInternetDateTime]

    let taskPayloads: [[String: Any]] = tasks.map { task in
        let daysUntilDue = task.dueAtLocal.map {
            max(
                0,
                scheduleCalendar.dateComponents(
                    [.day],
                    from: scheduleCalendar.startOfDay(for: date),
                    to: scheduleCalendar.startOfDay(for: $0)
                ).day ?? 0
            )
        }
        let isLargeAssignment = (task.category == .assignment || task.category == .project) && task.estimatedMinutes >= 180
        let shouldDeferUntilDayBeforeDue = shouldDeferSmallNearDueTask(task: task, planningDate: date, calendar: scheduleCalendar)

        return [
            "task_id": task.taskID.uuidString,
            "title": task.title,
            "category": task.category.rawValue,
            "due_at_local": task.dueAtLocal.map { iso.string(from: $0) } ?? NSNull(),
            "estimated_minutes": task.estimatedMinutes,
            "min_daily_minutes": task.minDailyMinutes,
            "priority": task.priority,
            "stress_weight": task.stressWeight,
            "days_until_due": daysUntilDue ?? NSNull(),
            "is_large_assignment": isLargeAssignment,
            "should_defer_until_day_before_due": shouldDeferUntilDayBeforeDue
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

    let plannerFileSection: String
    let tasksSection: String
    let busyBlocksSection: String
    if let plannerInputFileContext {
        plannerFileSection = """
        Planner input file path:
        \(plannerInputFileContext.path)

        Planner input file summary:
        tasks=\(plannerInputFileContext.snapshot.tasks.count) busy_blocks=\(plannerInputFileContext.snapshot.busyBlocks.count) plan_revision=\(plannerInputFileContext.snapshot.meta.planRevision)

        Planner input file JSON (source of truth):
        \(plannerInputFileContext.rawJSON)
        """
        tasksSection = "Tasks JSON omitted because planner_input JSON above is the source of truth."
        busyBlocksSection = "Busy blocks JSON omitted because planner_input JSON above is the source of truth."
    } else {
        plannerFileSection = "Planner input file JSON is unavailable for this run."
        tasksSection = scheduleJSONString(taskPayloads)
        busyBlocksSection = scheduleJSONString(busyPayloads)
    }

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
    - If a task is short (estimated_minutes <= 90) and due in 2 days, prefer scheduling on the day before due date.
    - If a task is large (estimated_minutes >= 180), allocate at least min_daily_minutes today when feasible.
    - Example policy: if today is March 3, a short task due March 5 can be planned for March 4, while a large March 15 assignment still gets progress on March 3 and onward.
    - Split long work across multiple blocks if needed.
    - Use lock_level=\"flexible\" for generated work unless absolutely required.
    - Do not include markdown.

    Constraints JSON:
    \(scheduleJSONString(constraintsPayload))

    \(plannerFileSection)

    Tasks JSON:
    \(tasksSection)

    Busy blocks JSON:
    \(busyBlocksSection)
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
    let deferredTaskIDs = Set(
        activeTasks
            .filter { shouldDeferSmallNearDueTask(task: $0, planningDate: date, calendar: window.calendar) }
            .map(\.taskID)
    )
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

        if let resolvedTaskID, deferredTaskIDs.contains(resolvedTaskID) {
            continue
        }

        let title: String
        let trimmedTitle = candidate.payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedTaskID == nil, !trimmedTitle.isEmpty {
            let normalizedTitle = trimmedTitle.lowercased()
            let matchesDeferredTitle = activeTasks.contains { task in
                deferredTaskIDs.contains(task.taskID) && normalizedTitle.contains(task.title.lowercased())
            }
            if matchesDeferredTitle {
                continue
            }
        }
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

private func plannerInputContext(preferredPath: String?, fallbackPath: String?) -> PlannerInputFileContext? {
    let candidatePaths = [preferredPath, fallbackPath]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    for rawPath in candidatePaths {
        let path = (rawPath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: path)

        guard let data = try? Data(contentsOf: fileURL)
        else {
            continue
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(PlannerInputSnapshot.self, from: data) else {
            continue
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let compactData = try? encoder.encode(snapshot),
              let compactRawJSON = String(data: compactData, encoding: .utf8)
        else {
            continue
        }

        return PlannerInputFileContext(path: path, snapshot: snapshot, rawJSON: compactRawJSON)
    }

    return nil
}

private struct ExtractedTaskCandidate {
    var payload: ExtractedTaskPayload
    var sourceUpdate: UpdateCard
    var dueAtLocal: Date?
}

private struct DueDateRepairEnvelope: Decodable {
    let dueDates: [String: String?]

    enum CodingKeys: String, CodingKey {
        case dueDates = "due_dates"
    }
}

private func extractionJSONString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return text
}

private func buildTaskExtractionPrompt(updates: [UpdateCard]) -> String {
    let iso = ISO8601DateFormatter()
    let simplifiedUpdates = updates.map { update in
        [
            "account_id": update.accountID,
            "source": update.source.rawValue,
            "message_id": update.providerIDs.messageID,
            "received_at_utc": iso.string(from: update.receivedAtUTC),
            "subject": update.subject,
            "body_text": String(update.bodyText.prefix(4000)),
            "tags": update.tags,
            "evidence": update.evidence,
            "parse_confidence": update.parseConfidence,
            "requires_confirmation": update.requiresConfirmation
        ] as [String: Any]
    }

    return """
    You are an extraction engine. Convert academic email updates into actionable tasks.
    Return ONLY valid JSON array matching this schema exactly:
    [
      {
        "source_message_id": "string",
        "title": "string",
        "category": "assignment|quiz|email_reply|application|leetcode|project|admin",
        "due_at_local": "ISO-8601 datetime string with timezone offset or null",
        "estimated_minutes": number,
        "min_daily_minutes": number,
        "priority": number,
        "stress_weight": number,
        "status": "todo|in_progress|done|ignored"
      }
    ]
    Requirements:
    - Capture due dates for assignments/quizzes/applications whenever present.
    - estimated_minutes must reflect total remaining effort.
    - min_daily_minutes must reflect consistent daily progress for large work.
    - For large assignments (estimated_minutes >= 180), choose meaningful min_daily_minutes, not tiny values.
    - For short near-due work (estimated_minutes <= 90 and due soon), keep min_daily_minutes realistic.
    - source_message_id must match an input message_id.
    - Do not include markdown.

    Updates JSON:
    \(extractionJSONString(simplifiedUpdates))
    """
}

private func buildDueDateRepairPrompt(updates: [UpdateCard]) -> String {
    let payload: [[String: Any]] = updates.map { update in
        [
            "message_id": update.providerIDs.messageID,
            "subject": update.subject,
            "body_text": String(update.bodyText.prefix(2500)),
            "evidence": update.evidence
        ]
    }

    return """
    You repair missing due dates for extracted academic tasks.
    Return ONLY valid JSON object in one of these exact forms:
    {"m1":"ISO-8601 datetime or null","m2":"ISO-8601 datetime or null"}
    or
    {"due_dates":{"m1":"ISO-8601 datetime or null","m2":"ISO-8601 datetime or null"}}
    Rules:
    - Keys must be message_id values from the input.
    - Value must be ISO-8601 datetime with timezone offset when inferable, otherwise null.
    - Do not include markdown.

    Input JSON:
    \(extractionJSONString(payload))
    """
}

private func buildExtractionRepairPrompt(
    basePrompt: String,
    previousOutput: String,
    errorDescription: String
) -> String {
    let outputSnippet = String(previousOutput.suffix(8000))
    let safeError = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    Your previous extraction output was invalid. Repair it now.
    Return ONLY valid JSON array for the exact schema in the base instructions.
    Do not include markdown.

    Validation/Error context:
    \(safeError)

    Previous output:
    \(outputSnippet)

    Base instructions:
    \(basePrompt)
    """
}

private func buildScheduleRepairPrompt(
    basePrompt: String,
    previousOutput: String,
    errorDescription: String
) -> String {
    let outputSnippet = String(previousOutput.suffix(8000))
    let safeError = errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    Your previous schedule output was invalid. Repair it now.
    Return ONLY valid JSON object for the exact schema in the base instructions.
    Keep all blocks non-overlapping and within day bounds.
    Do not include markdown.

    Validation/Error context:
    \(safeError)

    Previous output:
    \(outputSnippet)

    Base instructions:
    \(basePrompt)
    """
}

private func decodeDueDateRepairMap(json: String) throws -> [String: String] {
    guard let data = json.data(using: .utf8) else {
        throw LLMRuntimeError.invalidJSON
    }

    if let direct = try? JSONDecoder().decode([String: String?].self, from: data) {
        return direct.compactMapValues { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    if let wrapped = try? JSONDecoder().decode(DueDateRepairEnvelope.self, from: data) {
        return wrapped.dueDates.compactMapValues { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    throw LLMRuntimeError.invalidJSON
}

private func requiresDueDate(category: TaskCategory) -> Bool {
    category == .assignment || category == .quiz || category == .application
}

private func parseLLMDueDate(_ value: String?) -> Date? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

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
    formatter.timeZone = TimeZone.current
    for format in [
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
        "MMM d yyyy h:mma",
        "MMMM d yyyy h:mma",
        "MMM d yyyy",
        "MMMM d yyyy"
    ] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }

    return parseLooseDueDate(value, referenceDate: Date())
}

private func parseDueDateFromEvidence(_ evidence: [String], referenceDate: Date) -> Date? {
    guard let dueEvidence = evidence.first(where: { $0.lowercased().hasPrefix("due_date:") }) else {
        return nil
    }

    let dueText = String(dueEvidence.dropFirst("due_date:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !dueText.isEmpty else {
        return nil
    }

    return parseLooseDueDate(dueText, referenceDate: referenceDate)
}

private func parseLooseDueDate(_ text: String, referenceDate: Date) -> Date? {
    let pattern = #"(?i)(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+(\d{1,2})(?:,\s*(\d{4}))?(?:\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    else {
        return nil
    }

    func capture(_ group: Int) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }

    guard let monthText = capture(1), let dayText = capture(2), let day = Int(dayText) else {
        return nil
    }

    let calendar = Calendar.current
    let referenceYear = calendar.component(.year, from: referenceDate)
    let year = capture(3).flatMap(Int.init) ?? referenceYear
    let monthFormatter = DateFormatter()
    monthFormatter.locale = Locale(identifier: "en_US_POSIX")
    monthFormatter.dateFormat = "MMM"
    let normalizedMonth = String(monthText.prefix(3)).capitalized
    guard let monthDate = monthFormatter.date(from: normalizedMonth) else {
        return nil
    }
    let month = calendar.component(.month, from: monthDate)

    var hour = capture(4).flatMap(Int.init) ?? 23
    let minute = capture(5).flatMap(Int.init) ?? (capture(4) == nil ? 59 : 0)
    if let ampm = capture(6)?.lowercased() {
        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }
    }

    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = min(max(0, hour), 23)
    components.minute = min(max(0, minute), 59)
    components.second = 0
    components.timeZone = TimeZone.current

    guard var parsed = calendar.date(from: components) else {
        return nil
    }

    if capture(3) == nil, parsed < referenceDate.addingTimeInterval(-48 * 3600),
       let nextYear = calendar.date(byAdding: .year, value: 1, to: parsed) {
        parsed = nextYear
    }

    return parsed
}

private func normalizeSchedulingFields(
    category: TaskCategory,
    estimatedMinutes: Int,
    minDailyMinutes: Int,
    priority: Int,
    dueAtLocal: Date?,
    now: Date
) -> (estimatedMinutes: Int, minDailyMinutes: Int, priority: Int) {
    var estimated = max(15, estimatedMinutes)
    var dailyMinimum = max(15, minDailyMinutes)
    var normalizedPriority = max(1, priority)

    let isLargeWork = (category == .assignment || category == .project) && estimated >= 180
    if isLargeWork {
        normalizedPriority = max(normalizedPriority, 3)
        dailyMinimum = max(dailyMinimum, 30)
    }

    if let dueAtLocal {
        let calendar = Calendar.current
        let daysUntilDue = max(
            0,
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: dueAtLocal)
            ).day ?? 0
        )

        if daysUntilDue <= 1 {
            normalizedPriority = max(normalizedPriority, 5)
            dailyMinimum = max(dailyMinimum, min(estimated, max(45, estimated / 2)))
        } else if daysUntilDue <= 2 {
            normalizedPriority = max(normalizedPriority, 4)
        }

        if isLargeWork {
            let spreadDays = max(1, daysUntilDue + 1)
            let recommendedDaily = Int(ceil(Double(estimated) / Double(spreadDays)))
            dailyMinimum = max(dailyMinimum, min(180, max(30, recommendedDaily)))
        }

        // Keep short near-due tasks realistic so they can land day-before-due.
        if (category == .assignment || category == .quiz), estimated <= 90, daysUntilDue == 2 {
            dailyMinimum = min(dailyMinimum, 45)
        }
    }

    estimated = max(15, estimated)
    dailyMinimum = max(15, min(dailyMinimum, estimated))
    return (estimated, dailyMinimum, normalizedPriority)
}

private func shouldDeferSmallNearDueTask(task: TaskItem, planningDate: Date, calendar: Calendar) -> Bool {
    guard task.category == .assignment || task.category == .quiz else {
        return false
    }
    guard task.estimatedMinutes <= 90, let dueAtLocal = task.dueAtLocal else {
        return false
    }

    let planningStart = calendar.startOfDay(for: planningDate)
    let dueStart = calendar.startOfDay(for: dueAtLocal)
    let daysUntilDue = max(0, calendar.dateComponents([.day], from: planningStart, to: dueStart).day ?? 0)
    return daysUntilDue == 2
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
