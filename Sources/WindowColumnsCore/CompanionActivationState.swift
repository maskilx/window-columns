import Foundation

/// A minimized group suppresses only the immediate macOS activation cascade.
/// Every later Command-Tab, and every explicit Dock action, may restore it.
public struct CompanionActivationState {
    private var suppressUntil = Date.distantPast
    private var lastRequest = Date.distantPast

    public init() {}

    public func suppressesActivation(at now: Date) -> Bool { now < suppressUntil }

    public mutating func didMinimize(at now: Date) {
        suppressUntil = now.addingTimeInterval(0.35)
        lastRequest = .distantPast
    }

    public mutating func beginRequest(at now: Date, explicit: Bool = false) -> Bool {
        if explicit { suppressUntil = .distantPast }
        guard !suppressesActivation(at: now), now.timeIntervalSince(lastRequest) > 0.4 else { return false }
        lastRequest = now
        return true
    }
}
