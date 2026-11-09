import Foundation

/// Thread-safe progress counters shared by every worker thread of a scan.
final class ScanProgress: @unchecked Sendable {
    struct Snapshot {
        var files: Int = 0
        var folders: Int = 0
        var bytes: Int64 = 0
        var unreadable: Int = 0
        var currentPath: String = ""
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var cancelled = false

    func record(files: Int, folders: Int, bytes: Int64, path: String) {
        lock.lock()
        state.files += files
        state.folders += folders
        state.bytes += bytes
        state.currentPath = path
        lock.unlock()
    }

    func recordUnreadable() {
        lock.lock()
        state.unreadable += 1
        lock.unlock()
    }

    /// Used by the in-app reader of a privileged helper's progress file.
    func overwrite(with snapshot: Snapshot) {
        lock.lock()
        state = snapshot
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
