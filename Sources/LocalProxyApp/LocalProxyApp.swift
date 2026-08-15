import SwiftUI

@main
struct LocalProxyDesktopApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var controller = ProxyAppsController()

    var body: some Scene {
        WindowGroup {
            ProxyAppsContentView()
                .environmentObject(controller)
                .frame(minWidth: 760, minHeight: 720)
                .onAppear {
                    applicationDelegate.terminationHandler = { controller.shutdownForTermination() }
                }
                .task { await controller.monitorStatus() }
        }
    }
}
