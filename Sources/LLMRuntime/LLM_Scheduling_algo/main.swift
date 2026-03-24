import CoreContracts
import Foundation
import LLMRuntime
import Planner

private enum SimulatorError: Error, LocalizedError {
    case usage(String)
    case inputNotFound
    case invalidInput(String)
    case missingEnvironment(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            return message
        case .inputNotFound:
            return "No input file found. Provide --input <path> or create an input.* file."
        case let .invalidInput(message):
            return "Invalid input: \(message)"
        case let .missingEnvironment(message):
            return "Missing configuration: \(message)"
        }
    }
}

private enum SchedulerMode: String {
    case stub
    case planner
    case onnx
    case ollama
}

private struct SchedulingSimInputEnvelope: Decodable {
    var timeZone: String?
    var constraints: SchedulingSimConstraints?
    var tasks: [SchedulingSimTask]
    var busyBlocks: [SchedulingSimBusyBlock]?

    enum CodingKeys: String, CodingKey {
        case timeZone = "time_zone"
        case constraints
        case tasks
        case busyBlocks = "busy_blocks"
    }
}

private struct SchedulingSimConstraints: Decodable {
    var workdayStartHour24: Int?
    var workdayEndHour24: Int?
    var sleepStart: String?
    var sleepEnd: String?
    var maxDeepWorkMinutesPerDay: Int?
    var breakEveryMinutes: Int?
    var breakDurationMinutes: Int?
    var avoidAfterHour24: Int?
    var freeSpaceBufferMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case workdayStartHour24 = "workday_start_hour24"
        case workdayEndHour24 = "workday_end_hour24"
        case sleepStart = "sleep_start"
        case sleepEnd = "sleep_end"
        case maxDeepWorkMinutesPerDay = "max_deep_work_minutes_per_day"
        case breakEveryMinutes = "break_every_minutes"
        case breakDurationMinutes = "break_duration_minutes"
        case avoidAfterHour24 = "avoid_after_hour24"
        case freeSpaceBufferMinutes = "free_space_buffer_minutes"
    }
}

private struct SchedulingSimTask: Decodable {
    var taskID: String?
    var title: String
    var category: String?
    var dueAtLocal: String?
    var estimatedMinutes: Int?
    var minDailyMinutes: Int?
    var priority: Int?
    var stressWeight: Double?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
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

private struct SchedulingSimBusyBlock: Decodable {
    var title: String
    var startLocal: String
    var endLocal: String
    var lockLevel: String?
    var managedByAgent: Bool?

    enum CodingKeys: String, CodingKey {
        case title
        case startLocal = "start_local"
        case endLocal = "end_local"
        case lockLevel = "lock_level"
        case managedByAgent = "managed_by_agent"
    }
}

@main
struct SenseAssistScheduleSim {
    static func main() async {
        do {
            let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let now = Date()

            let inputPath = try resolveInputPath(explicit: options.inputPath)
            let loaded = try loadInput(from: inputPath)
            let timeZoneIdentifier = options.timeZoneOverride ?? loaded.timeZone ?? TimeZone.current.identifier

            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw SimulatorError.invalidInput("Unknown time zone identifier: \(timeZoneIdentifier)")
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            var constraints = PlannerConstraints()
            if let inputConstraints = loaded.constraints {
                apply(inputConstraints, to: &constraints)
            }

            let tasks = try loaded.tasks.map { try mapTask($0, timeZone: timeZone) }
            var existingBlocks = try (loaded.busyBlocks ?? []).compactMap { try mapBusyBlock($0, timeZone: timeZone) }

            let planRevision = 1

            let planning = computePlanningDate(now: now, constraints: constraints, calendar: calendar)
            if let pastBlock = buildPastBusyBlock(
                now: now,
                planningDate: planning.date,
                window: planning.window,
                calendar: calendar,
                planRevision: planRevision
            ) {
                existingBlocks.append(pastBlock)
            }

            fputs(
                "senseassist-schedule-sim: running scheduler=\(options.schedulerMode.rawValue) tasks=\(tasks.count) time_zone=\(timeZone.identifier)\n",
                stderr
            )
            if options.schedulerMode == .onnx {
                fputs("senseassist-schedule-sim: note: first ONNX run may take a few minutes (model load + generation)\n", stderr)
            }
            let schedulerStartedAt = Date()
            let plan = try await runScheduler(
                mode: options.schedulerMode,
                now: now,
                planningDate: planning.date,
                tasks: tasks,
                existingBlocks: existingBlocks,
                constraints: constraints,
                planRevision: planRevision,
                timeZoneIdentifier: timeZoneIdentifier,
                ollamaModel: options.ollamaModel,
                ollamaEndpoint: options.ollamaEndpoint,
                onnxModelPath: options.onnxModelPath,
                onnxRunnerPath: options.onnxRunnerPath,
                onnxPythonPath: options.onnxPythonPath
            )
            let elapsed = Date().timeIntervalSince(schedulerStartedAt)
            fputs(String(format: "senseassist-schedule-sim: scheduler finished in %.2fs\n", elapsed), stderr)

            printPlan(
                plan: plan,
                tasks: tasks,
                now: now,
                planning: planning,
                constraints: constraints,
                timeZone: timeZone,
                mode: options.schedulerMode,
                inputPath: inputPath
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fputs("error: \(message)\n", stderr)
            if case SimulatorError.usage = error {
                // usage already includes help text
            } else {
                fputs("hint: run with --help\n", stderr)
            }
            exit(1)
        }
    }
}

private struct Options {
    var inputPath: String?
    var schedulerMode: SchedulerMode
    var timeZoneOverride: String?
    var ollamaModel: String?
    var ollamaEndpoint: String?
    var onnxModelPath: String?
    var onnxRunnerPath: String?
    var onnxPythonPath: String?
}

private func parseOptions(arguments: [String]) throws -> Options {
    var options = Options(
        inputPath: nil,
        schedulerMode: .stub,
        timeZoneOverride: nil,
        ollamaModel: nil,
        ollamaEndpoint: nil,
        onnxModelPath: nil,
        onnxRunnerPath: nil,
        onnxPythonPath: nil
    )

    var index = 0
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--help", "-h":
            throw SimulatorError.usage(usageText())
        case "--input", "-i":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.inputPath = arguments[index]
        case "--scheduler", "-s":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            let raw = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mode = SchedulerMode(rawValue: raw) else {
                throw SimulatorError.invalidInput("Unknown --scheduler value: \(raw)")
            }
            options.schedulerMode = mode
        case "--time-zone":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.timeZoneOverride = arguments[index]
        case "--ollama-model":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.ollamaModel = arguments[index]
        case "--ollama-endpoint":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.ollamaEndpoint = arguments[index]
        case "--onnx-model":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.onnxModelPath = arguments[index]
        case "--onnx-runner":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.onnxRunnerPath = arguments[index]
        case "--onnx-python":
            index += 1
            guard index < arguments.count else { throw SimulatorError.usage(usageText()) }
            options.onnxPythonPath = arguments[index]
        default:
            throw SimulatorError.usage(usageText())
        }
        index += 1
    }

    return options
}

private func usageText() -> String {
    """
    usage:
      swift run senseassist-schedule-sim [options]

    options:
      --input, -i <path>            Path to input file (default: auto-detect input.*)
      --scheduler, -s <mode>        stub|planner|onnx|ollama (default: stub)
      --time-zone <tz>              Override time zone (default: input.time_zone or system)

      --ollama-model <name>         Required for --scheduler ollama (or set SENSEASSIST_OLLAMA_MODEL)
      --ollama-endpoint <url>       Default: http://127.0.0.1:11434

      --onnx-model <path>           Required for --scheduler onnx (or set SENSEASSIST_ONNX_MODEL_PATH)
      --onnx-runner <path>          Default: Scripts/onnx_genai_runner.py
      --onnx-python <path>          Default: /usr/bin/python3

    input:
      - JSON envelope: { "tasks": [...] } (recommended) or a bare JSON array [ ... ]
      - Plain text: each non-empty line is a task title
    """
}

private func resolveInputPath(explicit: String?) throws -> String {
    if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (explicit as NSString).expandingTildeInPath
    }

    let fm = FileManager.default
    let cwd = fm.currentDirectoryPath
    if let found = findInputFile(in: cwd) {
        return found
    }

    let fallbackDir = URL(fileURLWithPath: cwd).appendingPathComponent("Sources/LLMRuntime/LLM_Scheduling_algo").path
    if let found = findInputFile(in: fallbackDir) {
        return found
    }

    throw SimulatorError.inputNotFound
}

private func findInputFile(in directory: String) -> String? {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return nil
    }

    let candidates = entries
        .filter { $0.lowercased().hasPrefix("input.") }
        .sorted()

    for name in candidates {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            continue
        }
        return path
    }

    return nil
}

private func loadInput(from path: String) throws -> SchedulingSimInputEnvelope {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        throw SimulatorError.invalidInput("Unable to read file at path: \(path)")
    }

    if path.lowercased().hasSuffix(".json") {
        let decoder = JSONDecoder()
        let rawText = String(data: data, encoding: .utf8) ?? ""
        if let array = try? decoder.decode([SchedulingSimTask].self, from: data) {
            return SchedulingSimInputEnvelope(timeZone: nil, constraints: nil, tasks: array, busyBlocks: nil)
        }
        if let envelope = try? decoder.decode(SchedulingSimInputEnvelope.self, from: data) {
            return envelope
        }
        throw SimulatorError.invalidInput("Could not decode JSON. First 200 chars: \(rawText.prefix(200))")
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw SimulatorError.invalidInput("Input is not valid UTF-8")
    }

    let lines = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let tasks = lines.map {
        SchedulingSimTask(
            taskID: nil,
            title: $0,
            category: nil,
            dueAtLocal: nil,
            estimatedMinutes: nil,
            minDailyMinutes: nil,
            priority: nil,
            stressWeight: nil,
            status: nil
        )
    }

    return SchedulingSimInputEnvelope(timeZone: nil, constraints: nil, tasks: tasks, busyBlocks: nil)
}

private func apply(_ input: SchedulingSimConstraints, to constraints: inout PlannerConstraints) {
    if let value = input.workdayStartHour24 { constraints.workdayStartHour24 = clamp(value, min: 0, max: 23) }
    if let value = input.workdayEndHour24 { constraints.workdayEndHour24 = clamp(value, min: 0, max: 23) }
    if let value = input.avoidAfterHour24 { constraints.avoidAfterHour24 = clamp(value, min: 0, max: 23) }
    if let value = input.maxDeepWorkMinutesPerDay { constraints.maxDeepWorkMinutesPerDay = max(0, value) }
    if let value = input.breakEveryMinutes { constraints.breakEveryMinutes = max(0, value) }
    if let value = input.breakDurationMinutes { constraints.breakDurationMinutes = max(0, value) }
    if let value = input.freeSpaceBufferMinutes { constraints.freeSpaceBufferMinutes = max(0, value) }
    if let value = input.sleepStart { constraints.sleepStart = value }
    if let value = input.sleepEnd { constraints.sleepEnd = value }
}

private func clamp(_ value: Int, min: Int, max: Int) -> Int {
    Swift.min(Swift.max(value, min), max)
}

private func mapTask(_ input: SchedulingSimTask, timeZone: TimeZone) throws -> TaskItem {
    let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
        throw SimulatorError.invalidInput("Task title is empty")
    }

    let taskID = input.taskID.flatMap(UUID.init(uuidString:)) ?? UUID()
    let category = input.category
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap { TaskCategory(rawValue: $0) }
        ?? .assignment
    let due = input.dueAtLocal.flatMap { parseLooseDate($0, timeZone: timeZone) }
    let estimatedMinutes = max(15, input.estimatedMinutes ?? 60)
    let minDailyMinutes = max(15, input.minDailyMinutes ?? 30)
    let priority = max(1, input.priority ?? 3)
    let stressWeight = min(max(input.stressWeight ?? 0.30, 0.0), 1.0)
    let status = input.status
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap { TaskStatus(rawValue: $0) }
        ?? .todo

    return TaskItem(
        taskID: taskID,
        title: title,
        category: category,
        dueAtLocal: due,
        estimatedMinutes: estimatedMinutes,
        minDailyMinutes: minDailyMinutes,
        priority: priority,
        stressWeight: stressWeight,
        status: status
    )
}

private func mapBusyBlock(_ input: SchedulingSimBusyBlock, timeZone: TimeZone) throws -> CalendarBlock? {
    guard
        let start = parseLooseDate(input.startLocal, timeZone: timeZone),
        let end = parseLooseDate(input.endLocal, timeZone: timeZone),
        start < end
    else {
        return nil
    }

    let lockLevel = input.lockLevel
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap { BlockLockLevel(rawValue: $0) }
        ?? .locked
    let managedByAgent = input.managedByAgent ?? false

    return CalendarBlock(
        taskID: nil,
        title: input.title,
        startLocal: start,
        endLocal: end,
        managedByAgent: managedByAgent,
        lockLevel: lockLevel,
        planRevision: 0
    )
}

private func parseLooseDate(_ raw: String, timeZone: TimeZone) -> Date? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    iso.timeZone = timeZone
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
    for format in [
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd"
    ] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }

    return nil
}

private struct PlanningContext {
    var date: Date
    var window: (start: Date, end: Date)
}

private func computePlanningDate(
    now: Date,
    constraints: PlannerConstraints,
    calendar: Calendar
) -> PlanningContext {
    func window(for date: Date) -> (Date, Date)? {
        let startOfDay = calendar.startOfDay(for: date)
        guard
            let dayStart = calendar.date(bySettingHour: constraints.workdayStartHour24, minute: 0, second: 0, of: startOfDay),
            let dayEndRaw = calendar.date(bySettingHour: constraints.workdayEndHour24, minute: 0, second: 0, of: startOfDay),
            let cutoff = calendar.date(bySettingHour: constraints.avoidAfterHour24, minute: 0, second: 0, of: startOfDay)
        else {
            return nil
        }

        let dayEnd = min(dayEndRaw, cutoff)
        guard dayStart < dayEnd else { return nil }
        return (dayStart, dayEnd)
    }

    if let todayWindow = window(for: now), now < todayWindow.1 {
        return PlanningContext(date: now, window: todayWindow)
    }

    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
    let tomorrowWindow = window(for: tomorrow) ?? (calendar.startOfDay(for: tomorrow), calendar.startOfDay(for: tomorrow))
    return PlanningContext(date: tomorrow, window: tomorrowWindow)
}

private func buildPastBusyBlock(
    now: Date,
    planningDate: Date,
    window: (start: Date, end: Date),
    calendar: Calendar,
    planRevision: Int
) -> CalendarBlock? {
    let sameDay = calendar.isDate(now, inSameDayAs: planningDate)
    guard sameDay else { return nil }
    guard now > window.start else { return nil }

    let roundedNow = roundUp(now, toMinutes: 5, calendar: calendar)
    let end = min(roundedNow, window.end)
    guard end > window.start else { return nil }

    return CalendarBlock(
        taskID: nil,
        title: "Busy (past time)",
        startLocal: window.start,
        endLocal: end,
        managedByAgent: false,
        lockLevel: .locked,
        planRevision: planRevision
    )
}

private func roundUp(_ date: Date, toMinutes: Int, calendar: Calendar) -> Date {
    guard toMinutes > 1 else { return date }
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard let floored = calendar.date(from: components),
          let minute = components.minute
    else {
        return date
    }

    let remainder = minute % toMinutes
    if remainder == 0 {
        return floored
    }

    let delta = toMinutes - remainder
    return calendar.date(byAdding: .minute, value: delta, to: floored) ?? date
}

private func runScheduler(
    mode: SchedulerMode,
    now: Date,
    planningDate: Date,
    tasks: [TaskItem],
    existingBlocks: [CalendarBlock],
    constraints: PlannerConstraints,
    planRevision: Int,
    timeZoneIdentifier: String,
    ollamaModel: String?,
    ollamaEndpoint: String?,
    onnxModelPath: String?,
    onnxRunnerPath: String?,
    onnxPythonPath: String?
) async throws -> SchedulePlan {
    switch mode {
    case .planner:
        let input = PlannerInput(
            date: planningDate,
            tasks: tasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision
        )
        let result = PlannerEngine.plan(input)
        return SchedulePlan(blocks: result.blocks, feasibilityState: result.feasibilityState, unscheduledTaskIDs: result.unscheduledTaskIDs)
    case .stub:
        return try await StubLLMRuntime().inferSchedulePlan(
            date: planningDate,
            tasks: tasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )
    case .onnx:
        let env = ProcessInfo.processInfo.environment
        let modelPath = onnxModelPath ?? env["SENSEASSIST_ONNX_MODEL_PATH"]
        guard let modelPath, !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimulatorError.missingEnvironment("Set SENSEASSIST_ONNX_MODEL_PATH or pass --onnx-model.")
        }
        let runner = onnxRunnerPath ?? env["SENSEASSIST_ONNX_RUNNER"] ?? "Scripts/onnx_genai_runner.py"
        let python = onnxPythonPath ?? env["SENSEASSIST_ONNX_PYTHON"] ?? "/usr/bin/python3"
        let maxNewTokens = envInt(env["SENSEASSIST_ONNX_MAX_NEW_TOKENS"]) ?? 512
        let scheduleMaxNewTokens = envInt(env["SENSEASSIST_ONNX_MAX_NEW_TOKENS_SCHEDULE"])
        let temperature = envDouble(env["SENSEASSIST_ONNX_TEMPERATURE"]) ?? 0.2
        let topP = envDouble(env["SENSEASSIST_ONNX_TOP_P"]) ?? 0.95
        let provider = envString(env["SENSEASSIST_ONNX_PROVIDER"])
        let speculativeDecodingEnabled = envBool(env["SENSEASSIST_ONNX_SPECULATIVE_DECODING"], defaultValue: true)
        let speculativeFirstPassRatio = envDouble(env["SENSEASSIST_ONNX_SPECULATIVE_FIRST_PASS_RATIO"]) ?? 0.55
        let powerAwareThrottlingEnabled = envBool(env["SENSEASSIST_ONNX_POWER_AWARE_THROTTLING"], defaultValue: true)
        let lowPowerModeTokenScale = envDouble(env["SENSEASSIST_ONNX_LOW_POWER_TOKEN_SCALE"]) ?? 0.65
        let lowPowerModeMinIntervalMilliseconds = envInt(env["SENSEASSIST_ONNX_LOW_POWER_MIN_INTERVAL_MS"]) ?? 80
        let daemonBatchWindowMilliseconds = envInt(env["SENSEASSIST_ONNX_DAEMON_BATCH_WINDOW_MS"]) ?? 8
        let daemonMaxBatchSize = envInt(env["SENSEASSIST_ONNX_DAEMON_MAX_BATCH_SIZE"]) ?? 4

        let runtime = ONNXGenAILLMRuntime(
            modelPath: modelPath,
            runnerScriptPath: runner,
            pythonExecutable: python,
            maxNewTokens: maxNewTokens,
            scheduleMaxNewTokens: scheduleMaxNewTokens,
            temperature: temperature,
            topP: topP,
            provider: provider,
            speculativeDecodingEnabled: speculativeDecodingEnabled,
            speculativeFirstPassRatio: speculativeFirstPassRatio,
            powerAwareThrottlingEnabled: powerAwareThrottlingEnabled,
            lowPowerModeTokenScale: lowPowerModeTokenScale,
            lowPowerModeMinIntervalMilliseconds: lowPowerModeMinIntervalMilliseconds,
            daemonBatchWindowMilliseconds: daemonBatchWindowMilliseconds,
            daemonMaxBatchSize: daemonMaxBatchSize
        )
        return try await runtime.inferSchedulePlan(
            date: planningDate,
            tasks: tasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )
    case .ollama:
        let env = ProcessInfo.processInfo.environment
        let model = ollamaModel ?? env["SENSEASSIST_OLLAMA_MODEL"]
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimulatorError.missingEnvironment("Set SENSEASSIST_OLLAMA_MODEL or pass --ollama-model.")
        }
        let endpointRaw = ollamaEndpoint ?? env["SENSEASSIST_OLLAMA_ENDPOINT"] ?? "http://127.0.0.1:11434"
        guard let endpointURL = URL(string: endpointRaw) else {
            throw SimulatorError.invalidInput("Invalid ollama endpoint URL: \(endpointRaw)")
        }
        let runtime = OllamaLLMRuntime(endpointURL: endpointURL, model: model)
        return try await runtime.inferSchedulePlan(
            date: planningDate,
            tasks: tasks,
            existingBlocks: existingBlocks,
            constraints: constraints,
            planRevision: planRevision,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

private func envString(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func envInt(_ value: String?) -> Int? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return Int(trimmed)
}

private func envDouble(_ value: String?) -> Double? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return Double(trimmed)
}

private func envBool(_ value: String?, defaultValue: Bool) -> Bool {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !normalized.isEmpty
    else {
        return defaultValue
    }

    if ["1", "true", "yes", "y", "on"].contains(normalized) { return true }
    if ["0", "false", "no", "n", "off"].contains(normalized) { return false }
    return defaultValue
}

private func printPlan(
    plan: SchedulePlan,
    tasks: [TaskItem],
    now: Date,
    planning: PlanningContext,
    constraints: PlannerConstraints,
    timeZone: TimeZone,
    mode: SchedulerMode,
    inputPath: String
) {
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"

    let timeFormatter = DateFormatter()
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.timeZone = timeZone
    timeFormatter.dateFormat = "h:mm a"

    let nowLine = "\(dayFormatter.string(from: now)) \(timeFormatter.string(from: now))"

    print("SenseAssist Scheduling Simulator")
    print("input=\(inputPath)")
    print("scheduler=\(mode.rawValue)")
    print("time_zone=\(timeZone.identifier)")
    print("now=\(nowLine)")
    print("planning_date=\(dayFormatter.string(from: planning.date))")
    print("window=\(timeFormatter.string(from: planning.window.start)) - \(timeFormatter.string(from: planning.window.end))")
    print(
        "constraints=max_deep_work=\(constraints.maxDeepWorkMinutesPerDay)m break_every=\(constraints.breakEveryMinutes)m break_duration=\(constraints.breakDurationMinutes)m buffer=\(constraints.freeSpaceBufferMinutes)m"
    )
    print("tasks=\(tasks.count) blocks=\(plan.blocks.count) feasibility=\(plan.feasibilityState.rawValue)")
    print("")

    if plan.blocks.isEmpty {
        print("Schedule: (no blocks)")
    } else {
        print("Schedule:")
        for block in plan.blocks.sorted(by: { $0.startLocal < $1.startLocal }) {
            let start = timeFormatter.string(from: block.startLocal)
            let end = timeFormatter.string(from: block.endLocal)
            let minutes = max(0, Int(block.endLocal.timeIntervalSince(block.startLocal) / 60.0))
            print("- \(start) - \(end)  \(block.title) (\(minutes)m)")
        }
    }

    let taskByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
    let unscheduledTitles = plan.unscheduledTaskIDs.compactMap { taskByID[$0]?.title }

    if !unscheduledTitles.isEmpty {
        print("")
        print("Unscheduled (\(unscheduledTitles.count)):")
        for title in unscheduledTitles.sorted() {
            print("- \(title)")
        }
    }
}
