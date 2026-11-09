import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcon.image(size: 128))
            Text("DiskWhorl")
                .font(.largeTitle.bold())
            Text("Choose a disk in the sidebar to scan it, or scan any folder. The map shows where the space goes; nothing is deleted unless you collect it and confirm.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button {
                    model.scanStartupDisk()
                } label: {
                    Label("Scan Startup Disk", systemImage: "internaldrive")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Scan Folder…", systemImage: "folder")
                }
                .controlSize(.large)
            }
            if !model.hasFullDiskAccess {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Full Disk Access is off", systemImage: "exclamationmark.shield")
                            .font(.headline)
                        Text("macOS keeps Mail, Messages, Safari, Time Machine settings and other app data private unless DiskWhorl has Full Disk Access. Those folders then count as hidden space. Grant access in System Settings › Privacy & Security › Full Disk Access, then relaunch DiskWhorl.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Full Disk Access Settings") { FullDiskAccess.openSystemSettings() }
                    }
                    .padding(6)
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VolumeOverview: View {
    @EnvironmentObject private var model: AppModel
    let volume: VolumeInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: volume.symbolName)
                        .font(.system(size: 54))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name).font(.largeTitle.bold())
                        Text(volume.category.label + " · " + volume.fileSystemLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                CapacityBar(used: volume.usedFraction,
                            purgeable: volume.totalBytes > 0 ? Double(volume.purgeableBytes) / Double(volume.totalBytes) : 0)
                    .frame(height: 12)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Capacity", ByteFormat.string(volume.totalBytes))
                    row("Used", ByteFormat.string(volume.usedBytes) + "  (" + ByteFormat.percent(volume.usedBytes, of: volume.totalBytes) + ")")
                    row("Free", ByteFormat.string(volume.availableBytes))
                    if volume.purgeableBytes > 0 {
                        row("Purgeable", ByteFormat.string(volume.purgeableBytes))
                    }
                    row("File system", volume.formatDescription.isEmpty ? volume.fileSystemLabel : volume.formatDescription + " (\(volume.fsType))")
                    if let proto = volume.deviceProtocol { row("Connection", proto) }
                    if let medium = volume.mediumType { row("Medium", medium) }
                    if let deviceModel = volume.deviceModel, !deviceModel.isEmpty { row("Device", deviceModel) }
                    row("Device node", volume.device)
                    row("Mounted at", volume.mountPoint)
                    row("Access", volume.isReadOnly ? "Read-only" : "Read/write")
                    row("Removable", volume.isRemovable ? "Yes" : "No")
                }
                .font(.callout)

                HStack(spacing: 12) {
                    Button {
                        model.scan(volume: volume, asAdministrator: false)
                    } label: {
                        Label("Scan", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        model.scan(volume: volume, asAdministrator: true)
                    } label: {
                        Label("Scan as Administrator", systemImage: "lock.shield")
                    }
                    .controlSize(.large)
                    .disabled(!volume.isLocal)
                    if let last = model.latestSession(forPath: volume.mountPoint) {
                        Button("Open Last Scan") { model.selection = .session(last.id) }
                            .controlSize(.large)
                    }
                }
                Text("Figures refresh live while the disk is mounted. A scan result is a snapshot: it does not change when files are modified outside DiskWhorl.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).monospacedDigit()
        }
    }
}

struct ScanProgressView: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning \(session.title)")
                .font(.title2.bold())
            if session.adminMode {
                Label("Administrator scan", systemImage: "lock.shield")
                    .foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Files").foregroundStyle(.secondary)
                    Text(session.progressSnapshot.files.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Folders").foregroundStyle(.secondary)
                    Text(session.progressSnapshot.folders.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Measured").foregroundStyle(.secondary)
                    Text(ByteFormat.string(session.progressSnapshot.bytes)).monospacedDigit()
                }
                GridRow {
                    Text("Elapsed").foregroundStyle(.secondary)
                    Text(ByteFormat.duration(session.duration)).monospacedDigit()
                }
                if session.progressSnapshot.unreadable > 0 {
                    GridRow {
                        Text("Unreadable").foregroundStyle(.secondary)
                        Text("\(session.progressSnapshot.unreadable.formatted()) folders").monospacedDigit()
                    }
                }
            }
            Text(session.progressSnapshot.currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Stop") { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
