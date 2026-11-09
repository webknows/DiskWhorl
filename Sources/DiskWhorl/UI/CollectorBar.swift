import SwiftUI
import UniformTypeIdentifiers

/// The Collector tray along the bottom of the result window.
struct CollectorBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    @ObservedObject var collector: Collector
    @StateObject private var isTargeted = ViewState(false)
    @StateObject private var confirmPermanent = ViewState<[FSNode]>([])
    @StateObject private var showPermanentConfirmation = ViewState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let remaining = collector.countdownRemaining {
                CountdownBanner(remaining: remaining, total: collector.countdownTotal,
                                count: collector.entries.count, bytes: collector.totalBytes) {
                    collector.undo()
                }
            } else if collector.isDeleting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Moving items to the Trash…").font(.callout)
                }
            } else if let outcome = collector.outcome {
                OutcomeBanner(outcome: outcome,
                              onDismiss: { collector.outcome = nil },
                              onDeletePermanently: { nodes in
                                  confirmPermanent.value = nodes
                                  showPermanentConfirmation.value = true
                              })
            }

            HStack(alignment: .center, spacing: 10) {
                Label("Collector", systemImage: collector.entries.isEmpty ? "tray" : "tray.full")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)

                if collector.entries.isEmpty {
                    Text("Drag arcs or list rows here, or press ⌘⌫, to stage items for deletion. Nothing is removed until you confirm.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(collector.entries) { entry in
                                CollectorChip(entry: entry, disabled: collector.isBusy) {
                                    collector.remove(entry.node)
                                } onSelect: {
                                    if let parent = entry.node.parent { session.navigate(to: parent) }
                                    session.select(entry.node)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text(ByteFormat.string(collector.totalBytes))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Button("Clear") { collector.clear() }
                        .disabled(collector.isBusy)
                    Button(role: .destructive) {
                        collector.beginReview()
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                    .disabled(collector.isBusy)
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .help("Review and move the collected items to the Trash (⇧⌘⌫)")
                }
            }

            if let notice = collector.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(isTargeted.value ? Color.accentColor.opacity(0.16) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if isTargeted.value {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .onDrop(of: [UTType.plainText, UTType.utf8PlainText], isTargeted: $isTargeted.value) { providers in
            session.dropIntoCollector(providers)
        }
        .sheet(item: $collector.review) { review in
            DeletionReviewSheet(review: review, collector: collector)
        }
        .confirmationDialog("Delete permanently?", isPresented: $showPermanentConfirmation.value) {
            Button("Delete \(confirmPermanent.value.count) Item\(confirmPermanent.value.count == 1 ? "" : "s") Permanently", role: .destructive) {
                collector.deletePermanently(confirmPermanent.value)
                confirmPermanent.value = []
            }
            Button("Cancel", role: .cancel) { confirmPermanent.value = [] }
        } message: {
            Text("These items could not be moved to the Trash, usually because their volume has no Trash. Permanent deletion cannot be undone.")
        }
        .animation(.easeOut(duration: 0.15), value: collector.notice)
    }
}

private struct CollectorChip: View {
    let entry: Collector.Entry
    let disabled: Bool
    let onRemove: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ItemIcon(node: entry.node, size: 16)
            Text(entry.node.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(maxWidth: 160)
            Text(ByteFormat.string(entry.node.physicalSize))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if case .caution = entry.verdict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help("Remove from the Collector")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .help(entry.verdict.message.map { entry.node.path + "\n" + $0 } ?? entry.node.path)
    }
}

private struct CountdownBanner: View {
    let remaining: Int
    let total: Int
    let count: Int
    let bytes: Int64
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, total)))
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(remaining)").font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
            .frame(width: 26, height: 26)
            Text("Moving \(count) item\(count == 1 ? "" : "s") (\(ByteFormat.string(bytes))) to the Trash in \(remaining) s.")
                .font(.callout)
            Spacer()
            Button("Undo", action: onUndo)
                .keyboardShortcut("z", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OutcomeBanner: View {
    let outcome: Collector.Outcome
    let onDismiss: () -> Void
    let onDeletePermanently: ([FSNode]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.failures.isEmpty ? Color.green : Color.orange)
                Text(headline).font(.callout)
                Spacer()
                if !outcome.failures.isEmpty && !outcome.permanentlyDeleted {
                    Button("Delete Permanently…") { onDeletePermanently(outcome.failures.map { $0.node }) }
                        .controlSize(.small)
                }
                Button("Dismiss", action: onDismiss).controlSize(.small)
            }
            ForEach(0..<min(outcome.failures.count, 4), id: \.self) { index in
                let failure = outcome.failures[index]
                Text("“\(failure.node.title)”: \(failure.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var headline: String {
        let verb = outcome.permanentlyDeleted ? "Deleted" : "Moved"
        let target = outcome.permanentlyDeleted ? "" : " to the Trash"
        var text = "\(verb) \(outcome.movedCount) item\(outcome.movedCount == 1 ? "" : "s")\(target) (\(ByteFormat.string(outcome.movedBytes)))."
        if !outcome.permanentlyDeleted && outcome.movedCount > 0 {
            text += " Empty the Trash to free the space."
        }
        if !outcome.failures.isEmpty {
            text += " \(outcome.failures.count) could not be \(outcome.permanentlyDeleted ? "deleted" : "moved")."
        }
        return text
    }
}

/// Explicit confirmation before anything is touched on disk.
struct DeletionReviewSheet: View {
    let review: Collector.Review
    @ObservedObject var collector: Collector
    @StateObject private var acknowledged = ViewState(false)

    private var seconds: Int {
        max(1, min(30, UserDefaults.standard.object(forKey: "undoSeconds") as? Int ?? 5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Move \(review.entries.count) item\(review.entries.count == 1 ? "" : "s") to the Trash?", systemImage: "trash")
                .font(.title2.bold())
            Text("Total on disk: \(ByteFormat.string(review.totalBytes)). After you confirm, DiskWhorl waits \(seconds) seconds before moving anything, and you can undo during that time. Items go to the Trash, not straight to deletion.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !review.blocked.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<review.blocked.count, id: \.self) { index in
                            Text("“\(review.blocked[index].0)”: \(review.blocked[index].1)")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Removed by safety checks", systemImage: "hand.raised.fill").foregroundStyle(.red)
                }
            }

            List(review.entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    ItemIcon(node: entry.node, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.node.title).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(entry.node.physicalSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(entry.node.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if case .caution(let message) = entry.verdict {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180, maxHeight: 320)

            if review.needsAcknowledgement {
                Toggle("I have read the warnings and want to delete these items anyway", isOn: $acknowledged.value)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { collector.cancelReview() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    collector.confirmReview()
                } label: {
                    Text("Move to Trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(review.entries.isEmpty || (review.needsAcknowledgement && !acknowledged.value))
            }
        }
        .padding(22)
        .frame(width: 600)
    }
}
