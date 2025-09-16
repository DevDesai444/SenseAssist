import CoreContracts
import EventKitAdapter
import Foundation
import Storage

@main
struct SenseAssistMenuMain {
    static func main() async {
        do {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.currentDirectoryPath
            let config = SenseAssistConfiguration.default(homeDirectory: home)
            let logger = ConsoleLogger(minimumLevel: .error)
            let store = SQLiteStore(databasePath: config.databasePath, logger: logger)
            try store.initialize()
            defer { store.close() }

            let accountRepository = AccountRepository(store: store)
            let args = ProcessInfo.processInfo.arguments

            if args.contains("--list-accounts") {
                try printAccounts(using: accountRepository)
                return
            }

            if let linkIndex = args.firstIndex(of: "--link-account"), args.count > linkIndex + 2 {
                let providerRaw = args[linkIndex + 1].lowercased()
                let email = args[linkIndex + 2]
                guard let provider = StorageProvider(rawValue: providerRaw) else {
                    print("Unsupported provider: \(providerRaw). Use gmail or outlook.")
                    return
                }

                let explicitID = args.count > linkIndex + 3 ? args[linkIndex + 3] : nil
                let accountID = explicitID ?? "\(provider.rawValue):\(email)"
                try accountRepository.upsert(
                    ConnectedEmailAccount(
                        accountID: accountID,
                        provider: provider,
                        email: email,
                        isEnabled: true
                    )
                )
                print("Linked account: \(provider.rawValue) \(email) (\(accountID))")
                try printAccounts(using: accountRepository)
                return
            }

            if let disableIndex = args.firstIndex(of: "--disable-account"), args.count > disableIndex + 1 {
                try setEnabled(args[disableIndex + 1], enabled: false, repository: accountRepository)
                try printAccounts(using: accountRepository)
                return
            }

            if let enableIndex = args.firstIndex(of: "--enable-account"), args.count > enableIndex + 1 {
                try setEnabled(args[enableIndex + 1], enabled: true, repository: accountRepository)
                try printAccounts(using: accountRepository)
                return
            }

            try await printOnboardingStatus(config: config, accountRepository: accountRepository)
        } catch {
            fputs("menu app failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printOnboardingStatus(config: SenseAssistConfiguration, accountRepository: AccountRepository) async throws {
        let eventKit = EventKitService()
        let permission = await eventKit.currentPermissionState()
        let accounts = try accountRepository.list(enabledOnly: false)
        let enabled = accounts.filter(\.isEnabled).count

        print("SenseAssist onboarding status")
        print("Database: \(config.databasePath)")
        print("Calendar permission: \(permission.rawValue)")
        print("Accounts: enabled=\(enabled) total=\(accounts.count)")
        print("")
        print("Next steps:")
        print("1. Grant Calendar access in System Settings -> Privacy & Security -> Calendars.")
        print("2. Link Gmail/Outlook accounts via:")
        print("   senseassist-menu --link-account gmail student@example.com")
        print("   senseassist-menu --link-account outlook student@university.edu")
        print("3. Verify linked accounts via: senseassist-menu --list-accounts")
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
