import AppKit
import Combine
import Darwin

/// App-wide state: the disk list, every scan session, the sidebar selection and Quick Look.
@MainActor
final class AppModel: ObservableObject {

    enum SidebarItem: Hashable {
        case volume(String)
        case session(UUID)
    }

    @Published var sessions: [ScanSession] = []
    @Published var selection: SidebarItem?
    @Published var previewURL: URL?
    @Published var adminMode: Bool = UserDefaults.standard.bool(forKey: "adminMode") {
        didSet { UserDefaults.standard.set(adminMode, forKey: "adminMode") }
    }
    @Published private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    let disks = DiskMonitor()
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init() {
        PurgeableReclaimer.cleanLeftovers()
        installKeyMonitor()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hasFullDiskAccess = FullDiskAccess.isGranted }
        }
    }

    // MARK: Selection

    var selectedSession: ScanSession? {
        guard case .session(let id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    var selectedVolume: VolumeInfo? {
        guard case .volume(let path) = selection else { return nil }
        return disks.volume(forMountPoint: path)
    }

    func latestSession(forPath path: String) -> ScanSession? {
        sessions.last { $0.rootPath == path }
    }

    // MARK: Starting scans

    @discardableResult
    func scan(volume: VolumeInfo, asAdministrator: Bool? = nil, select: Bool = true) -> ScanSession {
        let admin = (asAdministrator ?? adminMode) && volume.isLocal
        let session = ScanSession(rootPath: volume.mountPoint, title: volume.name, volume: volume,
                                  isVolumeScan: true, adminMode: admin)
        add(session, select: select)
        return session
    }

    func scanFolder(_ url: URL, asAdministrator: Bool? = nil) {
        let path = url.resolvingSymlinksInPath().path
        let mount = MountTable.entry(forPath: path)
        if let mount, mount.mountPoint == path {
            let volume = disks.volume(forMountPoint: path) ?? VolumeInfo.make(from: mount)
            scan(volume: volume, asAdministrator: asAdministrator)
            return
        }
        let title = FileManager.default.displayName(atPath: path)
        let session = ScanSession(rootPath: path, title: title, volume: nil, isVolumeScan: false,
                                  adminMode: asAdministrator ?? adminMode)
        add(session, select: true)
    }

    func scanStartupDisk() {
        if let startup = disks.volumes.first(where: { $0.isStartup }) {
            scan(volume: startup)
        } else if let entry = MountTable.entry(forPath: "/") {
            scan(volume: VolumeInfo.make(from: entry))
        }
    }

    /// Scans every local disk at the same time; each scan runs on its own worker pool.
    func scanAllLocalVolumes() {
        let targets = disks.volumes.filter { $0.isLocal && $0.category != .diskImage }
        var first: ScanSession?
        for volume in targets {
            if let existing = latestSession(forPath: volume.mountPoint), existing.isScanning { continue }
            let session = scan(volume: volume, select: false)
            if first == nil { first = session }
        }
        if let first { selection = .session(first.id) }
    }

    func rescan(_ session: ScanSession, asAdministrator: Bool? = nil) {
        let admin = asAdministrator ?? session.adminMode
        let replacement: ScanSession
        if let volume = disks.volume(forMountPoint: session.rootPath) ?? session.volume {
            replacement = ScanSession(rootPath: volume.mountPoint, title: volume.name, volume: volume,
                                      isVolumeScan: true, adminMode: admin && volume.isLocal)
        } else {
            replacement = ScanSession(rootPath: session.rootPath, title: session.title, volume: nil,
                                      isVolumeScan: session.isVolumeScan, adminMode: admin)
        }
        if let index = sessions.firstIndex(where: { $0 === session }) {
            session.cancel()
            sessions[index] = replacement
        } else {
            sessions.append(replacement)
        }
        selection = .session(replacement.id)
        replacement.start()
    }

    func close(_ session: ScanSession) {
        session.cancel()
        sessions.removeAll { $0 === session }
        if case .session(let id) = selection, id == session.id {
            selection = sessions.last.map { .session($0.id) }
        }
    }

    private func add(_ session: ScanSession, select: Bool) {
        sessions.append(session)
        if select { selection = .session(session.id) }
        session.start()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan."
        if panel.runModal() == .OK, let url = panel.url {
            scanFolder(url)
        }
    }

    // MARK: Item actions

    func quickLook(_ node: FSNode?) {
        guard let node, !node.isPseudo else { return }
        previewURL = node.url
    }

    func toggleQuickLook() {
        if previewURL != nil {
            previewURL = nil
        } else {
            quickLook(selectedSession?.quickLookCandidate)
        }
    }

    func reveal(_ node: FSNode?) {
        guard let node, !node.isPseudo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func copyPath(_ node: FSNode?) {
        guard let node, !node.isPseudo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func collect(_ node: FSNode?) {
        guard let node, let session = selectedSession else { return }
        session.collector.add(node)
    }

    var currentItem: FSNode? {
        guard let session = selectedSession else { return nil }
        return session.selected ?? session.hovered
    }

    // MARK: Space bar → Quick Look

    /// Space toggles Quick Look for the hovered or selected item, unless a text field has focus.
    /// Local event monitors run on the main thread; the assertion makes that explicit.
    nonisolated private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let consumed = MainActor.assumeIsolated { () -> Bool in
            self.consumeSpaceKey(event)
        }
        return consumed ? nil : event
    }

    private func consumeSpaceKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard event.keyCode == 49, modifiers.isEmpty else { return false }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText || responder is NSTextField {
            return false
        }
        if previewURL != nil {
            previewURL = nil
            return true
        }
        if let candidate = selectedSession?.quickLookCandidate {
            quickLook(candidate)
            return true
        }
        return false
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }
}

/// Detects whether Full Disk Access has been granted, using a file only readable with it.
enum FullDiskAccess {
    static var isGranted: Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
