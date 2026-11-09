import SwiftUI
import QuickLook

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(disks: model.disks)
                .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 380)
        } detail: {
            DetailView(disks: model.disks)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.adminMode) {
                    Label("Administrator Scan", systemImage: model.adminMode ? "lock.open.fill" : "lock.fill")
                }
                .toggleStyle(.button)
                .help("When on, new scans run with administrator privileges and include folders your account cannot read. macOS asks for your password when a scan starts.")

                Button {
                    model.scanAllLocalVolumes()
                } label: {
                    Label("Scan All Local Disks", systemImage: "square.stack.3d.down.right")
                }
                .help("Scan every local disk in parallel")

                Button {
                    model.chooseFolder()
                } label: {
                    Label("Scan Folder…", systemImage: "folder.badge.questionmark")
                }
                .help("Scan a folder of your choice (⌘O)")
            }
        }
        .quickLookPreview($model.previewURL)
    }
}

private struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    /// Observed so the volume overview shows live free-space figures.
    @ObservedObject var disks: DiskMonitor

    var body: some View {
        if let session = model.selectedSession {
            SessionContainer(session: session)
                .id(session.id)
        } else if let volume = model.selectedVolume {
            VolumeOverview(volume: volume)
        } else {
            WelcomeView()
        }
    }
}

private struct SessionContainer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession

    var body: some View {
        switch session.state {
        case .scanning:
            ScanProgressView(session: session)
        case .finished:
            ResultView(session: session)
        case .failed(let message):
            ContentUnavailableView {
                Label("The scan could not finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.rescan(session) }
            }
        case .cancelled:
            ContentUnavailableView {
                Label("Scan cancelled", systemImage: "stop.circle")
            } description: {
                Text(session.title)
            } actions: {
                Button("Scan Again") { model.rescan(session) }
            }
        }
    }
}
