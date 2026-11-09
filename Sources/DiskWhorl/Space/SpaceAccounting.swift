import Foundation

/// Reconciles what the volume reports as used with what the scan could see.
///
///     used       = capacity − free          (free excludes purgeable space)
///     purgeable  = free for important use − free
///     hidden     = used − purgeable − scanned
///
/// Hidden space is therefore everything that occupies the disk but is not a file the
/// scan could measure: APFS snapshots, unmounted system volumes such as Recovery,
/// folders the scan was not allowed to read, and file-system metadata.
struct SpaceAccounting: Equatable {
    var capacity: Int64
    var free: Int64
    var freeForImportantUse: Int64?
    var scanned: Int64
    /// Bytes this session has moved to the Trash (still occupying space until emptied).
    var movedToTrash: Int64 = 0

    var used: Int64 { max(0, capacity - free) }
    var purgeable: Int64 { max(0, (freeForImportantUse ?? free) - free) }
    var hidden: Int64 { max(0, used - purgeable - scanned) }
    /// When positive, the scan counted more than the volume reports as used, which
    /// happens with APFS clones (copies that share blocks).
    var overcount: Int64 { max(0, scanned - (used - purgeable)) }

    static func measure(path: String, scanned: Int64) -> SpaceAccounting? {
        guard let capacity = VolumeInfo.capacity(ofPath: path) else { return nil }
        return SpaceAccounting(capacity: capacity.total,
                               free: capacity.available,
                               freeForImportantUse: capacity.important,
                               scanned: scanned)
    }
}
