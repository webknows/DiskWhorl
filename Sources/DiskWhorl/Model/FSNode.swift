import Foundation

/// One entry in the scanned hierarchy. Files and folders share the same class so the
/// map, the sidebar and the Collector can all refer to items uniformly.
///
/// Memory matters: a startup disk can hold several million entries, so the stored
/// properties are kept to the minimum needed for display, navigation and deletion.
/// Trees are built on scan threads and handed to the main thread only once complete,
/// hence the unchecked Sendable conformance.
final class FSNode: Identifiable, Hashable, @unchecked Sendable {

    enum Kind: UInt8 {
        case file = 0
        case directory = 1
        case symlink = 2
        /// Used space that no scannable file accounts for (snapshots, unreadable areas, metadata).
        case hiddenSpace = 3
        /// Space macOS reports as purgeable (reclaimable on demand).
        case purgeable = 4
        /// Device nodes, sockets, FIFOs.
        case special = 5
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        /// The folder could not be opened (permissions, TCC, I/O error).
        static let inaccessible = Flags(rawValue: 1 << 0)
        /// A mount point or firmlink that leads to another volume; not descended.
        static let crossDevice = Flags(rawValue: 1 << 1)
        /// A second (or later) hard link to a file that was already counted.
        static let hardLinkDuplicate = Flags(rawValue: 1 << 2)
        /// Protected by System Integrity Protection (SF_RESTRICTED) or immutable.
        static let restricted = Flags(rawValue: 1 << 3)
        /// Dataless placeholder (for example an iCloud file that was evicted).
        static let dataless = Flags(rawValue: 1 << 4)
        /// A bundle such as .app, .photoslibrary or .framework.
        static let package = Flags(rawValue: 1 << 5)
        /// Some descendants could not be read, so the size is a lower bound.
        static let partial = Flags(rawValue: 1 << 6)
    }

    var name: String
    var kind: Kind
    var flags: Flags = []
    /// Bytes actually allocated on disk (aggregated for folders).
    var physicalSize: Int64 = 0
    /// Apparent (logical) size in bytes (aggregated for folders).
    var logicalSize: Int64 = 0
    /// Number of files at or below this node.
    var fileCount: Int = 0
    /// Inode number (file ID) reported by the file system.
    var fileID: UInt64 = 0
    var children: [FSNode] = []
    weak var parent: FSNode?
    /// Absolute path when it cannot be derived from the parent chain
    /// (scan roots, and items merged in from another APFS volume of the group).
    var pathOverride: String?
    /// Friendly title for scan roots (for example "Macintosh HD").
    var displayName: String?

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    // MARK: Identity

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (lhs: FSNode, rhs: FSNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: Derived properties

    var isDirectory: Bool { kind == .directory }
    var isPseudo: Bool { kind == .hiddenSpace || kind == .purgeable }
    var isScanRoot: Bool { parent == nil }
    var title: String { displayName ?? name }

    var path: String {
        if let override = pathOverride { return override }
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    var depth: Int {
        var d = 0
        var cursor = parent
        while let c = cursor { d += 1; cursor = c.parent }
        return d
    }

    /// Root first, self last.
    var lineage: [FSNode] {
        var chain: [FSNode] = [self]
        var cursor = parent
        while let c = cursor { chain.append(c); cursor = c.parent }
        return chain.reversed()
    }

    var root: FSNode {
        var cursor = self
        while let p = cursor.parent { cursor = p }
        return cursor
    }

    func isDescendant(of other: FSNode) -> Bool {
        var cursor = parent
        while let c = cursor {
            if c === other { return true }
            cursor = c.parent
        }
        return false
    }

    func isSelfOrDescendant(of other: FSNode) -> Bool {
        self === other || isDescendant(of: other)
    }

    // MARK: Mutation after the scan

    /// Detaches this node from its parent and subtracts its sizes from every ancestor.
    func detachFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var cursor: FSNode? = parent
        while let c = cursor {
            c.physicalSize -= physicalSize
            c.logicalSize -= logicalSize
            c.fileCount -= fileCount
            cursor = c.parent
        }
        self.parent = nil
    }

    // MARK: Tree finalisation

    /// Aggregates sizes bottom-up, prunes empty cross-device placeholders and sorts
    /// children largest first. Iterative so deep hierarchies cannot overflow the stack.
    static func finalizeTree(_ root: FSNode) {
        var order: [FSNode] = []
        order.reserveCapacity(1 << 16)
        var stack: [FSNode] = [root]
        while let node = stack.popLast() {
            order.append(node)
            for child in node.children where child.kind == .directory {
                stack.append(child)
            }
        }
        for node in order.reversed() {
            node.children.removeAll { $0.flags.contains(.crossDevice) && $0.children.isEmpty }
            var physical: Int64 = 0
            var logical: Int64 = 0
            var count = 0
            var partial = false
            for child in node.children {
                physical += child.physicalSize
                logical += child.logicalSize
                count += child.fileCount
                if child.flags.contains(.inaccessible) || child.flags.contains(.partial) {
                    partial = true
                }
            }
            node.physicalSize = physical
            node.logicalSize = logical
            node.fileCount = count
            if partial { node.flags.insert(.partial) }
            if node.children.count > 1 {
                node.children.sort { $0.physicalSize > $1.physicalSize }
            }
        }
    }

    /// Resolves an absolute path to a node in this tree, if present.
    func descendant(atPath target: String) -> FSNode? {
        if path == target { return self }
        var queue: [FSNode] = [self]
        // Walk only along branches whose path is a prefix of the target.
        while let node = queue.popLast() {
            for child in node.children {
                let childPath = child.path
                if childPath == target { return child }
                if child.isDirectory, target.hasPrefix(childPath.hasSuffix("/") ? childPath : childPath + "/") {
                    queue.append(child)
                }
            }
        }
        return nil
    }

    /// Counts folders flagged as inaccessible below this node.
    func inaccessibleFolderCount() -> Int {
        var count = 0
        var stack: [FSNode] = [self]
        while let node = stack.popLast() {
            if node.flags.contains(.inaccessible) { count += 1 }
            if node.flags.contains(.partial) || node.flags.contains(.inaccessible) {
                for child in node.children where child.kind == .directory { stack.append(child) }
            }
        }
        return count
    }

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary",
        "tvlibrary", "photolibrary", "aplibrary", "fcpbundle", "logicx", "band", "xcodeproj",
        "xcworkspace", "playground", "rtfd", "pages", "numbers", "key", "sparsebundle",
        "vmwarevm", "pvm", "utm", "pkg", "mpkg", "imovielibrary", "theater", "lrdata", "lrlibrary",
        "dSYM", "appex", "xpc", "docset", "safari", "qlgenerator", "mdimporter", "prefPane", "saver"
    ]

    static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return packageExtensions.contains(String(ext))
    }
}
