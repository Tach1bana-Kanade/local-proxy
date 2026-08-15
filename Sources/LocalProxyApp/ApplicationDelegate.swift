import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }
}
