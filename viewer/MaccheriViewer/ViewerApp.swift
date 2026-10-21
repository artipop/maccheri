import SwiftUI

@main
struct ViewerApp: App {
    @State private var model = ViewerModel()

    var body: some Scene {
        WindowGroup("Maccheri Viewer") {
            ContentView(model: model)
                .task {
                    // `open MaccheriViewer.app --args -address host:port -autoconnect YES [-benchTaps 60]`
                    if UserDefaults.standard.bool(forKey: "autoconnect") { model.connect() }
                }
        }
        .defaultSize(width: 420, height: 880)
    }
}
