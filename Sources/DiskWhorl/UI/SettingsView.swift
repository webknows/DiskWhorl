import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("undoSeconds") private var undoSeconds = 5
    @AppStorage("ringCount") private var ringCount = 7
    @AppStorage(DiskMonitor.showSystemVolumesKey) private var showSystemVolumes = false

    var body: some View {
        Form {
            Section("Map") {
                Stepper("Rings shown around the centre: \(ringCount)", value: $ringCount, in: 3...12)
            }
            Section("Deletion") {
                Stepper("Undo countdown: \(undoSeconds) seconds", value: $undoSeconds, in: 2...30)
                Text("Collected items always go to the Trash after the countdown. DiskWhorl never cleans, empties caches or deletes anything on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Disks") {
                Toggle("Show system volumes (Preboot, VM, Update…)", isOn: $showSystemVolumes)
                    .onChange(of: showSystemVolumes) { model.disks.refresh() }
                Toggle("Run new scans as administrator", isOn: $model.adminMode)
            }
            Section("Privacy") {
                LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted" : "Not granted")
                Button("Open Privacy & Security Settings…") { FullDiskAccess.openSystemSettings() }
                Text("DiskWhorl reads file names, sizes and attributes only. It does not open file contents and makes no network connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding(.vertical, 8)
    }
}
