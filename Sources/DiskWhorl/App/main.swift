import Foundation

// The same executable serves as the privileged scan helper when launched with
// --helper-scan (see HelperMain), and as the icon renderer used by the build script.
if HelperMain.runIfRequested() {
    exit(0)
}
if AppIcon.renderIconSetIfRequested() {
    exit(0)
}
MainActor.assumeIsolated {
    DiskWhorlApp.main()
}
