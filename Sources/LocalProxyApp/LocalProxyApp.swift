import SwiftUI

@main
struct LocalProxyDesktopApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var controller = ProxyAppsController()

    var body: some Scene {
        WindowGroup {
            ProxyAppsContentView()
                .environmentObject(controller)
                .frame(minWidth: 720, minHeight: 620)
                .task { await controller.monitorStatus() }
        }
    }
}
