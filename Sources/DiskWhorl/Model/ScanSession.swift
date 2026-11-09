import AppKit
import Combine

/// One scan of one disk or folder: progress while running, then a static result that
/// the map, the sidebar and the Collector operate on. Results are never refreshed in
/// the background; changes made outside the app appear only after a rescan.
@MainActor
final class ScanSession: ObservableObject, Identifiable {

    enum State: Equatable {
        case scanning
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let rootPath: String
    let title: String
    let volume: VolumeInfo?
    let isVolumeScan: Bool
    let adminMode: Bool
    let mode: ScanMode
    let startedAt = Date()

    @Published private(set) var state: State = .scanning
    @Published private(set) var progressSnapshot = ScanProgress.Snapshot()
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var root: FSNode?
    @Published private(set) var accounting: SpaceAccounting?
    @Published private(set) var unreadableFolders = 0
    /// Bumped whenever the tree changes (after deletion), so the map re-lays itself out.
    @Published private(set) var revision = 0

    /// The folder at the centre of the map.
    @Published var center: FSNode?
    @Published var hovered: FSNode?
    @Published var selected: FSNode?
    @Published var showHiddenSpaceTools = false

    let collector = Collector()
    private(set) var draggedNodes: [FSNode] = []

    private let progress = ScanProgress()
    private var timer: Timer?
    private var helperDirectory: URL?
    private var cancelRequested = false

    init(rootPath: String, title: String, volume: VolumeInfo?, isVolumeScan: Bool, adminMode: Bool) {
        self.rootPath = rootPath
        self.title = title
        self.volume = volume
        self.isVolumeScan = isVolumeScan
        self.adminMode = adminMode
        self.mode = ScanEngine.mode(forRootPath: rootPath)
        collector.onRemoved = { [weak self] nodes, bytes, permanent in
            self?.applyRemoval(nodes, bytes: bytes, permanent: permanent)
        }
    }

    var isScanning: Bool { state == .scanning }
    var focusNode: FSNode? { hovered ?? selected ?? center }
    var quickLookCandidate: FSNode? {
        let node = hovered ?? selected
        return (node?.isPseudo ?? true) ? nil : node
    }

    // MARK: Running

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        if adminMode { startPrivileged() } else { startInProcess() }
    }

    func cancel() {
        guard isScanning else { return }
        cancelRequested = true
        progress.cancel()
        if let directory = helperDirectory {
            FileManager.default.createFile(atPath: directory.appendingPathComponent("cancel").path, contents: Data())
        }
    }

    private func makeRequest() -> ScanRequest {
        ScanRequest(rootPath: rootPath, rootName: title, mode: mode,
                    threads: ScanEngine.recommendedThreads(forPath: rootPath))
    }

    private func startInProcess() {
        let request = makeRequest()
        let progress = self.progress
        Thread.detachNewThread { [weak self] in
            let tree = ScanEngine.run(request, progress: progress)
            let error = tree == nil ? "Could not open \(request.rootPath)." : nil
            Task { @MainActor [weak self] in self?.complete(with: tree, error: error) }
        }
    }

    private func startPrivileged() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskWhorl-\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        helperDirectory = directory
        let output = directory.appendingPathComponent("tree.bin")
        let progressFile = directory.appendingPathComponent("progress.txt")
        let cancelFile = directory.appendingPathComponent("cancel")
        FileManager.default.createFile(atPath: output.path, contents: Data())
        FileManager.default.createFile(atPath: progressFile.path, contents: Data())

        guard let executable = Bundle.main.executablePath else {
            complete(with: nil, error: "Could not locate the DiskWhorl executable.")
            return
        }
        let request = makeRequest()
        let q = Privileged.shellQuote
        let command = [
            q(executable), "--helper-scan",
            "--root", q(request.rootPath),
            "--name", q(request.rootName),
            "--mode", request.mode.rawValue,
            "--threads", String(request.threads),
            "--out", q(output.path),
            "--progress", q(progressFile.path),
            "--cancel", q(cancelFile.path)
        ].joined(separator: " ")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Privileged.run(command, prompt: "DiskWhorl needs administrator access to measure folders your account cannot read.")
                let tree = try TreeCodec.read(from: output)
                Task { @MainActor [weak self] in self?.complete(with: tree, error: nil) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.complete(with: nil, error: message) }
            }
        }
    }

    private func poll() {
        if adminMode {
            if let directory = helperDirectory,
               let snapshot = HelperMain.readProgress(at: directory.appendingPathComponent("progress.txt").path) {
                progressSnapshot = snapshot
            }
        } else {
            progressSnapshot = progress.snapshot()
        }
        duration = Date().timeIntervalSince(startedAt)
    }

    private func complete(with tree: FSNode?, error: String?) {
        poll()
        timer?.invalidate()
        timer = nil
        if let directory = helperDirectory {
            try? FileManager.default.removeItem(at: directory)
            helperDirectory = nil
        }
        if cancelRequested {
            state = .cancelled
            return
        }
        guard let tree else {
            state = .failed(error ?? "The scan did not complete.")
            return
        }
        tree.displayName = title
        if isVolumeScan, let measured = SpaceAccounting.measure(path: rootPath, scanned: tree.physicalSize) {
            accounting = measured
            attachSpaceNodes(to: tree, accounting: measured)
        }
        unreadableFolders = tree.inaccessibleFolderCount()
        root = tree
        center = tree
        state = .finished
    }

    /// Adds "Hidden space" and "Purgeable space" segments to the root ring so the map's
    /// proportions match the used space the volume reports.
    private func attachSpaceNodes(to tree: FSNode, accounting: SpaceAccounting) {
        tree.children.removeAll { $0.isPseudo }
        func add(_ kind: FSNode.Kind, _ name: String, _ bytes: Int64) {
            guard bytes > 0 else { return }
            let node = FSNode(name: name, kind: kind)
            node.physicalSize = bytes
            node.logicalSize = bytes
            node.parent = tree
            tree.children.append(node)
            tree.physicalSize += bytes
        }
        add(.hiddenSpace, "Hidden space", accounting.hidden)
        add(.purgeable, "Purgeable space", accounting.purgeable)
        tree.children.sort { $0.physicalSize > $1.physicalSize }
    }

    // MARK: Navigation

    func navigate(to node: FSNode) {
        guard node.isDirectory else { return }
        center = node
        hovered = nil
    }

    func drill(into node: FSNode) {
        if node.isPseudo {
            showHiddenSpaceTools = true
            return
        }
        guard node.isDirectory, !node.children.isEmpty else {
            selected = node
            return
        }
        center = node
        selected = nil
        hovered = nil
    }

    func goUp() {
        if let parent = center?.parent {
            let previous = center
            center = parent
            selected = previous
        }
    }

    func goToRoot() {
        if let root { center = root }
    }

    func hover(_ node: FSNode?) {
        if hovered !== node { hovered = node }
    }

    func select(_ node: FSNode?) {
        if selected !== node { selected = node }
    }

    // MARK: Drag and drop into the Collector

    func beginDrag(_ nodes: [FSNode]) { draggedNodes = nodes }
    func endDrag() { draggedNodes = [] }

    func dropIntoCollector(_ providers: [NSItemProvider]) -> Bool {
        if !draggedNodes.isEmpty {
            for node in draggedNodes { collector.add(node) }
            draggedNodes = []
            return true
        }
        guard let root, let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let string = object as? NSString else { return }
            let path = string as String
            Task { @MainActor [weak self] in
                guard let self, let node = root.descendant(atPath: path) else { return }
                self.collector.add(node)
            }
        }
        return true
    }

    // MARK: After deletion

    private func applyRemoval(_ nodes: [FSNode], bytes: Int64, permanent: Bool) {
        for node in nodes {
            if let c = center, c.isSelfOrDescendant(of: node) { center = node.parent ?? root }
            if let h = hovered, h.isSelfOrDescendant(of: node) { hovered = nil }
            if let s = selected, s.isSelfOrDescendant(of: node) { selected = nil }
            node.detachFromParent()
        }
        if var updated = accounting {
            if permanent {
                updated.free += bytes
                updated.scanned -= bytes
            } else {
                updated.movedToTrash += bytes
            }
            accounting = updated
        }
        revision += 1
    }
}
