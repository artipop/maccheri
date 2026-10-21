// simstream --udid <UDID> [--port 7300] [--scale 0.5] [--fps-cap 60] [--bitrate 4000] [--refine 3]
//
// Streams a booted iOS Simulator over TCP (SimStreamProtocol) and turns the client's touches into
// simulator HID events. Runs next to the simulator, e.g. inside the macOS guest. One client at a
// time, no auth: LAN prototype.

import Foundation
import SimStreamProtocol
import SimulatorBridge

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

guard let udid = arg("--udid") else {
    FileHandle.standardError.write(Data("usage: simstream --udid <UDID> [--port 7300] [--scale 0.5] [--fps-cap 60] [--bitrate 4000 (kbit/s)] [--refine 3 (idle passes)]\n".utf8))
    exit(64)
}
let options = StreamServer.Options(
    port: arg("--port").flatMap(UInt16.init) ?? SimStream.defaultPort,
    scale: arg("--scale").flatMap(Double.init) ?? 0.5,
    fpsCap: arg("--fps-cap").flatMap(Int.init) ?? 60,
    bitrate: (arg("--bitrate").flatMap(Int.init) ?? 4000) * 1000,
    refinePasses: arg("--refine").flatMap(Int.init) ?? 3
)

do {
    let device = try SimDevice(udid: udid)
    print("device \(device.name) \(device.udid)")
    let screen = SimScreen(device: device)
    try screen.start()
    let deadline = Date().addingTimeInterval(15)
    while screen.currentSurface == nil, Date() < deadline { usleep(20_000) }
    let touch = try SimTouchInjector(device: device)
    let server = try StreamServer(device: device, screen: screen, touch: touch, options: options)
    server.start()
    withExtendedLifetime(server) { dispatchMain() }
} catch {
    print("error: \(error)")
    exit(1)
}
