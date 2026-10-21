import Foundation
import Observation
import SimStreamClient

@Observable
final class ViewerModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming
    }

    var address = UserDefaults.standard.string(forKey: "address") ?? "Mac-mini-Artem.local:\(SimStream.defaultPort)"
    private(set) var phase = Phase.idle
    private(set) var hello: Hello?
    private(set) var stats = SimStreamClient.Stats()
    private(set) var error: String?
    /// Owned here so frames go straight from the client queue to the layer, not through SwiftUI.
    let video = VideoView()

    private var client: SimStreamClient?

    func connect() {
        disconnect()
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? SimStream.defaultPort : SimStream.defaultPort
        UserDefaults.standard.set(address, forKey: "address")

        let client = SimStreamClient(host: host, port: port)
        error = nil
        phase = .connecting
        let video = self.video
        client.onState = { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(state) } }
        }
        client.onHello = { [weak self] hello in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hello = hello } }
        }
        client.onStats = { [weak self] stats in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stats = stats } }
        }
        client.onFrame = { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { video.show(frame) } }
        }
        video.onTouch = { [weak client] phase, x, y in client?.touch(phase, x: x, y: y) }
        self.client = client
        client.connect()
    }

    func disconnect() {
        client?.onState = nil
        client?.disconnect()
        client = nil
        video.clear()
        hello = nil
        stats = SimStreamClient.Stats()
        phase = .idle
    }

    /// Taps the screen centre `count` times through the same path as the mouse, so the overlay
    /// numbers can be checked without a hand on the mouse (TapProbe flips on every tap).
    private func benchTaps(_ count: Int) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<count where phase == .streaming {
                video.onTouch?(.began, 0.5, 0.5)
                try? await Task.sleep(for: .milliseconds(60))
                video.onTouch?(.ended, 0.5, 0.5)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 250...400)))
            }
        }
    }

    private func update(_ state: SimStreamClient.State) {
        switch state {
        case .connecting:
            phase = .connecting
        case .connected:
            phase = .streaming
            let taps = UserDefaults.standard.integer(forKey: "benchTaps")
            if taps > 0 { benchTaps(taps) }
        case .disconnected(let reason):
            disconnect()
            error = reason ?? "disconnected"
        }
    }
}
