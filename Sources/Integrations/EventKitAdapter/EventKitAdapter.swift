import CoreContracts
import Foundation

#if canImport(EventKit)
import EventKit

public enum EventKitPermissionState: String, Sendable {
    case fullAccess
    case writeOnly
    case denied
    case notDetermined
}

public actor EventKitService {
    private let store = EKEventStore()

    public init() {}

    public func currentPermissionState() -> EventKitPermissionState {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .fullAccess
            case .writeOnly: return .writeOnly
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        }

        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized: return .fullAccess
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
#else
public enum EventKitPermissionState: String, Sendable {
    case denied
}

public actor EventKitService {
    public init() {}

    public func currentPermissionState() -> EventKitPermissionState {
        .denied
    }
}
#endif
