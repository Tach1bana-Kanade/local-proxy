import SwiftUI
import ProxyAppsCore
import Darwin

@main
struct LocalProxyDesktopApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var controller = ProxyAppsController()

    init() {
        if CommandLine.arguments.contains("--verify-bundled-rules") {
            do {
                let snapshot = try RuleSetStore(directory: FileManager.default.temporaryDirectory).bundled()
                let parsed = try snapshot.parse()
                let pac = try PACValidation.compile(mode: .smart, manual: [], automatic: parsed.rules)
                print("PAC validation OK: \(pac.utf8.count) bytes, revision=\(PACGenerator.revision(pac))")
                print("Bundled rules OK: \(snapshot.version), direct=\(parsed.directCount), proxy=\(parsed.proxyCount), unsupported=\(parsed.unsupported), conflicts=\(parsed.conflicts)")
                exit(0)
            } catch { fputs("Bundled rules failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ProxyAppsContentView()
                .environmentObject(controller)
                .frame(minWidth: 760, minHeight: 720)
                .onAppear {
                    applicationDelegate.terminationHandler = { await controller.shutdownForTermination() }
                }
                .task { await controller.monitorStatus() }
        }
    }
}
