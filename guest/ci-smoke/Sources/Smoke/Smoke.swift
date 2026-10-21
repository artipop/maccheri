import UIKit

/// Something that needs the iOS SDK, so the job proves the simulator toolchain is there.
@MainActor public func deviceSummary() -> String {
    "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
}
