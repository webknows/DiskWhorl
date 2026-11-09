import Foundation
import Darwin

/// A row of the kernel mount table (getmntinfo / statfs).
struct MountEntry: Hashable {
    let mountPoint: String
    let device: String
    let fsType: String
    let flags: UInt32
    let totalBytes: Int64
    let availableBytes: Int64

    static let flagReadOnly: UInt32 = 0x0000_0001
    static let flagRemovable: UInt32 = 0x0000_0200
    static let flagLocal: UInt32 = 0x0000_1000
    static let flagRootFS: UInt32 = 0x0000_4000
    static let flagDontBrowse: UInt32 = 0x0010_0000
    static let flagSnapshot: UInt32 = 0x4000_0000

    init(_ s: statfs) {
        mountPoint = MountEntry.string(from: s.f_mntonname)
        device = MountEntry.string(from: s.f_mntfromname)
        fsType = MountEntry.string(from: s.f_fstypename)
        flags = s.f_flags
        let blockSize = Int64(s.f_bsize)
        totalBytes = Int64(clamping: s.f_blocks) &* blockSize
        availableBytes = Int64(clamping: s.f_bavail) &* blockSize
    }

    var isLocal: Bool { flags & Self.flagLocal != 0 }
    var isReadOnly: Bool { flags & Self.flagReadOnly != 0 }
    var isRootFS: Bool { flags & Self.flagRootFS != 0 }
    var isBrowsable: Bool { flags & Self.flagDontBrowse == 0 }
    var isRemovableFlag: Bool { flags & Self.flagRemovable != 0 }

    /// "disk3" for "/dev/disk3s1s1"; nil for non-disk devices.
    var wholeDiskIdentifier: String? { Self.wholeDisk(fromDevice: device) }

    /// "disk3s5" for "/dev/disk3s5".
    var bsdName: String? {
        guard device.hasPrefix("/dev/") else { return nil }
        return String(device.dropFirst(5))
    }

    static func wholeDisk(fromDevice device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let rest = device.dropFirst(5) // "disk3s1s1"
        var result = "disk"
        for ch in rest.dropFirst(4) {
            if ch.isNumber { result.append(ch) } else { break }
        }
        return result == "disk" ? nil : result
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

enum MountTable {
    /// Current mounts without blocking on unresponsive network servers.
    static func entries() -> [MountEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var result: [MountEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            result.append(MountEntry(buffer[index]))
        }
        return result
    }

    static func entry(forPath path: String) -> MountEntry? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return MountEntry(s)
    }
}
