import AppKit
import Combine

/// The staging tray. Items are gathered here, reviewed, confirmed, and only then moved
/// to the Trash after a short countdown during which the whole operation can be undone.
@MainActor
final class Collector: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let node: FSNode
        let verdict: SafetyGuard.Verdict
        var id: ObjectIdentifier { node.id }
        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.node === rhs.node && lhs.verdict == rhs.verdict }
    }

    struct Review: Identifiable {
        let id = UUID()
        let entries: [Entry]
        let blocked: [(String, String)]
        var totalBytes: Int64 { entries.reduce(0) { $0 + $1.node.physicalSize } }
        var needsAcknowledgement: Bool { entries.contains { if case .caution = $0.verdict { return true } else { return false } } }
    }

    struct Outcome: Identifiable {
        let id = UUID()
        var movedCount: Int
        var movedBytes: Int64
        var failures: [(node: FSNode, reason: String)]
        var permanentlyDeleted: Bool = false
    }

    @Published private(set) var entries: [Entry] = []
    @Published var notice: String?
    @Published var review: Review?
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var countdownTotal: Int = 5
    @Published private(set) var isDeleting = false
    @Published var outcome: Outcome?

    /// Called after items were removed from disk so the session can update the tree.
    var onRemoved: (([FSNode], Int64, Bool) -> Void)?

    private var pending: [FSNode] = []
    private var timer: Timer?
    private var noticeClear: DispatchWorkItem?

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.node.physicalSize } }
    var isBusy: Bool { countdownRemaining != nil || isDeleting }

    func contains(_ node: FSNode) -> Bool {
        entries.contains { node.isSelfOrDescendant(of: $0.node) }
    }

    // MARK: Gathering

    @discardableResult
    func add(_ node: FSNode) -> Bool {
        guard !isBusy else { show("Wait for the current deletion to finish."); return false }
        let verdict = SafetyGuard.evaluate(node)
        if case .blocked(let reason) = verdict {
            show("“\(node.title)” cannot be collected. \(reason)")
            NSSound.beep()
            return false
        }
        if let holder = entries.first(where: { node.isSelfOrDescendant(of: $0.node) }) {
            show(holder.node === node ? "“\(node.title)” is already in the Collector."
                                      : "Already covered by “\(holder.node.title)” in the Collector.")
            return false
        }
        let superseded = entries.filter { $0.node.isDescendant(of: node) }.count
        entries.removeAll { $0.node.isDescendant(of: node) }
        entries.append(Entry(node: node, verdict: verdict))
        if superseded > 0 {
            show("“\(node.title)” replaces \(superseded) item\(superseded == 1 ? "" : "s") it contains.")
        }
        return true
    }

    func remove(_ node: FSNode) {
        guard !isBusy else { return }
        entries.removeAll { $0.node === node }
    }

    func clear() {
        guard !isBusy else { return }
        entries.removeAll()
    }

    private func show(_ message: String) {
        notice = message
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.notice = nil }
        }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Review → confirm → countdown → Trash

    func beginReview() {
        guard !entries.isEmpty, !isBusy else { return }
        var allowed: [Entry] = []
        var blocked: [(String, String)] = []
        for entry in entries {
            let verdict = SafetyGuard.finalCheck(entry.node)
            if case .blocked(let reason) = verdict {
                blocked.append((entry.node.title, reason))
            } else {
                allowed.append(Entry(node: entry.node, verdict: verdict))
            }
        }
        // Items that fail the live check leave the Collector.
        let allowedSet = Set(allowed.map { $0.node })
        entries = entries.filter { allowedSet.contains($0.node) }
        review = Review(entries: allowed, blocked: blocked)
    }

    func confirmReview() {
        guard let review, !review.entries.isEmpty else { self.review = nil; return }
        pending = review.entries.map(\.node)
        self.review = nil
        let seconds = max(1, min(30, UserDefaults.standard.object(forKey: "undoSeconds") as? Int ?? 5))
        countdownTotal = seconds
        countdownRemaining = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func cancelReview() { review = nil }

    /// Cancels the pending deletion; nothing has been touched on disk yet.
    func undo() {
        timer?.invalidate()
        timer = nil
        countdownRemaining = nil
        pending = []
        show("Deletion cancelled. Nothing was moved to the Trash.")
    }

    private func tick() {
        guard let remaining = countdownRemaining else { return }
        if remaining > 1 {
            countdownRemaining = remaining - 1
        } else {
            timer?.invalidate()
            timer = nil
            countdownRemaining = nil
            performTrash()
        }
    }

    private func performTrash() {
        let items = pending.map { (node: $0, url: $0.url) }
        pending = []
        isDeleting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moved: [FSNode] = []
            var failures: [(node: FSNode, reason: String)] = []
            for item in items {
                do {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    moved.append(item.node)
                } catch {
                    failures.append((item.node, error.localizedDescription))
                }
            }
            let movedNodes = moved
            let failureList = failures
            Task { @MainActor [weak self] in self?.finish(moved: movedNodes, failures: failureList, permanent: false) }
        }
    }

    /// For items on volumes without a Trash (network shares, some FAT/exFAT media).
    func deletePermanently(_ nodes: [FSNode]) {
        guard !isBusy else { return }
        let items = nodes.filter { !SafetyGuard.finalCheck($0).isBlocked }.map { (node: $0, url: $0.url) }
        isDeleting = true
        outcome = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var removed: [FSNode] = []
            var failures: [(node: FSNode, reason: String)] = []
            for item in items {
                do {
                    try FileManager.default.removeItem(at: item.url)
                    removed.append(item.node)
                } catch {
                    failures.append((item.node, error.localizedDescription))
                }
            }
            let removedNodes = removed
            let failureList = failures
            Task { @MainActor [weak self] in self?.finish(moved: removedNodes, failures: failureList, permanent: true) }
        }
    }

    private func finish(moved: [FSNode], failures: [(node: FSNode, reason: String)], permanent: Bool) {
        isDeleting = false
        let bytes = moved.reduce(Int64(0)) { $0 + $1.physicalSize }
        let movedSet = Set(moved)
        entries.removeAll { movedSet.contains($0.node) }
        onRemoved?(moved, bytes, permanent)
        outcome = Outcome(movedCount: moved.count, movedBytes: bytes, failures: failures, permanentlyDeleted: permanent)
    }
}
