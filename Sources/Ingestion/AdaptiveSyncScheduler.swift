import CoreContracts
import Foundation

public enum SyncState: Equatable, Sendable {
    case active
    case normal
    case idle
    case error(retryCount: Int)
}

public struct SyncIntervalDecision: Equatable, Sendable {
    public var delayMinutes: Int
    public var jitterSeconds: Int

    public init(delayMinutes: Int, jitterSeconds: Int) {
        self.delayMinutes = delayMinutes
        self.jitterSeconds = jitterSeconds
    }
}

public enum AdaptiveSyncScheduler {
    public static func nextInterval(for state: SyncState, config: SyncConfiguration, seed: Int = 0) -> SyncIntervalDecision {
        let baseMinutes: Int

        switch state {
        case .active:
            baseMinutes = max(1, config.activePollingMinutes)
        case .normal:
            baseMinutes = max(1, config.normalPollingMinutes)
        case .idle:
            baseMinutes = max(1, config.idlePollingMinutes)
        case let .error(retryCount):
            let exponential = Int(pow(2.0, Double(max(0, retryCount))))
            baseMinutes = min(config.maxBackoffMinutes, max(1, config.activePollingMinutes * exponential))
        }

        let jitterSeconds = deterministicJitter(seed: seed, maxSeconds: 30)
        return SyncIntervalDecision(delayMinutes: baseMinutes, jitterSeconds: jitterSeconds)
    }

    private static func deterministicJitter(seed: Int, maxSeconds: Int) -> Int {
        guard maxSeconds > 0 else { return 0 }
        return abs(seed) % (maxSeconds + 1)
    }
}
