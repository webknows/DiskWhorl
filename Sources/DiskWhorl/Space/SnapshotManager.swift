import Foundation

/// An APFS snapshot as reported by `diskutil apfs listSnapshots`.
struct APFSSnapshot: Identifiable, Hashable {
    enum Kind: String {
        case timeMachine = "Time Machine"
        case systemUpdate = "macOS system"
        case other = "Third-party / other"
    }

    var id: String { volumeMountPoint + "|" + (uuid.isEmpty ? name : uuid) }
    let volumeMountPoint: String
    let name: String
    let uuid: String
    let xid: UInt64?
    let purgeable: Bool?
    let limitsContainerShrink: Bool?

    var kind: Kind {
        if name.contains("com.apple.TimeMachine") { return .timeMachine }
        if name.hasPrefix("com.apple.os.update") || volumeMountPoint == "/" { return .systemUpdate }
        return .other
    }

    /// Snapshots that must never be deleted from here.
    var protectionReason: String? {
        if volumeMountPoint == "/" {
            return "Part of the sealed System volume the Mac starts up from."
        }
        if name.hasPrefix("com.apple.os.update") {
            return "Sealed system snapshot used to start up and update macOS."
        }
        return nil
    }

    /// "2026-11-09-103045" for "com.apple.TimeMachine.2026-11-09-103045.local".
    var timeMachineDate: String? {
        guard kind == .timeMachine,
              let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    /// Creator inferred from the reverse-DNS prefix ("com.bombich.ccc" → "com.bombich.ccc").
    var creator: String {
        switch kind {
        case .timeMachine: return "Time Machine"
        case .systemUpdate: return "macOS"
        case .other:
            let parts = name.split(separator: ".")
            return parts.count >= 3 ? parts.prefix(3).joined(separator: ".") : name
        }
    }
}

enum SnapshotManager {

    /// Lists snapshots on the given mounted APFS volumes. Blocking; call off the main thread.
    static func list(volumeMountPoints: [String]) -> [APFSSnapshot] {
        var all: [APFSSnapshot] = []
        for mountPoint in volumeMountPoints {
            let (status, output, _) = Privileged.runUnprivileged("/usr/sbin/diskutil",
                                                                ["apfs", "listSnapshots", "-plist", mountPoint])
            if status == 0, let parsed = parsePlist(output, mountPoint: mountPoint) {
                all.append(contentsOf: parsed)
                continue
            }
            let (textStatus, text, _) = Privileged.runUnprivileged("/usr/sbin/diskutil",
                                                                  ["apfs", "listSnapshots", mountPoint])
            if textStatus == 0 {
                all.append(contentsOf: parseText(text, mountPoint: mountPoint))
            }
        }
        return all
    }

    private static func parsePlist(_ output: String, mountPoint: String) -> [APFSSnapshot]? {
        guard let data = output.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        var dictionaries: [[String: Any]] = []
        if let root = object as? [String: Any] {
            if let list = root["Snapshots"] as? [[String: Any]] {
                dictionaries = list
            } else {
                for value in root.values {
                    if let list = value as? [[String: Any]] { dictionaries.append(contentsOf: list) }
                }
            }
        } else if let list = object as? [[String: Any]] {
            dictionaries = list
        }
        return dictionaries.compactMap { dict -> APFSSnapshot? in
            func find(_ keys: [String]) -> Any? {
                for key in keys { if let v = dict[key] { return v } }
                for (key, value) in dict where keys.contains(where: { key.localizedCaseInsensitiveContains($0) }) {
                    return value
                }
                return nil
            }
            guard let name = find(["SnapshotName", "Name"]) as? String else { return nil }
            let uuid = (find(["SnapshotUUID", "UUID"]) as? String) ?? ""
            var xid: UInt64?
            if let number = find(["SnapshotXID", "XID"]) as? NSNumber { xid = number.uint64Value }
            let purgeable = (find(["Purgeable"]) as? NSNumber)?.boolValue
            let limits = (find(["LimitingContainerShrink", "Limiting"]) as? NSNumber)?.boolValue
            return APFSSnapshot(volumeMountPoint: mountPoint, name: name, uuid: uuid, xid: xid,
                                purgeable: purgeable, limitsContainerShrink: limits)
        }
    }

    /// Fallback parser for the human-readable listing:
    ///     +-- 1885D22C-4B79-4406-86DA-E23AB9E5454F
    ///     |   Name:        com.apple.TimeMachine.2026-11-09-184430.local
    ///     |   XID:         545948
    ///     |   Purgeable:   Yes
    private static func parseText(_ text: String, mountPoint: String) -> [APFSSnapshot] {
        var result: [APFSSnapshot] = []
        var uuid: String?
        var name: String?
        var xid: UInt64?
        var purgeable: Bool?
        var limits: Bool?

        func flush() {
            if let name {
                result.append(APFSSnapshot(volumeMountPoint: mountPoint, name: name, uuid: uuid ?? "",
                                           xid: xid, purgeable: purgeable, limitsContainerShrink: limits))
            }
            uuid = nil; name = nil; xid = nil; purgeable = nil; limits = nil
        }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "|+- \t"))
            if line.count == 36, line.filter({ $0 == "-" }).count == 4, !line.contains(":") {
                flush()
                uuid = line
            } else if line.hasPrefix("Name:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("XID:") {
                xid = UInt64(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Purgeable:") {
                purgeable = line.localizedCaseInsensitiveContains("yes")
            } else if line.hasPrefix("NOTE:") && line.contains("limits the minimum size") {
                limits = true
            }
        }
        flush()
        return result
    }

    /// Deletes one snapshot with administrator privileges. Blocking.
    static func delete(_ snapshot: APFSSnapshot) throws {
        if let reason = snapshot.protectionReason {
            throw Privileged.PrivilegeError.failed("This snapshot is protected. \(reason)")
        }
        let command: String
        if let date = snapshot.timeMachineDate {
            command = "/usr/bin/tmutil deletelocalsnapshots \(Privileged.shellQuote(date))"
        } else if !snapshot.uuid.isEmpty {
            command = "/usr/sbin/diskutil apfs deleteSnapshot \(Privileged.shellQuote(snapshot.volumeMountPoint)) -uuid \(Privileged.shellQuote(snapshot.uuid))"
        } else if let xid = snapshot.xid {
            command = "/usr/sbin/diskutil apfs deleteSnapshot \(Privileged.shellQuote(snapshot.volumeMountPoint)) -xid \(xid)"
        } else {
            throw Privileged.PrivilegeError.failed("The snapshot has no identifier that diskutil accepts.")
        }
        try Privileged.run(command, prompt: "DiskWhorl needs administrator access to delete the snapshot “\(snapshot.name)”.")
    }

    /// Asks Time Machine to thin its local snapshots as much as possible (urgency 4).
    static func thinTimeMachineSnapshots(mountPoint: String) throws -> String {
        let args = ["thinlocalsnapshots", mountPoint, "999999999999999", "4"]
        let (status, output, error) = Privileged.runUnprivileged("/usr/bin/tmutil", args)
        if status == 0 { return output }
        let command = "/usr/bin/tmutil " + args.map(Privileged.shellQuote).joined(separator: " ")
        _ = error
        return try Privileged.run(command, prompt: "DiskWhorl needs administrator access to thin Time Machine snapshots.")
    }
}
