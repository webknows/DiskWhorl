import AppKit
import Combine

/// Keeps the list of mounted volumes current: mount, unmount and rename events arrive
/// immediately from NSWorkspace, and free-space figures are refreshed every few seconds.
@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "DiskWhorl.disk-monitor", qos: .utility)
    private var refreshInFlight = false
    private var refreshPending = false

    static let showSystemVolumesKey = "showSystemVolumes"

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            observers.append(token)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func volume(forMountPoint path: String) -> VolumeInfo? {
        volumes.first { $0.mountPoint == path }
    }

    func refresh() {
        if refreshInFlight { refreshPending = true; return }
        refreshInFlight = true
        let includeSystem = UserDefaults.standard.bool(forKey: Self.showSystemVolumesKey)
        queue.async { [weak self] in
            let list = VolumeInfo.currentVolumes(includeSystem: includeSystem)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.volumes != list { self.volumes = list }
                self.refreshInFlight = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }
}
