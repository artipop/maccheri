import AppKit
import SwiftUI

@main
struct MaccheriApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(host: delegate.host)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(host: delegate.host)
        }
    }

    private var menuBarSymbol: String {
        let host = delegate.host
        if !host.isRunning || host.isPaused { return "shippingbox" }
        return host.status.activities.isEmpty ? "shippingbox.fill" : "shippingbox.circle.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = HostModel()

    /// Quitting stops the VMs and deletes their clones first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard host.isRunning else { return .terminateNow }
        Task {
            await host.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
