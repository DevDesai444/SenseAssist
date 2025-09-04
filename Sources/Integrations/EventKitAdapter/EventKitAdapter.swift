import CoreContracts
import Foundation

public enum CalendarStoreError: Error, LocalizedError {
    case permissionDenied
    case calendarNotAvailable
    case eventNotFound
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar permission is not available"
        case .calendarNotAvailable:
            return "Managed calendar is not available"
        case .eventNotFound:
            return "Event not found"
        case .unsupportedPlatform:
            return "EventKit is not available on this platform"
        }
    }
}

public protocol CalendarStore: Sendable {
    func ensureManagedCalendar(named name: String) async throws
    func fetchManagedBlocks(on date: Date, calendar: Calendar) async throws -> [CalendarBlock]
    func createManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock
    func updateManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock
    func findManagedBlocks(fuzzyTitle: String, on date: Date?, calendar: Calendar) async throws -> [CalendarBlock]
}

public actor InMemoryCalendarStore: CalendarStore {
    private var blocks: [UUID: CalendarBlock] = [:]

    public init() {}

    public func ensureManagedCalendar(named name: String) async throws {
        _ = name
    }

    public func fetchManagedBlocks(on date: Date, calendar: Calendar) async throws -> [CalendarBlock] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }

        return blocks.values
            .filter { $0.managedByAgent && $0.startLocal >= start && $0.startLocal < end }
            .sorted { $0.startLocal < $1.startLocal }
    }

    public func createManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        var created = block
        created.calendarName = calendarName
        if created.ekEventID == nil {
            created.ekEventID = UUID().uuidString
        }
        blocks[created.blockID] = created
        return created
    }

    public func updateManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        guard blocks[block.blockID] != nil else {
            throw CalendarStoreError.eventNotFound
        }

        var updated = block
        updated.calendarName = calendarName
        if updated.ekEventID == nil {
            updated.ekEventID = UUID().uuidString
        }
        blocks[updated.blockID] = updated
        return updated
    }

    public func findManagedBlocks(fuzzyTitle: String, on date: Date?, calendar: Calendar) async throws -> [CalendarBlock] {
        let normalized = fuzzyTitle.lowercased()
        let candidateBlocks: [CalendarBlock]

        if let date {
            candidateBlocks = try await fetchManagedBlocks(on: date, calendar: calendar)
        } else {
            candidateBlocks = Array(blocks.values)
        }

        return candidateBlocks
            .filter { $0.title.lowercased().contains(normalized) }
            .sorted { $0.startLocal < $1.startLocal }
    }
}

#if canImport(EventKit)
import EventKit

public enum EventKitPermissionState: String, Sendable {
    case fullAccess
    case writeOnly
    case denied
    case notDetermined
}

public actor EventKitService: CalendarStore {
    private let store = EKEventStore()
    private let managedMarker = "[SenseAssistManaged]"

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

    public func ensureManagedCalendar(named name: String) async throws {
        _ = try resolveManagedCalendar(named: name, createIfMissing: true)
    }

    public func fetchManagedBlocks(on date: Date, calendar: Calendar) async throws -> [CalendarBlock] {
        let managedCalendar = try resolveManagedCalendar(named: "SenseAssist", createIfMissing: false)
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: [managedCalendar])
        return store.events(matching: predicate)
            .filter { ($0.notes ?? "").contains(managedMarker) }
            .map(eventToBlock)
            .sorted { $0.startLocal < $1.startLocal }
    }

    public func createManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        let calendar = try resolveManagedCalendar(named: calendarName, createIfMissing: true)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = block.title
        event.startDate = block.startLocal
        event.endDate = block.endLocal
        event.notes = markerNotes(for: block)

        try store.save(event, span: .thisEvent, commit: true)

        var saved = block
        saved.calendarName = calendarName
        saved.ekEventID = event.eventIdentifier
        return saved
    }

    public func updateManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        guard let eventID = block.ekEventID, let event = store.event(withIdentifier: eventID) else {
            throw CalendarStoreError.eventNotFound
        }

        let calendar = try resolveManagedCalendar(named: calendarName, createIfMissing: true)
        event.calendar = calendar
        event.title = block.title
        event.startDate = block.startLocal
        event.endDate = block.endLocal
        event.notes = markerNotes(for: block)

        try store.save(event, span: .thisEvent, commit: true)

        return block
    }

    public func findManagedBlocks(fuzzyTitle: String, on date: Date?, calendar: Calendar) async throws -> [CalendarBlock] {
        let managedCalendar = try resolveManagedCalendar(named: "SenseAssist", createIfMissing: false)

        let now = Date()
        let searchStart: Date
        let searchEnd: Date
        if let date {
            searchStart = calendar.startOfDay(for: date)
            searchEnd = calendar.date(byAdding: .day, value: 1, to: searchStart) ?? searchStart
        } else {
            searchStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            searchEnd = calendar.date(byAdding: .day, value: 30, to: now) ?? now
        }

        let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: [managedCalendar])
        let normalized = fuzzyTitle.lowercased()
        return store.events(matching: predicate)
            .filter { ($0.notes ?? "").contains(managedMarker) }
            .filter { $0.title.lowercased().contains(normalized) }
            .map(eventToBlock)
            .sorted { $0.startLocal < $1.startLocal }
    }

    private func resolveManagedCalendar(named name: String, createIfMissing: Bool) throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }

        guard createIfMissing else {
            throw CalendarStoreError.calendarNotAvailable
        }

        guard currentPermissionState() == .fullAccess || currentPermissionState() == .writeOnly else {
            throw CalendarStoreError.permissionDenied
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name

        if let defaultSource = store.defaultCalendarForNewEvents?.source {
            calendar.source = defaultSource
        } else if let fallbackSource = store.sources.first(where: { $0.sourceType == .calDAV }) ?? store.sources.first {
            calendar.source = fallbackSource
        } else {
            throw CalendarStoreError.calendarNotAvailable
        }

        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func markerNotes(for block: CalendarBlock) -> String {
        "\(managedMarker) block_id=\(block.blockID.uuidString) revision=\(block.planRevision)"
    }

    private func eventToBlock(_ event: EKEvent) -> CalendarBlock {
        let blockID = UUID()
        return CalendarBlock(
            blockID: blockID,
            taskID: nil,
            title: event.title,
            startLocal: event.startDate,
            endLocal: event.endDate,
            ekEventID: event.eventIdentifier,
            calendarName: event.calendar.title,
            managedByAgent: true,
            lockLevel: .flexible,
            planRevision: 0
        )
    }
}
#else
public enum EventKitPermissionState: String, Sendable {
    case denied
}

public actor EventKitService: CalendarStore {
    public init() {}

    public func currentPermissionState() -> EventKitPermissionState {
        .denied
    }

    public func ensureManagedCalendar(named name: String) async throws {
        _ = name
        throw CalendarStoreError.unsupportedPlatform
    }

    public func fetchManagedBlocks(on date: Date, calendar: Calendar) async throws -> [CalendarBlock] {
        _ = date
        _ = calendar
        throw CalendarStoreError.unsupportedPlatform
    }

    public func createManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        _ = block
        _ = calendarName
        throw CalendarStoreError.unsupportedPlatform
    }

    public func updateManagedBlock(_ block: CalendarBlock, calendarName: String) async throws -> CalendarBlock {
        _ = block
        _ = calendarName
        throw CalendarStoreError.unsupportedPlatform
    }

    public func findManagedBlocks(fuzzyTitle: String, on date: Date?, calendar: Calendar) async throws -> [CalendarBlock] {
        _ = fuzzyTitle
        _ = date
        _ = calendar
        throw CalendarStoreError.unsupportedPlatform
    }
}
#endif
