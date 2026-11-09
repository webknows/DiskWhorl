import SwiftUI
import AppKit

struct DiskWhorlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DiskWhorl", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1380, height: 880)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = AppIcon.image(size: 512)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Scan Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Button("Scan Startup Disk") { model.scanStartupDisk() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Scan All Local Disks") { model.scanAllLocalVolumes() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Rescan") {
                if let session = model.selectedSession { model.rescan(session) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)
        }
        CommandMenu("Navigate") {
            Button("Up One Level") { model.selectedSession?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Back to Top Level") { model.selectedSession?.goToRoot() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Divider()
            Button("Quick Look (Space)") { model.toggleQuickLook() }
                .keyboardShortcut("y")
            Button("Reveal in Finder") { model.reveal(model.currentItem) }
                .keyboardShortcut("r")
            Button("Copy Path") { model.copyPath(model.currentItem) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Add to Collector") { model.collect(model.currentItem) }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Hidden Space…") { model.selectedSession?.showHiddenSpaceTools = true }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!(model.selectedSession?.isVolumeScan ?? false))
        }
    }
}
