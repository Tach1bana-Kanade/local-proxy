import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Bool)?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            let restored = await terminationHandler()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
}
