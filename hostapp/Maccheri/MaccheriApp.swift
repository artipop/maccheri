import SwiftUI

@main
struct MaccheriApp: App {
    @State private var host = HostModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(host: host)
        } label: {
            Image(systemName: host.isAccepting ? "shippingbox.fill" : "shippingbox")
        }
        .menuBarExtraStyle(.window)
    }
}
