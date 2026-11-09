import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var disks: DiskMonitor
    @AppStorage(DiskMonitor.showSystemVolumesKey) private var showSystemVolumes = false

    var body: some View {
        List(selection: $model.selection) {
            Section("Disks") {
                ForEach(disks.volumes) { volume in
                    DiskRow(volume: volume)
                        .tag(AppModel.SidebarItem.volume(volume.id))
                        .contextMenu {
                            Button("Scan") { model.scan(volume: volume, asAdministrator: false) }
                            Button("Scan as Administrator") { model.scan(volume: volume, asAdministrator: true) }
                                .disabled(!volume.isLocal)
                            Divider()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: volume.mountPoint)])
                            }
                        }
                }
            }
            if !model.sessions.isEmpty {
                Section("Scans") {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                            .tag(AppModel.SidebarItem.session(session.id))
                            .contextMenu {
                                Button("Rescan") { model.rescan(session) }
                                Button("Rescan as Administrator") { model.rescan(session, asAdministrator: true) }
                                Divider()
                                if session.isScanning {
                                    Button("Stop Scan") { session.cancel() }
                                }
                                Button("Close") { model.close(session) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.hasFullDiskAccess {
                    Button {
                        FullDiskAccess.openSystemSettings()
                    } label: {
                        Label("Grant Full Disk Access", systemImage: "exclamationmark.shield")
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                    .help("Without Full Disk Access, macOS hides Mail, Messages, Safari and other protected folders from any scan.")
                }
                Toggle("Show system volumes", isOn: $showSystemVolumes)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .onChange(of: showSystemVolumes) { disks.refresh() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

struct DiskRow: View {
    @EnvironmentObject private var model: AppModel
    let volume: VolumeInfo

    private var activeSession: ScanSession? {
        model.latestSession(forPath: volume.mountPoint)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: volume.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(volume.isStartup ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ScanButton(volume: volume, session: activeSession)
                }
                CapacityBar(used: volume.usedFraction,
                            purgeable: volume.totalBytes > 0 ? Double(volume.purgeableBytes) / Double(volume.totalBytes) : 0)
                    .frame(height: 6)
                Text("\(ByteFormat.string(volume.availableBytes)) free of \(ByteFormat.string(volume.totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text([volume.fileSystemLabel, volume.mediaLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ScanButton: View {
    let volume: VolumeInfo
    let session: ScanSession?

    var body: some View {
        if let session {
            ObservedScanButton(volume: volume, session: session)
        } else {
            StartScanButton(volume: volume)
        }
    }
}

/// Watches the volume's latest session so the row switches back from the spinner when it ends.
private struct ObservedScanButton: View {
    let volume: VolumeInfo
    @ObservedObject var session: ScanSession

    var body: some View {
        if session.isScanning {
            ProgressView()
                .controlSize(.small)
                .help("Scanning…")
        } else {
            StartScanButton(volume: volume)
        }
    }
}

private struct StartScanButton: View {
    @EnvironmentObject private var model: AppModel
    let volume: VolumeInfo

    var body: some View {
        Button {
            model.scan(volume: volume)
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 16))
        }
        .buttonStyle(.borderless)
        .help(model.adminMode && volume.isLocal ? "Scan as administrator" : "Scan this disk")
    }
}

struct SessionRow: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.adminMode ? "lock.shield" : (session.isVolumeScan ? "chart.pie" : "folder"))
                .foregroundStyle(session.adminMode ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Group {
                    switch session.state {
                    case .scanning:
                        Text("\(session.progressSnapshot.files.formatted()) files · \(ByteFormat.string(session.progressSnapshot.bytes))")
                    case .finished:
                        Text("\(ByteFormat.string(session.root?.physicalSize ?? 0)) · \(ByteFormat.duration(session.duration))")
                    case .failed:
                        Text("Failed")
                    case .cancelled:
                        Text("Cancelled")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if session.isScanning {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Used / purgeable / free bar.
struct CapacityBar: View {
    let used: Double
    let purgeable: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usedWidth = width * CGFloat(min(1, max(0, used)))
            let purgeableWidth = min(usedWidth, width * CGFloat(min(1, max(0, purgeable))))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(used > 0.9 ? Color.red.opacity(0.8) : Color.accentColor.opacity(0.85))
                    .frame(width: usedWidth)
                Rectangle()
                    .fill(Color(nsColor: Palette.purgeable))
                    .frame(width: purgeableWidth)
                    .offset(x: usedWidth - purgeableWidth)
            }
        }
    }
}
