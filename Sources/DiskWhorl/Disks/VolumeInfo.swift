import Foundation
import DiskArbitration
import IOKit

/// Everything the app shows about a mounted volume.
struct VolumeInfo: Identifiable, Hashable {

    enum Category: Int, Comparable {
        case startup = 0, internalDisk, external, removable, diskImage, userSpace, network
        static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .startup: return "Startup disk"
            case .internalDisk: return "Internal"
            case .external: return "External"
            case .removable: return "Removable media"
            case .diskImage: return "Disk image"
            case .userSpace: return "User-space file system"
            case .network: return "Network"
            }
        }
    }

    var id: String { mountPoint }
    let mountPoint: String
    var name: String
    let device: String
    let fsType: String
    var formatDescription: String
    var totalBytes: Int64
    var availableBytes: Int64
    var importantAvailableBytes: Int64?
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    var isLocal: Bool
    var isReadOnly: Bool
    var isBrowsable: Bool
    var deviceProtocol: String?
    var deviceModel: String?
    var mediumType: String?
    var category: Category

    var isStartup: Bool { mountPoint == "/" }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var purgeableBytes: Int64 { max(0, (importantAvailableBytes ?? availableBytes) - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    var symbolName: String {
        switch category {
        case .startup: return "internaldrive.fill"
        case .internalDisk: return "internaldrive"
        case .external: return "externaldrive.fill"
        case .removable: return "sdcard.fill"
        case .diskImage: return "opticaldiscdrive"
        case .userSpace: return "puzzlepiece.extension"
        case .network: return "server.rack"
        }
    }

    var fileSystemLabel: String {
        switch fsType.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return formatDescription.isEmpty ? "HFS+" : formatDescription
        case "msdos": return formatDescription.isEmpty ? "FAT" : formatDescription
        case "exfat": return "exFAT"
        case "ntfs": return "NTFS"
        case "smbfs": return "SMB"
        case "nfs": return "NFS"
        case "afpfs": return "AFP"
        case "webdav": return "WebDAV"
        case "cd9660": return "ISO 9660"
        case "udf": return "UDF"
        default:
            let lower = fsType.lowercased()
            if lower.contains("fuse") { return "FUSE (\(fsType))" }
            return formatDescription.isEmpty ? fsType.uppercased() : formatDescription
        }
    }

    /// "SSD · PCI-Express", "USB", "Network"…
    var mediaLabel: String {
        var parts: [String] = []
        if let medium = mediumType {
            parts.append(medium == "Solid State" ? "SSD" : (medium == "Rotational" ? "HDD" : medium))
        }
        if let proto = deviceProtocol, !proto.isEmpty { parts.append(proto) }
        if !isLocal { parts.append("Network") }
        if isReadOnly { parts.append("Read-only") }
        return parts.joined(separator: " · ")
    }

    // MARK: Discovery

    /// Builds the current volume list. Safe to call off the main thread.
    static func currentVolumes(includeSystem: Bool) -> [VolumeInfo] {
        var seen = Set<String>()
        var result: [VolumeInfo] = []
        for entry in MountTable.entries() {
            let type = entry.fsType.lowercased()
            if ["devfs", "autofs", "nullfs"].contains(type) { continue }
            if entry.mountPoint == "/dev" { continue }
            let isRoot = entry.mountPoint == "/"
            if !isRoot {
                if entry.flags & MountEntry.flagSnapshot != 0 { continue }
                if !includeSystem && (!entry.isBrowsable || entry.mountPoint.hasPrefix("/System/Volumes/")) { continue }
            }
            guard seen.insert(entry.mountPoint).inserted else { continue }
            result.append(make(from: entry))
        }
        return result.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func make(from entry: MountEntry) -> VolumeInfo {
        let url = URL(fileURLWithPath: entry.mountPoint, isDirectory: true)
        var name = (entry.mountPoint as NSString).lastPathComponent
        var formatDescription = ""
        var total = entry.totalBytes
        var available = entry.availableBytes
        var important: Int64?
        var isInternal = false
        var isRemovable = entry.isRemovableFlag
        var isEjectable = false

        if entry.isLocal {
            let keys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey
            ]
            if let values = try? url.resourceValues(forKeys: keys) {
                if let n = values.volumeName, !n.isEmpty { name = n }
                formatDescription = values.volumeLocalizedFormatDescription ?? ""
                if let t = values.volumeTotalCapacity { total = Int64(t) }
                if let a = values.volumeAvailableCapacity { available = Int64(a) }
                important = values.volumeAvailableCapacityForImportantUsage
                isInternal = values.volumeIsInternal ?? false
                isRemovable = values.volumeIsRemovable ?? isRemovable
                isEjectable = values.volumeIsEjectable ?? false
            }
        }
        if entry.mountPoint == "/" && name == "/" { name = "Macintosh HD" }

        let details = DiskDetails.lookup(device: entry.device, mountPoint: entry.mountPoint)
        if let detailsInternal = details.isInternal { isInternal = detailsInternal }
        if let removable = details.isRemovable { isRemovable = isRemovable || removable }
        if let ejectable = details.isEjectable { isEjectable = isEjectable || ejectable }

        var medium = details.mediumType
        #if arch(arm64)
        if medium == nil && isInternal && entry.isLocal {
            // Every Apple silicon Mac has internal flash storage. (Intel Macs may have a
            // hard disk or Fusion Drive, so no assumption is made there.)
            medium = "Solid State"
        }
        #endif

        let type = entry.fsType.lowercased()
        let category: Category
        if entry.mountPoint == "/" {
            category = .startup
        } else if !entry.isLocal || ["smbfs", "nfs", "afpfs", "webdav", "ftp"].contains(type) {
            category = .network
        } else if type.contains("fuse") {
            category = .userSpace
        } else if let proto = details.deviceProtocol, proto == "Disk Image" || proto == "Virtual Interface" {
            category = .diskImage
        } else if isRemovable && !isInternal {
            category = .removable
        } else if isInternal {
            category = .internalDisk
        } else {
            category = .external
        }

        return VolumeInfo(
            mountPoint: entry.mountPoint,
            name: name,
            device: entry.device,
            fsType: entry.fsType,
            formatDescription: formatDescription,
            totalBytes: total,
            availableBytes: available,
            importantAvailableBytes: important,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            isLocal: entry.isLocal,
            isReadOnly: entry.isReadOnly,
            isBrowsable: entry.isBrowsable,
            deviceProtocol: details.deviceProtocol,
            deviceModel: details.deviceModel,
            mediumType: medium,
            category: category
        )
    }

    /// Fresh capacity figures for one volume (bypassing URL resource caches).
    static func capacity(ofPath path: String) -> (total: Int64, available: Int64, important: Int64?)? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
            return (Int64(total), Int64(available), values.volumeAvailableCapacityForImportantUsage)
        }
        if let entry = MountTable.entry(forPath: path) {
            return (entry.totalBytes, entry.availableBytes, nil)
        }
        return nil
    }
}

/// Hardware details from Disk Arbitration and the I/O Registry, cached per device.
enum DiskDetails {
    struct Info {
        var deviceProtocol: String?
        var deviceModel: String?
        var mediumType: String?
        var isInternal: Bool?
        var isRemovable: Bool?
        var isEjectable: Bool?
    }

    private static let lock = NSLock()
    private static var cache: [String: Info] = [:]
    private static let session: DASession? = DASessionCreate(kCFAllocatorDefault)

    static func lookup(device: String, mountPoint: String) -> Info {
        lock.lock()
        if let cached = cache[device] { lock.unlock(); return cached }
        lock.unlock()

        var info = Info()
        if device.hasPrefix("/dev/"), let session {
            let url = URL(fileURLWithPath: mountPoint, isDirectory: true) as CFURL
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url),
               let description = DADiskCopyDescription(disk) as? [String: Any] {
                info.deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
                if let model = description[kDADiskDescriptionDeviceModelKey as String] as? String {
                    info.deviceModel = model.trimmingCharacters(in: .whitespaces)
                }
                info.isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                info.isRemovable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool
                info.isEjectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool
            }
            if let whole = MountEntry.wholeDisk(fromDevice: device) {
                info.mediumType = mediumType(bsdName: whole)
            }
        }

        lock.lock()
        cache[device] = info
        lock.unlock()
        return info
    }

    /// Reads "Medium Type" (Solid State / Rotational) from the nearest storage device
    /// above the given BSD disk in the I/O Registry.
    private static func mediumType(bsdName: String) -> String? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                                                           "Device Characteristics" as CFString,
                                                           kCFAllocatorDefault, options) else { return nil }
        if let characteristics = value as? [String: Any] {
            return characteristics["Medium Type"] as? String
        }
        return nil
    }
}
