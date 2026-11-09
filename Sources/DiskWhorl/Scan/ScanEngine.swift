import Foundation
import Darwin

enum ScanMode: String {
    /// Scan one volume or folder, never crossing into other volumes.
    case plain
    /// Scan the startup disk as a whole: the sealed System volume, the Data volume
    /// (joined through firmlinks, exactly as Finder presents it) and the other mounted
    /// volumes of the same APFS container (Preboot, VM, Update…).
    case startupGroup
}

struct ScanRequest {
    var rootPath: String
    var rootName: String
    var mode: ScanMode
    var threads: Int
}

/// Entry point shared by in-process scans and the privileged helper.
enum ScanEngine {

    static let dataVolumePath = "/System/Volumes/Data"

    static func mode(forRootPath path: String) -> ScanMode {
        guard path == "/" else { return .plain }
        let data = MountTable.entry(forPath: dataVolumePath)
        return data?.mountPoint == dataVolumePath ? .startupGroup : .plain
    }

    /// Thread count tuned to the medium: many parallel requests saturate NVMe flash,
    /// while network and user-space (FUSE) file systems prefer fewer.
    static func recommendedThreads(forPath path: String) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard let mount = MountTable.entry(forPath: path) else { return max(4, cores) }
        let type = mount.fsType.lowercased()
        if !mount.isLocal || ["smbfs", "nfs", "afpfs", "webdav", "ftp"].contains(type) { return 4 }
        if type.contains("fuse") || type.contains("fskit") { return 3 }
        if mount.isRootFS || mount.mountPoint.hasPrefix("/System/Volumes") || mount.mountPoint == "/" {
            return min(16, max(6, cores + 2))
        }
        return min(8, max(4, cores / 2))
    }

    static func run(_ request: ScanRequest, progress: ScanProgress) -> FSNode? {
        switch request.mode {
        case .plain:
            guard let scanner = BulkScanner(rootPath: request.rootPath,
                                            threadCount: request.threads,
                                            progress: progress) else { return nil }
            let root = scanner.scan(rootName: request.rootName)
            FSNode.finalizeTree(root)
            return root
        case .startupGroup:
            return scanStartupGroup(request, progress: progress)
        }
    }

    // MARK: Startup disk (APFS volume group)

    private final class GroupResults: @unchecked Sendable {
        let lock = NSLock()
        var system: FSNode?
        var data: FSNode?
        var siblings: [(String, FSNode)] = []
    }

    private static func scanStartupGroup(_ request: ScanRequest, progress: ScanProgress) -> FSNode? {
        let mounts = MountTable.entries()
        guard let systemMount = mounts.first(where: { $0.mountPoint == "/" }) else { return nil }
        let container = systemMount.wholeDiskIdentifier
        let siblingPaths: [String] = mounts.compactMap { mount in
            guard mount.fsType == "apfs",
                  mount.mountPoint.hasPrefix("/System/Volumes/"),
                  mount.mountPoint != ScanEngine.dataVolumePath,
                  let container, mount.wholeDiskIdentifier == container else { return nil }
            return mount.mountPoint
        }

        let results = GroupResults()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let dataThreads = max(4, request.threads)

        queue.async(group: group) {
            guard let scanner = BulkScanner(rootPath: "/", threadCount: 4, progress: progress) else { return }
            let root = scanner.scan(rootName: request.rootName)
            results.lock.lock(); results.system = root; results.lock.unlock()
        }
        queue.async(group: group) {
            guard let scanner = BulkScanner(rootPath: ScanEngine.dataVolumePath, threadCount: dataThreads, progress: progress) else { return }
            let root = scanner.scan(rootName: "Data")
            results.lock.lock(); results.data = root; results.lock.unlock()
        }
        for path in siblingPaths {
            queue.async(group: group) {
                guard let scanner = BulkScanner(rootPath: path, threadCount: 2, progress: progress) else { return }
                let name = (path as NSString).lastPathComponent
                let root = scanner.scan(rootName: name)
                results.lock.lock(); results.siblings.append((path, root)); results.lock.unlock()
            }
        }
        group.wait()

        guard let systemRoot = results.system else { return nil }
        systemRoot.pathOverride = "/"

        if let dataRoot = results.data {
            merge(dataRoot, into: systemRoot,
                  sourceRealPath: dataVolumePath,
                  destinationLogicalPath: "/",
                  sourceDevice: device(ofPath: dataVolumePath))
        }
        for (mountPoint, siblingRoot) in results.siblings {
            let target = ensureFolder(atPath: mountPoint, in: systemRoot)
            merge(siblingRoot, into: target,
                  sourceRealPath: mountPoint,
                  destinationLogicalPath: mountPoint,
                  sourceDevice: device(ofPath: mountPoint))
        }
        FSNode.finalizeTree(systemRoot)
        return systemRoot
    }

    /// Grafts `source`'s children into `destination`, folding same-named folders together.
    /// Items whose logical path does not lead back to the same inode keep their real
    /// path in `pathOverride`, so Reveal, Quick Look and deletion always act on the right file.
    static func merge(_ source: FSNode, into destination: FSNode,
                      sourceRealPath: String, destinationLogicalPath: String,
                      sourceDevice: dev_t) {
        destination.flags.remove(.crossDevice)
        destination.flags.formUnion(source.flags.intersection([.inaccessible, .partial, .restricted, .package]))

        var index: [String: FSNode] = [:]
        for child in destination.children { index[child.name] = child }
        let samePlace = sourceRealPath == destinationLogicalPath

        for child in source.children {
            let realPath = join(sourceRealPath, child.name)
            let logicalPath = join(destinationLogicalPath, child.name)
            if let existing = index[child.name] {
                if existing.kind == .directory && child.kind == .directory {
                    merge(child, into: existing,
                          sourceRealPath: realPath,
                          destinationLogicalPath: logicalPath,
                          sourceDevice: sourceDevice)
                    continue
                }
                child.pathOverride = realPath
            } else if !samePlace && !resolves(logicalPath, toInode: child.fileID, device: sourceDevice) {
                child.pathOverride = realPath
            }
            child.parent = destination
            destination.children.append(child)
        }
        source.children = []
    }

    private static func ensureFolder(atPath path: String, in root: FSNode) -> FSNode {
        var node = root
        for component in path.split(separator: "/").map(String.init) {
            if let next = node.children.first(where: { $0.name == component && $0.kind == .directory }) {
                node = next
            } else {
                let created = FSNode(name: component, kind: .directory)
                created.parent = node
                node.children.append(created)
                node = created
            }
        }
        return node
    }

    private static func resolves(_ path: String, toInode inode: UInt64, device: dev_t) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return UInt64(st.st_ino) == inode && st.st_dev == device
    }

    static func device(ofPath path: String) -> dev_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : -1
    }

    private static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
