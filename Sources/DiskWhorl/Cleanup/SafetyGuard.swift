import AppKit
import Darwin

/// Safety stoppers: decides whether an item may be deleted at all, and whether the user
/// must acknowledge a specific risk first. Checks run when an item enters the Collector
/// and again, against the live file system, immediately before deletion.
enum SafetyGuard {

    enum Verdict: Equatable {
        case allowed
        case caution(String)
        case blocked(String)

        var isBlocked: Bool { if case .blocked = self { return true } else { return false } }
        var message: String? {
            switch self {
            case .allowed: return nil
            case .caution(let m), .blocked(let m): return m
            }
        }
    }

    private static let home = NSHomeDirectory()

    /// Folders that may never be removed themselves (their contents are judged separately).
    private static var protectedFolders: Set<String> {
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/sbin",
            "/usr", "/usr/local", "/private", "/etc", "/var", "/tmp", "/cores", "/opt", "/dev",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
            "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/Extensions",
            "/Library/Frameworks", "/Library/Keychains", "/Library/Security", "/Library/Logs"
        ]
        let userFolders = ["", "/Library", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music",
                           "/Pictures", "/Public", "/Applications", "/.Trash", "/Library/Application Support",
                           "/Library/Caches", "/Library/Containers", "/Library/Group Containers",
                           "/Library/Preferences", "/Library/Mobile Documents", "/Library/CloudStorage",
                           "/Library/Mail", "/Library/Messages", "/Library/Photos"]
        for suffix in userFolders { set.insert(home + suffix) }
        return set
    }

    /// Whole trees that are off limits.
    private static let protectedTrees: [String] = [
        "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/",
        "/usr/share/", "/usr/standalone/", "/private/var/db/", "/private/var/vm/", "/private/var/folders/",
        "/private/var/protected/", "/private/var/root/", "/private/etc/", "/Library/Apple/",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.vol/", "/.PreviousSystemInformation",
        "/dev/", "/Library/Keychains/", "/Library/Security/", "/Library/SystemExtensions/"
    ]

    private static let ownKeychains = "/Library/Keychains/"

    // MARK: Evaluation

    /// Fast check on scan data, used when an item is collected.
    static func evaluate(_ node: FSNode) -> Verdict {
        if node.isPseudo {
            return .blocked("This is a summary of space, not a file. Use the Hidden Space tools instead.")
        }
        if node.isScanRoot {
            return .blocked("The scanned disk or folder itself cannot be deleted.")
        }
        if node.flags.contains(.restricted) {
            return .blocked("Protected by System Integrity Protection.")
        }
        return evaluate(path: node.path, isDirectory: node.isDirectory)
    }

    static func evaluate(path rawPath: String, isDirectory: Bool) -> Verdict {
        let path = (rawPath as NSString).standardizingPath
        if protectedFolders.contains(path) {
            return .blocked("A folder macOS or your account depends on.")
        }
        let withSlash = path + "/"
        for tree in protectedTrees where withSlash.hasPrefix(tree) || path == tree {
            return .blocked("Inside a protected system location (\(tree)).")
        }
        if path.hasPrefix(home + ownKeychains) {
            return .blocked("Contains your keychains.")
        }
        let bundle = Bundle.main.bundlePath
        if path == bundle || withSlash.hasPrefix(bundle + "/") {
            return .blocked("This is DiskWhorl itself.")
        }
        if path.hasPrefix("/System/Volumes/") {
            return .blocked("Inside a system volume of the startup disk.")
        }

        // Caution tier: allowed after explicit acknowledgement.
        if let appRange = path.range(of: ".app/") {
            let appPath = String(path[..<appRange.lowerBound]) + ".app"
            return .caution("Inside the application \((appPath as NSString).lastPathComponent). Removing parts of an app breaks its code signature.")
        }
        if path.hasSuffix(".app"), isRunningApplication(at: path) {
            return .caution("This application is running. Quit it before deleting.")
        }
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") {
            return .caution("A cloud-synced item. Deleting it removes it from every device signed in to the account.")
        }
        if path.hasPrefix(home + "/Library/") {
            return .caution("Application data in your Library. Apps may lose settings, caches or documents.")
        }
        if path.hasPrefix("/Library/") {
            return .caution("A system-wide support location shared by all users.")
        }
        if path.hasPrefix("/Applications/") && !path.hasSuffix(".app") {
            return .caution("Inside the Applications folder.")
        }
        if path.hasPrefix("/private/") {
            return .caution("A Unix system location.")
        }
        if path.hasSuffix(".photoslibrary") || path.hasSuffix(".musiclibrary") {
            return .caution("A media library. Every item in it would be removed.")
        }
        return .allowed
    }

    /// Re-validates against the live file system right before deletion.
    static func finalCheck(_ node: FSNode) -> Verdict {
        let base = evaluate(node)
        if base.isBlocked { return base }
        let path = node.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .blocked("The item no longer exists at this location.")
        }
        let guarded = AttrConst.sfRestricted | AttrConst.sfImmutable | AttrConst.ufImmutable | AttrConst.sfNoUnlink
        if st.st_flags & guarded != 0 {
            return .blocked("The file system marks this item as protected or locked.")
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        var parentStat = stat()
        if lstat(parentPath, &parentStat) == 0, parentStat.st_dev != st.st_dev {
            return .blocked("This is the mount point of another volume.")
        }
        return base
    }

    private static func isRunningApplication(at path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }
}
