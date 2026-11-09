import SwiftUI

/// Tools for the part of the disk that file scanning cannot see: APFS snapshots,
/// purgeable space and folders the scan was not allowed to read.
struct HiddenSpaceView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var state = HiddenSpaceState()

    private var isAPFS: Bool {
        let type = session.volume?.fsType ?? MountTable.entry(forPath: session.rootPath)?.fsType ?? ""
        return type.lowercased() == "apfs"
    }

    private var snapshotVolumes: [String] {
        guard isAPFS else { return [] }
        if session.mode == .startupGroup { return [ScanEngine.dataVolumePath, "/"] }
        return [session.rootPath]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Hidden and system space on \(session.title)", systemImage: "eye.slash")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let accounting = session.accounting {
                summary(accounting)
            }

            if let message = state.message {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if state.changedDisk {
                        Button("Rescan Now") {
                            dismiss()
                            model.rescan(session)
                        }
                        .controlSize(.small)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    snapshotSection
                    purgeableSection
                    accessSection
                }
            }
        }
        .padding(22)
        .frame(width: 700, height: 660)
        .task { await loadSnapshots() }
        .confirmationDialog("Delete this snapshot?",
                            isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } }),
                            presenting: state.pendingDelete) { snapshot in
            Button("Delete Snapshot", role: .destructive) { delete(snapshot) }
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
        } message: { snapshot in
            Text("“\(snapshot.name)” will be removed permanently. Restore points it provides (for example a Time Machine local backup) will no longer be available. macOS asks for an administrator password.")
        }
        .confirmationDialog("Reclaim purgeable space?", isPresented: $state.confirmReclaim) {
            Button("Reclaim") { startReclaim() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DiskWhorl temporarily reserves free space in a file inside your Caches folder. When free space runs low, macOS deletes purgeable data on its own: local snapshots, downloaded copies of iCloud files and system caches. The reservation never goes below \(ByteFormat.string(PurgeableReclaimer.safetyFloor)) free, no data is written to the reservation, and the file is removed as soon as the process ends.")
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summary(_ accounting: SpaceAccounting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SpaceBreakdownBar(accounting: accounting).frame(height: 12)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow { Text("Used (as the volume reports it)").foregroundStyle(.secondary); Text(ByteFormat.string(accounting.used)).monospacedDigit() }
                GridRow { Text("Found in files by the scan").foregroundStyle(.secondary); Text(ByteFormat.string(accounting.scanned)).monospacedDigit() }
                GridRow { Text("Purgeable").foregroundStyle(.secondary); Text(ByteFormat.string(accounting.purgeable)).monospacedDigit() }
                GridRow { Text("Hidden").fontWeight(.semibold); Text(ByteFormat.string(accounting.hidden)).fontWeight(.semibold).monospacedDigit() }
                GridRow { Text("Free").foregroundStyle(.secondary); Text(ByteFormat.string(accounting.free)).monospacedDigit() }
            }
            .font(.callout)
            Text("Hidden space = used − files found − purgeable. Typical contributors: APFS snapshots, the Recovery and other system volumes that are not mounted, swap and sleep images, folders the scan could not read, and file-system metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Snapshots

    private var snapshotSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !isAPFS {
                    Text("Snapshots are an APFS feature; this volume uses \(session.volume?.fileSystemLabel ?? "another file system").")
                        .foregroundStyle(.secondary)
                } else if state.loadingSnapshots {
                    HStack { ProgressView().controlSize(.small); Text("Reading snapshots…") }
                } else if state.snapshots.isEmpty {
                    Text("No snapshots were found on this volume.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.snapshots) { snapshot in
                        snapshotRow(snapshot)
                        Divider()
                    }
                }
                HStack {
                    Button {
                        Task { await loadSnapshots() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.busy || !isAPFS)
                    Spacer()
                    Text("Snapshot sizes are not reported by macOS; deleting one frees only the blocks no other snapshot or file still uses.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("APFS snapshots", systemImage: "camera.on.rectangle").font(.headline)
        }
    }

    private func snapshotRow(_ snapshot: APFSSnapshot) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(details(of: snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = snapshot.protectionReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if snapshot.limitsContainerShrink == true {
                    Text("This snapshot limits how far the container can shrink.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Delete…") { state.pendingDelete = snapshot }
                .controlSize(.small)
                .disabled(snapshot.protectionReason != nil || state.busy)
        }
    }

    private func details(of snapshot: APFSSnapshot) -> String {
        var parts = [snapshot.kind.rawValue, "created by " + snapshot.creator]
        parts.append(snapshot.volumeMountPoint == "/" ? "System volume" : snapshot.volumeMountPoint)
        if let xid = snapshot.xid { parts.append("XID \(xid)") }
        if let purgeable = snapshot.purgeable { parts.append(purgeable ? "purgeable" : "not purgeable") }
        return parts.joined(separator: " · ")
    }

    private func loadSnapshots() async {
        state.loadingSnapshots = true
        let volumes = snapshotVolumes
        let list = await Task.detached(priority: .userInitiated) { () -> [APFSSnapshot] in
            SnapshotManager.list(volumeMountPoints: volumes)
        }.value
        state.snapshots = list
        state.loadingSnapshots = false
    }

    private func delete(_ snapshot: APFSSnapshot) {
        state.pendingDelete = nil
        state.busy = true
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try SnapshotManager.delete(snapshot)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            state.busy = false
            if let failure {
                state.message = failure
            } else {
                state.message = "Deleted “\(snapshot.name)”. Rescan to see the effect on hidden space."
                state.changedDisk = true
            }
            await loadSnapshots()
        }
    }

    // MARK: Purgeable

    private var purgeableSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                let purgeable = state.reclaimStatus?.purgeableBytes ?? session.accounting?.purgeable ?? 0
                Text("macOS currently reports \(ByteFormat.string(purgeable)) as purgeable. It frees this space automatically when an app needs it, so it is safe to leave alone; reclaim it only when you need the free space now (for example, before a macOS update).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = state.reclaimStatus, state.reclaimer != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("\(status.message) Reserved \(ByteFormat.string(status.reservedBytes)) · free \(ByteFormat.string(status.freeBytes)) · purgeable \(ByteFormat.string(status.purgeableBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        thinSnapshots()
                    } label: {
                        Label("Thin Time Machine Snapshots", systemImage: "scissors")
                    }
                    .disabled(state.busy || !isAPFS)
                    .help("Asks Time Machine to remove as many local snapshots as it can (tmutil thinlocalsnapshots)")

                    if state.reclaimer != nil {
                        Button("Stop") { state.reclaimer?.cancel() }
                    } else {
                        Button {
                            state.confirmReclaim = true
                        } label: {
                            Label("Reclaim Purgeable Space…", systemImage: "arrow.3.trianglepath")
                        }
                        .disabled(state.busy || purgeable <= 0 || !(session.volume?.isLocal ?? true))
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Purgeable space", systemImage: "arrow.3.trianglepath").font(.headline)
        }
    }

    private func thinSnapshots() {
        state.busy = true
        let path = session.rootPath
        Task {
            let output: String = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let text = try SnapshotManager.thinTimeMachineSnapshots(mountPoint: path)
                    return text.isEmpty ? "Time Machine finished thinning local snapshots." : text
                } catch {
                    return error.localizedDescription
                }
            }.value
            state.busy = false
            state.message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            state.changedDisk = true
            await loadSnapshots()
        }
    }

    private func startReclaim() {
        let worker = PurgeableReclaimer()
        let state = self.state
        state.reclaimer = worker
        state.busy = true
        let volume = session.rootPath
        DispatchQueue.global(qos: .userInitiated).async {
            let report = worker.run(volume: volume) { status in
                Task { @MainActor in state.reclaimStatus = status }
            }
            Task { @MainActor in
                state.busy = false
                state.reclaimer = nil
                state.changedDisk = true
                state.message = "\(report.outcome) Purgeable: \(ByteFormat.string(report.purgeableBefore)) → \(ByteFormat.string(report.purgeableAfter)). Free: \(ByteFormat.string(report.freeBefore)) → \(ByteFormat.string(report.freeAfter))."
            }
        }
    }

    // MARK: Access

    private var accessSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if session.unreadableFolders > 0 {
                    Text("\(session.unreadableFolders.formatted()) folders could not be read in this scan. Their contents count as hidden space.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Every folder the scan reached could be read.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label(model.hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access not granted",
                          systemImage: model.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                        .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.orange)
                    Spacer()
                    if !model.hasFullDiskAccess {
                        Button("Open Privacy Settings…") { FullDiskAccess.openSystemSettings() }
                    }
                    if !session.adminMode && session.volume?.isLocal ?? true {
                        Button("Rescan as Administrator") {
                            dismiss()
                            model.rescan(session, asAdministrator: true)
                        }
                    }
                }
                .controlSize(.small)
                Text("Full Disk Access lifts the privacy protection on app data such as Mail and Messages. An administrator scan additionally reads root-only system folders, for example in /private/var and on the Preboot volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Access", systemImage: "lock.shield").font(.headline)
        }
    }
}

/// State of the Hidden Space window (see ViewState for why this is not @State).
@MainActor
final class HiddenSpaceState: ObservableObject {
    @Published var snapshots: [APFSSnapshot] = []
    @Published var loadingSnapshots = true
    @Published var pendingDelete: APFSSnapshot?
    @Published var busy = false
    @Published var message: String?
    @Published var reclaimer: PurgeableReclaimer?
    @Published var reclaimStatus: PurgeableReclaimer.Status?
    @Published var confirmReclaim = false
    @Published var changedDisk = false
}
