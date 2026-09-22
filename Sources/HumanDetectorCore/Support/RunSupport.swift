import Foundation

/// Thread-safe cancellation flag shared between the UI and worker tasks.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Lightweight, non-fatal diagnostics collected during a run.
public final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    public init() {}

    public func add(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
