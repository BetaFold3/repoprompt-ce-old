import Foundation

/// Reopenable gate for the binding engine's pre-publication hook. While closed, every request
/// that reaches it parks; opening resumes them all and lets later ones through until closed again.
final class CodemapReopenablePublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredPaths: [String] = []
    private var passedPaths: [String] = []

    /// Paths that reached the gate, in arrival order.
    var entered: [String] {
        lock.withLock { enteredPaths }
    }

    /// Paths that went through the gate (it was open, or it opened while they waited).
    var passed: [String] {
        lock.withLock { passedPaths }
    }

    func pass(_ path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock { () -> Bool in
                enteredPaths.append(path)
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if proceed {
                continuation.resume()
            }
        }
        lock.withLock { passedPaths.append(path) }
    }

    func waitUntilEntered(_ path: String, timeout: TimeInterval = 30) async throws {
        try await AsyncTestWait.waitUntil("\(path) reached the publication gate", timeout: timeout) {
            self.entered.contains(path)
        }
    }

    func waitUntilPassed(_ path: String, timeout: TimeInterval = 30) async throws {
        try await AsyncTestWait.waitUntil("\(path) went through the publication gate", timeout: timeout) {
            self.passed.contains(path)
        }
    }

    func open() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in resumed {
            continuation.resume()
        }
    }

    func close() {
        lock.withLock { isOpen = false }
    }
}
