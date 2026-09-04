import Foundation

/// A Semantic Version (2.0.0 compliant) parser and comparator.
/// Supports standard version formats including prereleases such as `0.1.0-beta.2`.
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible, Codable {
    public enum PrereleaseIdentifier: Comparable, Equatable, CustomStringConvertible {
        case numeric(Int)
        case text(String)

        public var description: String {
            switch self {
            case .numeric(let value): return String(value)
            case .text(let value): return value
            }
        }

        public static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(l), .numeric(r)):
                return l < r
            case let (.text(l), .text(r)):
                return l.localizedStandardCompare(r) == .orderedAscending
            case (.numeric, .text):
                // Per SemVer 2.0 §11.4.3: Numeric identifiers always have lower precedence than text identifiers.
                return true
            case (.text, .numeric):
                return false
            }
        }
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [PrereleaseIdentifier]
    public let raw: String

    public var description: String { raw }

    public var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    public init?(string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        // Strip build metadata (everything after '+') per SemVer 2.0
        let partsWithoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let versionAndPrerelease = String(partsWithoutBuild[0])

        let parts = versionAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)

        guard !numericParts.isEmpty,
              let maj = Int(numericParts[0]), maj >= 0 else {
            return nil
        }
        self.major = maj
        self.minor = numericParts.count > 1 ? (Int(numericParts[1]) ?? 0) : 0
        self.patch = numericParts.count > 2 ? (Int(numericParts[2]) ?? 0) : 0

        if parts.count > 1 {
            let prereleaseStr = String(parts[1])
            let identifiers = prereleaseStr.split(separator: ".").map { item -> PrereleaseIdentifier in
                if let num = Int(item), String(num) == item {
                    return .numeric(num)
                } else {
                    return .text(String(item))
                }
            }
            self.prerelease = identifiers
        } else {
            self.prerelease = []
        }

        self.raw = trimmed
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // When major, minor, and patch are equal:
        // A normal version has greater precedence than a pre-release version.
        // e.g. 1.0.0-alpha < 1.0.0
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (false, true):
            return true
        case (true, false):
            return false
        case (true, true):
            return false
        case (false, false):
            let count = min(lhs.prerelease.count, rhs.prerelease.count)
            for i in 0..<count {
                if lhs.prerelease[i] != rhs.prerelease[i] {
                    return lhs.prerelease[i] < rhs.prerelease[i]
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major &&
        lhs.minor == rhs.minor &&
        lhs.patch == rhs.patch &&
        lhs.prerelease == rhs.prerelease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let parsed = SemanticVersion(string: str) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid semantic version: \(str)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
