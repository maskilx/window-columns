import Foundation

/// Shared by the main actor and the serial AX writer. Cancellation is checked
/// while holding the frame service's write lock, so an old write cannot run
/// after a newer synchronous layout has already acquired that lock.
final class WindowFrameWriteSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
