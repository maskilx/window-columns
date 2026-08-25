import Foundation

/// The parts of a window that identify it across time.
public struct WindowIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let title: String
    public let windowNumber: UInt32?

    public init(bundleIdentifier: String, title: String, windowNumber: UInt32?) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowNumber = windowNumber
    }
}

/// Maps the windows saved with a group onto the windows that exist right now.
///
/// WindowServer numbers are reassigned whenever a window is closed and reopened,
/// and titles change as the user works, so a single strict rule breaks a group
/// permanently the first time its application restarts. Progressively weaker
/// passes run in order, and each pass may only claim windows that the stronger
/// passes left unclaimed, so an exact match never loses to a fuzzy one.
public enum WindowMatcher {
    /// - Returns: indexes into `available`, in the order of `saved`. Entries
    ///   that could not be matched are omitted, so the result may be shorter
    ///   than `saved`.
    public static func resolve(saved: [WindowIdentity], available: [WindowIdentity]) -> [Int] {
        var remaining = Set(available.indices)
        var matches: [Int: Int] = [:]

        func pass(uniqueOnly: Bool, _ isMatch: (WindowIdentity, WindowIdentity) -> Bool) {
            for (offset, identity) in saved.enumerated() where matches[offset] == nil {
                let candidates = remaining
                    .filter { isMatch(identity, available[$0]) }
                    .sorted()
                guard let index = uniqueOnly ? (candidates.count == 1 ? candidates.first : nil)
                                             : candidates.first else { continue }
                matches[offset] = index
                remaining.remove(index)
            }
        }

        // 1. The exact window it was when the group was saved.
        pass(uniqueOnly: false) { identity, window in
            guard let number = identity.windowNumber else { return false }
            return window.bundleIdentifier == identity.bundleIdentifier && window.windowNumber == number
        }
        // 2. Same application and title, and unambiguous.
        pass(uniqueOnly: true) { identity, window in
            window.bundleIdentifier == identity.bundleIdentifier && window.title == identity.title
        }
        // 3. Same application and title among several identically titled windows.
        pass(uniqueOnly: false) { identity, window in
            window.bundleIdentifier == identity.bundleIdentifier && window.title == identity.title
        }
        // 4. Titles changed too — a browser retitles its window on every
        //    navigation, so this is common after an application restarts. Pair
        //    what is left by application, but only when the counts agree
        //    exactly; a mismatch means guessing, and a wrong window is worse
        //    than a group with one member missing.
        let unmatchedByBundle = Dictionary(
            grouping: saved.indices.filter { matches[$0] == nil },
            by: { saved[$0].bundleIdentifier }
        )
        let remainingByBundle = Dictionary(
            grouping: remaining.sorted(),
            by: { available[$0].bundleIdentifier }
        )
        for (bundleIdentifier, offsets) in unmatchedByBundle {
            guard let candidates = remainingByBundle[bundleIdentifier],
                  candidates.count == offsets.count else { continue }
            for (offset, index) in zip(offsets.sorted(), candidates) {
                matches[offset] = index
                remaining.remove(index)
            }
        }

        return saved.indices.compactMap { matches[$0] }
    }
}
