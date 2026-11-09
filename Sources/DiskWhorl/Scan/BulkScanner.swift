import Foundation
import Darwin

/// Constants from <sys/attr.h>, <sys/vnode.h> and <sys/stat.h>, typed explicitly so the
/// bit arithmetic below never depends on how the C macros are imported.
enum AttrConst {
    static let bitmapCount: UInt16 = 5

    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000

    static let dirMountStatus: UInt32 = 0x0000_0004
    static let dirMountStatusMountPoint: UInt32 = 0x0000_0001

    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocSize: UInt32 = 0x0000_0004

    // fsobj_type_t (enum vtype)
    static let vReg: UInt32 = 1
    static let vDir: UInt32 = 2
    static let vLnk: UInt32 = 5

    // st_flags
    static let ufImmutable: UInt32 = 0x0000_0002
    static let sfImmutable: UInt32 = 0x0002_0000
    static let sfRestricted: UInt32 = 0x0008_0000
    static let sfNoUnlink: UInt32 = 0x0010_0000
    static let sfFirmlink: UInt32 = 0x0080_0000
    static let sfDataless: UInt32 = 0x4000_0000
}

/// Parallel, metadata-only directory walker built on getattrlistbulk(2).
///
/// One system call returns names, types, inode numbers, flags and allocated sizes for
/// a whole batch of directory entries, so the scan never stats files individually and
/// never opens file contents. Worker threads share a LIFO work stack; each folder is
/// owned by exactly one worker while it is listed, so tree construction needs no locks.
final class BulkScanner {

    private struct WorkItem {
        let node: FSNode
        let path: String
    }

    private struct LinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }

    let rootPath: String
    let rootDevice: dev_t
    private let threadCount: Int
    private let progress: ScanProgress

    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    private var activeWorkers = 0

    private let linkLock = NSLock()
    private var seenHardLinks = Set<LinkKey>()

    private static let bufferSize = 256 * 1024

    init?(rootPath: String, threadCount: Int, progress: ScanProgress) {
        var st = stat()
        guard stat(rootPath, &st) == 0 else { return nil }
        self.rootPath = rootPath
        self.rootDevice = st.st_dev
        self.threadCount = max(1, threadCount)
        self.progress = progress
    }

    /// Scans synchronously; call from a background thread. Returns an un-finalised tree
    /// (sizes on files only); call `FSNode.finalizeTree` once all merging is done.
    func scan(rootName: String) -> FSNode {
        let root = FSNode(name: rootName, kind: .directory)
        root.pathOverride = rootPath
        var st = stat()
        if stat(rootPath, &st) == 0 { root.fileID = UInt64(st.st_ino) }

        stack = [WorkItem(node: root, path: rootPath)]
        activeWorkers = 0

        let group = DispatchGroup()
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                self.workerLoop()
                group.leave()
            }
            thread.name = "DiskWhorl.scan.\(index)"
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        return root
    }

    // MARK: Worker

    private func workerLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            condition.lock()
            while stack.isEmpty && activeWorkers > 0 && !progress.isCancelled {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
            }
            if stack.isEmpty || progress.isCancelled {
                condition.broadcast()
                condition.unlock()
                return
            }
            let item = stack.removeLast()
            activeWorkers += 1
            condition.unlock()

            let subfolders = list(item, buffer: buffer)

            condition.lock()
            activeWorkers -= 1
            if !subfolders.isEmpty {
                stack.append(contentsOf: subfolders)
                condition.broadcast()
            } else if activeWorkers == 0 && stack.isEmpty {
                condition.broadcast()
            }
            condition.unlock()
        }
    }

    private func list(_ item: WorkItem, buffer: UnsafeMutableRawPointer) -> [WorkItem] {
        let isRoot = item.node.parent == nil
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (isRoot ? 0 : O_NOFOLLOW)
        let fd = open(item.path, flags)
        if fd < 0 {
            item.node.flags.insert(.inaccessible)
            progress.recordUnreadable()
            return []
        }
        defer { close(fd) }

        // Opening resolves firmlinks and mount points; never leave the scanned volume.
        var st = stat()
        if fstat(fd, &st) == 0, st.st_dev != rootDevice {
            item.node.flags.insert(.crossDevice)
            return []
        }

        if let result = bulkList(fd: fd, item: item, buffer: buffer) {
            return result
        }
        return fallbackList(fd: fd, item: item)
    }

    /// Returns nil when getattrlistbulk is unsupported on this file system, so the caller
    /// can fall back to readdir + fstatat.
    private func bulkList(fd: Int32, item: WorkItem, buffer: UnsafeMutableRawPointer) -> [WorkItem]? {
        var request = attrlist()
        request.bitmapcount = AttrConst.bitmapCount
        request.commonattr = AttrConst.cmnReturnedAttrs | AttrConst.cmnName | AttrConst.cmnError
            | AttrConst.cmnDevID | AttrConst.cmnObjType | AttrConst.cmnFlags | AttrConst.cmnFileID
        request.dirattr = AttrConst.dirMountStatus
        request.fileattr = AttrConst.fileLinkCount | AttrConst.fileTotalSize | AttrConst.fileAllocSize

        let parent = item.node
        let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
        var children: [FSNode] = []
        var subfolders: [WorkItem] = []
        var fileCount = 0
        var byteCount: Int64 = 0
        var receivedAny = false

        while !progress.isCancelled {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count < 0 {
                let err = errno
                if err == EINTR { continue }
                if !receivedAny && (err == ENOTSUP || err == EINVAL || err == ENOSYS) {
                    return nil
                }
                parent.flags.insert(.partial)
                break
            }
            if count == 0 { break }
            receivedAny = true

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }

                var field = entry + 4
                let returnedCommon = field.loadUnaligned(as: UInt32.self)
                let returnedDir = field.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                let returnedFile = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                field += 20 // attribute_set_t: five attrgroup_t values

                var entryError: UInt32 = 0
                if returnedCommon & AttrConst.cmnError != 0 {
                    entryError = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var name = ""
                if returnedCommon & AttrConst.cmnName != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    let cString = (field + offset).assumingMemoryBound(to: CChar.self)
                    name = String(cString: cString)
                    field += 8 // attrreference_t
                }
                var device: Int32 = 0
                if returnedCommon & AttrConst.cmnDevID != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var objectType: UInt32 = 0
                if returnedCommon & AttrConst.cmnObjType != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var statFlags: UInt32 = 0
                if returnedCommon & AttrConst.cmnFlags != 0 {
                    statFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returnedCommon & AttrConst.cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var mountStatus: UInt32 = 0
                if returnedDir & AttrConst.dirMountStatus != 0 {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var linkCount: UInt32 = 1
                if returnedFile & AttrConst.fileLinkCount != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var logical: Int64 = 0
                if returnedFile & AttrConst.fileTotalSize != 0 {
                    logical = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                var allocated: Int64 = 0
                if returnedFile & AttrConst.fileAllocSize != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += 8
                }

                if entryError != 0 || name.isEmpty || name == "." || name == ".." { continue }

                if objectType == AttrConst.vDir {
                    let child = FSNode(name: name, kind: .directory)
                    child.parent = parent
                    child.fileID = fileID
                    if statFlags & AttrConst.sfRestricted != 0 { child.flags.insert(.restricted) }
                    if FSNode.isPackageName(name) { child.flags.insert(.package) }
                    children.append(child)

                    let isMountPoint = mountStatus & AttrConst.dirMountStatusMountPoint != 0
                    let isFirmlink = statFlags & AttrConst.sfFirmlink != 0
                    let otherDevice = device != 0 && device != rootDevice
                    if isMountPoint || isFirmlink || otherDevice {
                        child.flags.insert(.crossDevice)
                    } else {
                        subfolders.append(WorkItem(node: child, path: prefix + name))
                    }
                } else {
                    let kind: FSNode.Kind
                    switch objectType {
                    case AttrConst.vReg: kind = .file
                    case AttrConst.vLnk: kind = .symlink
                    default: kind = .special
                    }
                    let child = FSNode(name: name, kind: kind)
                    child.parent = parent
                    child.fileID = fileID
                    child.fileCount = 1
                    child.logicalSize = logical
                    var physical = allocated
                    if linkCount > 1 && kind == .file && !registerHardLink(device: device, inode: fileID) {
                        physical = 0
                        child.flags.insert(.hardLinkDuplicate)
                    }
                    child.physicalSize = physical
                    if statFlags & AttrConst.sfRestricted != 0 { child.flags.insert(.restricted) }
                    if statFlags & AttrConst.sfDataless != 0 { child.flags.insert(.dataless) }
                    children.append(child)
                    fileCount += 1
                    byteCount += physical
                }
            }
        }

        parent.children = children
        progress.record(files: fileCount, folders: subfolders.count, bytes: byteCount, path: item.path)
        return subfolders
    }

    /// Portable path for file systems without getattrlistbulk support.
    private func fallbackList(fd: Int32, item: WorkItem) -> [WorkItem] {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            item.node.flags.insert(.inaccessible)
            progress.recordUnreadable()
            return []
        }
        defer { closedir(dir) }
        rewinddir(dir)

        let parent = item.node
        let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
        var children: [FSNode] = []
        var subfolders: [WorkItem] = []
        var fileCount = 0
        var byteCount: Int64 = 0

        while !progress.isCancelled, let entry = readdir(dir) {
            let nameLength = Int(entry.pointee.d_namlen)
            let name: String = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(nameLength), as: UTF8.self)
            }
            if name.isEmpty || name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            if type == S_IFDIR {
                let child = FSNode(name: name, kind: .directory)
                child.parent = parent
                child.fileID = UInt64(st.st_ino)
                if st.st_flags & AttrConst.sfRestricted != 0 { child.flags.insert(.restricted) }
                if FSNode.isPackageName(name) { child.flags.insert(.package) }
                children.append(child)
                if st.st_dev != rootDevice {
                    child.flags.insert(.crossDevice)
                } else {
                    subfolders.append(WorkItem(node: child, path: prefix + name))
                }
            } else {
                let kind: FSNode.Kind = type == S_IFREG ? .file : (type == S_IFLNK ? .symlink : .special)
                let child = FSNode(name: name, kind: kind)
                child.parent = parent
                child.fileID = UInt64(st.st_ino)
                child.fileCount = 1
                child.logicalSize = Int64(st.st_size)
                var physical = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 && kind == .file && !registerHardLink(device: st.st_dev, inode: UInt64(st.st_ino)) {
                    physical = 0
                    child.flags.insert(.hardLinkDuplicate)
                }
                child.physicalSize = physical
                if st.st_flags & AttrConst.sfRestricted != 0 { child.flags.insert(.restricted) }
                children.append(child)
                fileCount += 1
                byteCount += physical
            }
        }

        parent.children = children
        progress.record(files: fileCount, folders: subfolders.count, bytes: byteCount, path: item.path)
        return subfolders
    }

    /// Returns true the first time a (device, inode) pair is seen.
    private func registerHardLink(device: Int32, inode: UInt64) -> Bool {
        linkLock.lock()
        defer { linkLock.unlock() }
        return seenHardLinks.insert(LinkKey(device: device, inode: inode)).inserted
    }
}
