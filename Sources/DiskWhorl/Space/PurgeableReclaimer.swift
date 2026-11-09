import Foundation
import Darwin

/// Converts purgeable space into free space on request.
///
/// macOS releases purgeable data (local snapshots, evictable iCloud copies, caches
/// registered with the system) only when free space runs short. The reclaimer creates
/// that pressure deliberately: it reserves free space in a temporary file with
/// F_PREALLOCATE (metadata only, no data is written), waits while macOS purges, keeps
/// reserving until nothing purgeable is left or macOS stops releasing space, and then
/// deletes the file. A safety floor of free space is never consumed.
final class PurgeableReclaimer: @unchecked Sendable {

    struct Status {
        var reservedBytes: Int64
        var freeBytes: Int64
        var purgeableBytes: Int64
        var message: String
    }

    struct Report {
        var purgeableBefore: Int64
        var purgeableAfter: Int64
        var freeBefore: Int64
        var freeAfter: Int64
        var outcome: String
    }

    static let safetyFloor: Int64 = 1_500_000_000
    private static let chunk: Int64 = 2 << 30
    private static let stallTimeout: TimeInterval = 20
    private static let overallTimeout: TimeInterval = 240

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Removes leftovers if the app was interrupted during a previous run.
    static func cleanLeftovers() {
        let directory = workDirectory(forVolume: "/")
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("reclaim-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private static func workDirectory(forVolume volume: String) -> URL {
        if volume == "/" || volume == ScanEngine.dataVolumePath {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return caches.appendingPathComponent("DiskWhorl", isDirectory: true)
        }
        return URL(fileURLWithPath: volume, isDirectory: true).appendingPathComponent(".DiskWhorl-reclaim", isDirectory: true)
    }

    private func measure(_ volume: String) -> (free: Int64, purgeable: Int64)? {
        guard let capacity = VolumeInfo.capacity(ofPath: volume) else { return nil }
        let purgeable = max(0, (capacity.important ?? capacity.available) - capacity.available)
        return (capacity.available, purgeable)
    }

    /// Blocking. `update` is called from the worker thread.
    func run(volume: String, update: @escaping (Status) -> Void) -> Report {
        let start = measure(volume) ?? (0, 0)
        var report = Report(purgeableBefore: start.purgeable, purgeableAfter: start.purgeable,
                            freeBefore: start.free, freeAfter: start.free, outcome: "")

        let directory = Self.workDirectory(forVolume: volume)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reclaim-\(UUID().uuidString).tmp")
        let fd = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            report.outcome = "Could not create the temporary reservation file (\(String(cString: strerror(errno))))."
            return report
        }
        _ = fcntl(fd, F_NOCACHE, 1)

        var reserved: Int64 = 0
        var usePreallocate = true
        var lastGain = Date()
        var lastFree = start.free
        let deadline = Date().addingTimeInterval(Self.overallTimeout)
        var outcome = "Finished."

        while true {
            if isCancelled { outcome = "Cancelled."; break }
            if Date() > deadline { outcome = "Stopped after the time limit."; break }
            guard let now = measure(volume) else { outcome = "The volume stopped responding."; break }
            update(Status(reservedBytes: reserved, freeBytes: now.free, purgeableBytes: now.purgeable,
                          message: "Reserving free space so macOS releases purgeable data…"))
            if now.purgeable < 64 << 20 {
                outcome = "macOS released all purgeable space it reports."
                break
            }
            if now.free > lastFree + (128 << 20) { lastGain = Date() }
            lastFree = now.free

            let headroom = now.free - Self.safetyFloor
            if headroom > (256 << 20) {
                let amount = min(Self.chunk, headroom)
                if reserve(fd: fd, from: reserved, amount: amount, preallocate: &usePreallocate) {
                    reserved += amount
                    lastGain = Date()
                    continue
                }
            }
            if Date().timeIntervalSince(lastGain) > Self.stallTimeout {
                outcome = "macOS stopped releasing purgeable space; the remainder is held by data it will not purge yet."
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        close(fd)
        unlink(file.path)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path), items.isEmpty,
           directory.lastPathComponent == ".DiskWhorl-reclaim" {
            try? FileManager.default.removeItem(at: directory)
        }

        Thread.sleep(forTimeInterval: 1.0)
        let end = measure(volume) ?? start
        report.purgeableAfter = end.purgeable
        report.freeAfter = end.free
        report.outcome = outcome
        update(Status(reservedBytes: 0, freeBytes: end.free, purgeableBytes: end.purgeable, message: outcome))
        return report
    }

    /// Reserves `amount` more bytes at the end of the file. Prefers preallocation (no data
    /// written); falls back to writing zeros on file systems without F_PREALLOCATE.
    private func reserve(fd: Int32, from offset: Int64, amount: Int64, preallocate: inout Bool) -> Bool {
        if preallocate {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(amount), fst_bytesalloc: 0)
            if fcntl(fd, F_PREALLOCATE, &store) != -1 {
                return ftruncate(fd, off_t(offset + amount)) == 0
            }
            if errno == ENOSPC { return false }
            preallocate = false
        }
        let blockSize = 8 << 20
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 4096)
        defer { zeros.deallocate() }
        memset(zeros, 0, blockSize)
        var written: Int64 = 0
        _ = lseek(fd, off_t(offset), SEEK_SET)
        while written < amount {
            if isCancelled { return false }
            let toWrite = Int(min(Int64(blockSize), amount - written))
            let result = write(fd, zeros, toWrite)
            if result <= 0 { return false }
            written += Int64(result)
        }
        return true
    }
}
