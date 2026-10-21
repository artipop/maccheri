import SimStreamClient
import SwiftUI

struct ContentView: View {
    @Bindable var model: ViewerModel

    var body: some View {
        if model.phase == .idle {
            ConnectForm(model: model)
        } else {
            VideoRepresentable(view: model.video)
                .overlay(alignment: .topLeading) {
                    StatsOverlay(model: model)
                }
        }
    }
}

private struct ConnectForm: View {
    @Bindable var model: ViewerModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Remote iOS Simulator")
                .font(.headline)
            HStack {
                TextField("host:port", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { model.connect() }
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
            }
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatsOverlay: View {
    let model: ViewerModel

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: model.hello.map { "\($0.deviceName) · \($0.videoWidth)×\($0.videoHeight)" } ?? "connecting…")
                Spacer()
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(verbatim: String(format: "%.0f fps · %.2f Mbit/s · RTT %@ ms", s.fps, s.mbps, ms(s.rttMs)))
            Text(verbatim: "click → frame \(ms(s.lastLatencyMs)) ms (n \(s.samples))")
            Text(verbatim: "  p50 \(ms(s.p50Ms)) · p95 \(ms(s.p95Ms)) ms")
            Text(verbatim: "  server \(ms(s.serverP50Ms)) · decode \(ms(s.decodeP50Ms)) ms (p50)")
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 6))
        .padding(6)
        .allowsHitTesting(true)
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "–"
    }
}

private struct VideoRepresentable: NSViewRepresentable {
    let view: VideoView
    func makeNSView(context: Context) -> VideoView { view }
    func updateNSView(_ nsView: VideoView, context: Context) {}
}
