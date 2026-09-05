import Foundation

/// Serializes asynchronous launches and preserves crash backoff across every
/// reconciliation entry point, including unrelated application exits.
public struct CompanionLaunchGate<ID: Hashable> {
    private var pending: [ID: UUID] = [:]
    private var retryAfter: [ID: Date] = [:]

    public init() {}

    public func isPending(_ id: ID) -> Bool { pending[id] != nil }

    public func retryDelay(for id: ID, now: Date) -> TimeInterval {
        max(0, (retryAfter[id] ?? .distantPast).timeIntervalSince(now))
    }

    public mutating func begin(_ id: ID, now: Date) -> UUID? {
        guard pending[id] == nil, retryDelay(for: id, now: now) == 0 else { return nil }
        let token = UUID()
        pending[id] = token
        return token
    }

    public mutating func complete(_ id: ID, token: UUID) -> Bool {
        guard pending[id] == token else { return false }
        pending.removeValue(forKey: id)
        return true
    }

    public mutating func deferRetry(_ id: ID, until date: Date) {
        retryAfter[id] = date
    }

    public mutating func cancel(_ id: ID) {
        pending.removeValue(forKey: id)
        retryAfter.removeValue(forKey: id)
    }
}
