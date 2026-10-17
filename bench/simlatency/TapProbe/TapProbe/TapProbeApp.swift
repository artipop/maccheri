import UIKit

// Measures input-to-display latency from outside: every touch-down flips the whole screen
// between black and white in the same run-loop turn, so the first changed frame marks the
// moment the app reacted. A touch-up does nothing.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ProbeViewController: UIViewController {
    private var isWhite = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isWhite.toggle()
        // No animation: the change must land in the very next frame.
        UIView.performWithoutAnimation {
            view.backgroundColor = isWhite ? .white : .black
        }
    }
}
