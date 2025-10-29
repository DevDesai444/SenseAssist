import CoreContracts
import EventKitAdapter
import Foundation
import Storage

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
#endif

@main
struct SenseAssistMenuMain {
    static func main() async {
        do {
            let context = try MenuRuntimeContext.makeDefault()
            let args = ProcessInfo.processInfo.arguments

            if try await handleCLIIfRequested(args: args, context: context) {
                context.close()
                return
            }

            #if canImport(AppKit) && canImport(SwiftUI)
            await MainActor.run {
                let delegate = SenseAssistMenuApplicationDelegate(context: context)
                SenseAssistMenuApplicationRunner.run(delegate: delegate)
            }
            #else
            try await printOnboardingStatus(
                config: context.config,
                accountRepository: context.accountRepository,
                eventKitService: context.eventKitService
            )
            context.close()
            #endif
        } catch {
            fputs("menu app failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func handleCLIIfRequested(args: [String], context: MenuRuntimeContext) async throws -> Bool {
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return true
        }

        if args.contains("--health-check") {
            let requireCalendarReady = args.contains("--require-calendar-ready")
            try await runHealthCheck(
                config: context.config,
                accountRepository: context.accountRepository,
                eventKitService: context.eventKitService,
                requireCalendarReady: requireCalendarReady
            )
            return true
        }

        if args.contains("--request-calendar-access") {
            await requestCalendarAccess(eventKitService: context.eventKitService)
            return true
        }

        if args.contains("--list-accounts") {
            try printAccounts(using: context.accountRepository)
            return true
        }

        if let linkIndex = args.firstIndex(of: "--link-account"), args.count > linkIndex + 2 {
            let providerRaw = args[linkIndex + 1].lowercased()
            let email = args[linkIndex + 2]
            guard let provider = StorageProvider(rawValue: providerRaw) else {
                print("Unsupported provider: \(providerRaw). Use gmail or outlook.")
                return true
            }

            let explicitID = args.count > linkIndex + 3 ? args[linkIndex + 3] : nil
            let accountID = explicitID ?? "\(provider.rawValue):\(email)"
            try context.accountRepository.upsert(
                ConnectedEmailAccount(
                    accountID: accountID,
                    provider: provider,
                    email: email,
                    isEnabled: true
                )
            )
            print("Linked account: \(provider.rawValue) \(email) (\(accountID))")
            try printAccounts(using: context.accountRepository)
            return true
        }

        if let disableIndex = args.firstIndex(of: "--disable-account"), args.count > disableIndex + 1 {
            try setEnabled(args[disableIndex + 1], enabled: false, repository: context.accountRepository)
            try printAccounts(using: context.accountRepository)
            return true
        }

        if let enableIndex = args.firstIndex(of: "--enable-account"), args.count > enableIndex + 1 {
            try setEnabled(args[enableIndex + 1], enabled: true, repository: context.accountRepository)
            try printAccounts(using: context.accountRepository)
            return true
        }

        if args.contains("--status") {
            try await printOnboardingStatus(
                config: context.config,
                accountRepository: context.accountRepository,
                eventKitService: context.eventKitService
            )
            return true
        }

        return false
    }

    private static func printUsage() {
        print("SenseAssist Menu")
        print("Usage:")
        print("  senseassist-menu                       Launch native menu bar onboarding UI")
        print("  senseassist-menu --health-check       Run non-interactive onboarding health check")
        print("  senseassist-menu --health-check --require-calendar-ready")
        print("  senseassist-menu --request-calendar-access")
        print("  senseassist-menu --status             Print onboarding status snapshot")
        print("  senseassist-menu --list-accounts")
        print("  senseassist-menu --link-account gmail student@example.com [account_id]")
        print("  senseassist-menu --link-account outlook student@university.edu [account_id]")
        print("  senseassist-menu --disable-account <account_id>")
        print("  senseassist-menu --enable-account <account_id>")
    }

    private static func requestCalendarAccess(eventKitService: EventKitService) async {
        let before = await eventKitService.currentPermissionState()
        let after = await eventKitService.requestCalendarAccessIfNeeded()

        print("Calendar permission request")
        print("before=\(before.rawValue)")
        print("after=\(after.rawValue)")

        switch after {
        case .fullAccess, .writeOnly:
            print("result=granted")
        case .denied:
            print("result=denied")
            print("next_step=Open System Settings > Privacy & Security > Calendars")
        case .notDetermined:
            print("result=not_determined")
            print("next_step=Run this command from a normal Terminal.app session to allow macOS to show the permission prompt")
        }
    }

    private static func runHealthCheck(
        config: SenseAssistConfiguration,
        accountRepository: AccountRepository,
        eventKitService: EventKitService,
        requireCalendarReady: Bool
    ) async throws {
        let permission = await eventKitService.currentPermissionState()
        let accounts = try accountRepository.list(enabledOnly: false)
        let enabled = accounts.filter(\.isEnabled).count

        var managedCalendarStatus = "skipped"
        var readinessIssues: [String] = []

        switch permission {
        case .fullAccess, .writeOnly:
            do {
                try await eventKitService.ensureManagedCalendar(named: "SenseAssist")
                managedCalendarStatus = "ok"
            } catch {
                managedCalendarStatus = "error"
                readinessIssues.append("managed_calendar_unavailable")
                if requireCalendarReady {
                    throw CalendarStoreError.calendarNotAvailable
                }
            }
        case .notDetermined:
            readinessIssues.append("calendar_permission_not_determined")
            if requireCalendarReady {
                throw CalendarStoreError.permissionDenied
            }
        case .denied:
            readinessIssues.append("calendar_permission_denied")
            if requireCalendarReady {
                throw CalendarStoreError.permissionDenied
            }
        }

        print("SenseAssist menu health")
        print("db_path=\(config.databasePath)")
        print("calendar_permission=\(permission.rawValue)")
        print("managed_calendar_check=\(managedCalendarStatus)")
        print("accounts_enabled=\(enabled)")
        print("accounts_total=\(accounts.count)")
        if readinessIssues.isEmpty {
            print("health=ok")
        } else {
            print("health=degraded")
            print("issues=\(readinessIssues.joined(separator: ","))")
        }
    }

    private static func printOnboardingStatus(
        config: SenseAssistConfiguration,
        accountRepository: AccountRepository,
        eventKitService: EventKitService
    ) async throws {
        let permission = await eventKitService.currentPermissionState()
        let accounts = try accountRepository.list(enabledOnly: false)
        let enabled = accounts.filter(\.isEnabled).count

        print("SenseAssist onboarding status")
        print("Database: \(config.databasePath)")
        print("Calendar permission: \(permission.rawValue)")
        print("Accounts: enabled=\(enabled) total=\(accounts.count)")
        print("")
        print("Next steps:")
        print("1. Launch the native menu onboarding UI: senseassist-menu")
        print("2. Link Gmail/Outlook accounts in the onboarding window.")
        print("3. Run live sync after OAuth setup: make sync-all-live")
    }

    private static func printAccounts(using repository: AccountRepository) throws {
        let accounts = try repository.list(enabledOnly: false)
        if accounts.isEmpty {
            print("No linked accounts.")
            return
        }

        print("Linked accounts:")
        for account in accounts {
            let state = account.isEnabled ? "enabled" : "disabled"
            print("- \(account.provider.rawValue) \(account.email) (\(account.accountID)) [\(state)]")
        }
    }

    private static func setEnabled(_ accountID: String, enabled: Bool, repository: AccountRepository) throws {
        let accounts = try repository.list(enabledOnly: false)
        guard let account = accounts.first(where: { $0.accountID == accountID }) else {
            print("Account not found: \(accountID)")
            return
        }

        try repository.upsert(
            ConnectedEmailAccount(
                accountID: account.accountID,
                provider: account.provider,
                email: account.email,
                isEnabled: enabled
            )
        )
        print("\(enabled ? "Enabled" : "Disabled") account: \(accountID)")
    }
}

private final class MenuRuntimeContext {
    let config: SenseAssistConfiguration
    let store: SQLiteStore
    let accountRepository: AccountRepository
    let eventKitService: EventKitService
    private let logger: Logging

    init(
        config: SenseAssistConfiguration,
        store: SQLiteStore,
        accountRepository: AccountRepository,
        eventKitService: EventKitService,
        logger: Logging
    ) {
        self.config = config
        self.store = store
        self.accountRepository = accountRepository
        self.eventKitService = eventKitService
        self.logger = logger
    }

    static func makeDefault() throws -> MenuRuntimeContext {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let currentDirectory = FileManager.default.currentDirectoryPath
        var config = SenseAssistConfiguration.default(homeDirectory: home)

        if let explicitDBPath = (
            environment["SENSEASSIST_DATABASE_PATH"] ??
                environment["SENSEASSIST_DB_PATH"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !explicitDBPath.isEmpty {
            config.databasePath = (explicitDBPath as NSString).expandingTildeInPath
        }

        let logger = ConsoleLogger(minimumLevel: .error)
        let resolvedDatabasePath = RuntimePathResolver.resolveWritableDatabasePath(
            preferredPath: config.databasePath,
            fallbackBaseDirectory: currentDirectory
        )
        config.databasePath = resolvedDatabasePath

        let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try store.initialize()
        let accountRepository = AccountRepository(store: store)
        return MenuRuntimeContext(
            config: config,
            store: store,
            accountRepository: accountRepository,
            eventKitService: EventKitService(),
            logger: logger
        )
    }

    func close() {
        store.close()
    }

    func listAccountsFresh(enabledOnly: Bool = false) throws -> [ConnectedEmailAccount] {
        try withFreshAccountRepository { repository in
            try repository.list(enabledOnly: enabledOnly)
        }
    }

    func upsertAccountFresh(_ account: ConnectedEmailAccount) throws {
        try withFreshAccountRepository { repository in
            try repository.upsert(account)
        }
    }

    private func withFreshAccountRepository<T>(_ operation: (AccountRepository) throws -> T) throws -> T {
        let freshStore = SQLiteStore(databasePath: config.databasePath, logger: logger)
        try freshStore.initialize()
        defer { freshStore.close() }

        let repository = AccountRepository(store: freshStore)
        return try operation(repository)
    }

    deinit {
        store.close()
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
@MainActor
private final class SenseAssistOnboardingViewModel: ObservableObject {
    @Published private(set) var accounts: [ConnectedEmailAccount] = []
    @Published private(set) var permissionState: EventKitPermissionState = .denied
    @Published private(set) var isLoading = false
    @Published var selectedProvider: StorageProvider = .gmail
    @Published var pendingEmail: String = ""
    @Published var statusMessage: String = ""
    @Published var statusIsError = false
    @Published private(set) var lastRefreshedAt: Date?

    private let context: MenuRuntimeContext

    init(context: MenuRuntimeContext) {
        self.context = context
    }

    var enabledAccountsCount: Int {
        accounts.filter(\.isEnabled).count
    }

    var calendarPermissionDisplay: String {
        switch permissionState.rawValue {
        case "fullAccess":
            return "Granted (Full Access)"
        case "writeOnly":
            return "Granted (Write-Only)"
        case "notDetermined":
            return "Not Yet Granted"
        case "denied":
            return "Denied"
        default:
            return permissionState.rawValue
        }
    }

    var isCalendarReady: Bool {
        let raw = permissionState.rawValue
        return raw == "fullAccess" || raw == "writeOnly"
    }

    var onboardingProgress: Double {
        var completed = 0.0
        if isCalendarReady {
            completed += 1.0
        }
        if enabledAccountsCount > 0 {
            completed += 1.0
        }
        return completed / 2.0
    }

    var onboardingProgressText: String {
        "\(Int(onboardingProgress * 100.0))% complete"
    }

    var canLinkPendingAccount: Bool {
        isValidEmail(pendingEmail) && !isLoading
    }

    var databasePath: String {
        context.config.databasePath
    }

    func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            lastRefreshedAt = Date()
        }

        permissionState = await context.eventKitService.currentPermissionState()
        do {
            accounts = try context.listAccountsFresh(enabledOnly: false)
        } catch {
            setStatus(
                "Failed to read accounts from \(context.config.databasePath): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func ensureManagedCalendarReady() async {
        isLoading = true
        defer { isLoading = false }

        let permissionState = await context.eventKitService.currentPermissionState()
        if permissionState == .notDetermined {
            let requestedState = await context.eventKitService.requestCalendarAccessIfNeeded()
            if requestedState == .denied {
                setStatus(
                    "Calendar permission was denied. Open Calendar privacy settings for the host app (for example Terminal) and allow access.",
                    isError: true
                )
                await refresh()
                return
            } else if requestedState == .notDetermined {
                setStatus(
                    "Calendar prompt did not appear. Click \"Request Calendar Access\" or run `swift run senseassist-menu --request-calendar-access` from Terminal.app.",
                    isError: true
                )
                await refresh()
                return
            }
        } else if permissionState == .denied {
            setStatus(
                "Calendar permission is denied for this host context. Run `swift run senseassist-menu --request-calendar-access` from Terminal.app, then grant Calendar access there.",
                isError: true
            )
            return
        }

        do {
            try await context.eventKitService.ensureManagedCalendar(named: "SenseAssist")
            setStatus("Managed calendar is ready.", isError: false)
            await refresh()
        } catch {
            setStatus("Managed calendar setup failed: \(error.localizedDescription)", isError: true)
        }
    }

    func requestCalendarAccess() async {
        isLoading = true
        defer { isLoading = false }

        let before = await context.eventKitService.currentPermissionState()
        let after = await context.eventKitService.requestCalendarAccessIfNeeded()

        switch after {
        case .fullAccess, .writeOnly:
            setStatus("Calendar permission granted (\(after.rawValue)).", isError: false)
        case .denied:
            setStatus(
                "Calendar permission denied. Open Calendar privacy settings and enable access for the host app.",
                isError: true
            )
        case .notDetermined:
            if before == .notDetermined {
                setStatus(
                    "Calendar prompt did not appear in this host context. Run `swift run senseassist-menu --request-calendar-access` from Terminal.app.",
                    isError: true
                )
            } else {
                setStatus("Calendar permission remains unresolved (\(after.rawValue)).", isError: true)
            }
        }

        await refresh()
    }

    func linkPendingAccount() async {
        let normalizedEmail = pendingEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(normalizedEmail) else {
            setStatus("Enter a valid email address before linking.", isError: true)
            return
        }

        isLoading = true
        defer { isLoading = false }

        let accountID = "\(selectedProvider.rawValue):\(normalizedEmail)"
        do {
            try context.upsertAccountFresh(
                ConnectedEmailAccount(
                    accountID: accountID,
                    provider: selectedProvider,
                    email: normalizedEmail,
                    isEnabled: true
                )
            )
            pendingEmail = ""
            setStatus("Linked account \(normalizedEmail).", isError: false)
            await refresh()
        } catch {
            setStatus(
                "Failed to link account in \(context.config.databasePath): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func setEnabled(accountID: String, enabled: Bool) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let list = try context.listAccountsFresh(enabledOnly: false)
            guard let account = list.first(where: { $0.accountID == accountID }) else {
                setStatus("Account not found: \(accountID)", isError: true)
                return
            }

            try context.upsertAccountFresh(
                ConnectedEmailAccount(
                    accountID: account.accountID,
                    provider: account.provider,
                    email: account.email,
                    isEnabled: enabled
                )
            )

            setStatus("\(enabled ? "Enabled" : "Disabled") \(account.email).", isError: false)
            await refresh()
        } catch {
            setStatus("Failed to update account: \(error.localizedDescription)", isError: true)
        }
    }

    func openCalendarPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.SystemPreferences"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        setStatus("Unable to open Calendar privacy settings.", isError: true)
    }

    func openDatabaseFolder() {
        let dbURL = URL(fileURLWithPath: context.config.databasePath)
        let folderURL = dbURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            setStatus("Failed to create/open DB folder: \(error.localizedDescription)", isError: true)
            return
        }

        if FileManager.default.fileExists(atPath: dbURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dbURL])
        } else {
            _ = NSWorkspace.shared.open(folderURL)
        }
    }

    func copySyncCommand() {
        let command = "make sync-all-live"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        setStatus("Copied `\(command)` to clipboard.", isError: false)
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else {
            return false
        }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".")
    }
}

@MainActor
private final class SenseAssistMenuApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let context: MenuRuntimeContext
    private let onboardingModel: SenseAssistOnboardingViewModel
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?

    init(context: MenuRuntimeContext) {
        self.context = context
        self.onboardingModel = SenseAssistOnboardingViewModel(context: context)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusMenu()
        showOnboardingWindow(nil)
        Task { await onboardingModel.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        context.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showOnboardingWindow(nil)
        }
        return true
    }

    @objc func showOnboardingWindow(_ sender: Any?) {
        _ = sender

        if onboardingWindow == nil {
            let rootView = SenseAssistOnboardingView(model: onboardingModel)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "SenseAssist Onboarding"
            window.minSize = NSSize(width: 620, height: 700)
            window.setContentSize(NSSize(width: 700, height: 760))
            window.styleMask.insert(.resizable)
            window.isReleasedWhenClosed = false
            window.delegate = self
            onboardingWindow = window
        }

        // Switch to .regular so the app becomes frontmost and buttons respond on first click.
        // .accessory apps are not "active" in the macOS sense, so without this the window
        // would require a first click to activate and a second click to press any button.
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Restore menu-bar-only appearance once the onboarding window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func refreshStatus(_ sender: Any?) {
        _ = sender
        Task { await onboardingModel.refresh() }
    }

    @objc func quitApplication(_ sender: Any?) {
        _ = sender
        NSApplication.shared.terminate(nil)
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "SenseAssist"
        item.button?.toolTip = "SenseAssist onboarding and account management"

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Onboarding", action: #selector(showOnboardingWindow(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "Refresh Status", action: #selector(refreshStatus(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SenseAssist Menu", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }
}

@MainActor
private enum SenseAssistMenuApplicationRunner {
    static func run(delegate: NSApplicationDelegate) {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private struct SenseAssistOnboardingView: View {
    @ObservedObject var model: SenseAssistOnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                progress
                calendarAccessStep
                accountLinkStep
                accountManagementStep
                runHelperStep
                statusBanner
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 720)
        .task {
            await model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SenseAssist Setup")
                    .font(.system(size: 24, weight: .semibold))
                Text("Connect calendar + accounts, then run live sync.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .disabled(model.isLoading)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.onboardingProgress)
                .progressViewStyle(.linear)
            Text(model.onboardingProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var calendarAccessStep: some View {
        OnboardingStepCard(
            title: "Step 1: Calendar Access",
            statusText: model.calendarPermissionDisplay,
            statusIsReady: model.isCalendarReady
        ) {
            Text("SenseAssist writes only to its managed calendar. Grant Calendar access and validate managed calendar availability.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Request Calendar Access") {
                    Task { await model.requestCalendarAccess() }
                }
                .disabled(model.isLoading)
                Button("Open Calendar Privacy Settings") {
                    model.openCalendarPrivacySettings()
                }
                Button("Create / Validate Managed Calendar") {
                    Task { await model.ensureManagedCalendarReady() }
                }
                .disabled(model.isLoading)
            }
        }
    }

    private var accountLinkStep: some View {
        OnboardingStepCard(
            title: "Step 2: Link an Account",
            statusText: model.enabledAccountsCount > 0 ? "Account linked" : "No account linked",
            statusIsReady: model.enabledAccountsCount > 0
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $model.selectedProvider) {
                    Text("Gmail").tag(StorageProvider.gmail)
                    Text("Outlook").tag(StorageProvider.outlook)
                }
                .pickerStyle(.segmented)

                HStack {
                    TextField("student@example.com", text: $model.pendingEmail)
                        .textFieldStyle(.roundedBorder)
                    Button("Link Account") {
                        Task { await model.linkPendingAccount() }
                    }
                    .disabled(!model.canLinkPendingAccount)
                }
            }
        }
    }

    private var accountManagementStep: some View {
        OnboardingStepCard(
            title: "Step 3: Manage Linked Accounts",
            statusText: "\(model.enabledAccountsCount) enabled of \(model.accounts.count)",
            statusIsReady: model.enabledAccountsCount > 0
        ) {
            if model.accounts.isEmpty {
                Text("No linked accounts yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.accounts, id: \.accountID) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email)
                                    .font(.body)
                                Text("\(account.provider.rawValue) • \(account.accountID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(account.isEnabled ? "Disable" : "Enable") {
                                Task { await model.setEnabled(accountID: account.accountID, enabled: !account.isEnabled) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var runHelperStep: some View {
        OnboardingStepCard(
            title: "Step 4: Run Live Sync",
            statusText: "Ready when calendar + account are configured",
            statusIsReady: model.isCalendarReady && model.enabledAccountsCount > 0
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use this command after OAuth env setup:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Database: \(model.databasePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("make sync-all-live")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                HStack {
                    Button("Copy Command") {
                        model.copySyncCommand()
                    }
                    Button("Open DB Folder") {
                        model.openDatabaseFolder()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !model.statusMessage.isEmpty || model.lastRefreshedAt != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .foregroundStyle(model.statusIsError ? .red : .green)
                        .font(.subheadline)
                }

                if let timestamp = model.lastRefreshedAt {
                    Text("Last refreshed: \(timestamp.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct OnboardingStepCard<Content: View>: View {
    let title: String
    let statusText: String
    let statusIsReady: Bool
    let content: Content

    init(
        title: String,
        statusText: String,
        statusIsReady: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.statusText = statusText
        self.statusIsReady = statusIsReady
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusIsReady ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
                    .foregroundStyle(statusIsReady ? .green : .orange)
                    .clipShape(Capsule())
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
    }
}
#endif
