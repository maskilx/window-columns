import Foundation

public struct WindowFingerprint: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let title: String
    public let windowNumber: UInt32?

    public init(bundleIdentifier: String, title: String, windowNumber: UInt32?) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowNumber = windowNumber
    }

    public func matches(_ other: WindowFingerprint) -> Bool {
        guard bundleIdentifier == other.bundleIdentifier else { return false }
        if let windowNumber, let otherNumber = other.windowNumber {
            return windowNumber == otherNumber
        }
        return title == other.title
    }
}
