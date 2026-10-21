// simstream-peer: runs HostPeer without the agent, for testing the web client and the transport.
//
//   simstream-peer --guest 127.0.0.1:7300 --control-plane http://localhost:5173 --agent-token dev
//       Stands in for the agent: long-polls POST /agent/v1/work, serves every simulator lease with
//       HostPeer against one simstream (`--guest`), reports `ready` and `ended`. Works against the
//       web client's dev mock (`npm run dev` in web/) and against the real control plane.
//   simstream-peer --guest 127.0.0.1:7300 --signal 'wss://…/signal?role=host&token=…' [--ice stun:…]
//       One session from a signaling URL.
//
// Options: --relay-only (force TURN).

import Foundation
import MaccheriProtocol
import Network
import SimStreamPeer

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

func args(_ name: String) -> [String] {
    let a = CommandLine.arguments
    return a.indices.filter { a[$0] == name && $0 + 1 < a.count }.map { a[$0 + 1] }
}

let usage = """
usage: simstream-peer --guest host:port (--control-plane URL --agent-token TOKEN | --signal URL [--ice URL]...) [--relay-only]
"""

func guestEndpoint() -> (host: String, port: UInt16)? {
    guard let guest = arg("--guest"), let colon = guest.lastIndex(of: ":"), let port = UInt16(guest[guest.index(after: colon)...]) else { return nil }
    return (String(guest[..<colon]), port)
}

guard guestEndpoint() != nil else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

@Sendable func connectToGuest() async throws -> NWConnection {
    let (host, port) = guestEndpoint()!
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
}

func serve(sessionID: UUID, signaling: SignalingInfo) async {
    var options = HostPeer.Options()
    options.relayOnly = CommandLine.arguments.contains("--relay-only")
    let peer = HostPeer(transport: WebSocketSignaling(url: signaling.url), iceServers: signaling.iceServers, sessionID: sessionID,
                        options: options, connectToGuest: connectToGuest)
    do {
        let reason = try await peer.run()
        print("session \(sessionID): \(reason)")
    } catch {
        print("session \(sessionID) failed: \(error)")
    }
}

/// The agent's side of /agent/v1, just enough to take simulator sessions.
struct Agent {
    let base: URL
    let token: String
    let encoder = JSONEncoder()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func request(_ path: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = TimeInterval(WorkAPI.longPollSeconds + 10)
        return request
    }

    func report(_ sessionID: UUID, _ state: HostSessionState, _ message: String? = nil) async {
        do {
            let (_, response) = try await URLSession.shared.data(for: request(WorkAPI.sessionStatePath(sessionID: sessionID), body: SessionStateReport(state: state, message: message)))
            print("session \(sessionID): reported \(state) → \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            print("session \(sessionID): report \(state): \(error)")
        }
    }

    func run() async {
        print("polling \(base.appending(path: WorkAPI.workPath))")
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request(WorkAPI.workPath, body: LeaseRequest(labels: ["maccheri"], freeSlots: 1)))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if status != 204 {
                        print("work: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
                        try await Task.sleep(for: .seconds(3))
                    }
                    continue
                }
                switch try decoder.decode(WorkLease.self, from: data) {
                case .simulator(let lease):
                    print("session \(lease.sessionID): \(lease.device.deviceType)")
                    Task {
                        await report(lease.sessionID, .ready)
                        await serve(sessionID: lease.sessionID, signaling: lease.signaling)
                        await report(lease.sessionID, .ended)
                    }
                case .ci(let job):
                    print("ignoring CI job \(job.jobID)")
                }
            } catch {
                print("work: \(error)")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

if let base = arg("--control-plane").flatMap(URL.init(string:)) {
    await Agent(base: base, token: arg("--agent-token") ?? "dev").run()
} else if let signal = arg("--signal").flatMap(URL.init(string:)) {
    let ice = args("--ice").map { url -> ICEServer in
        // turn:user:pass@host:port → ICEServer with credentials.
        guard let at = url.lastIndex(of: "@"), let scheme = url.firstIndex(of: ":") else { return ICEServer(urls: [url]) }
        let credentials = url[url.index(after: scheme)..<at].split(separator: ":", maxSplits: 1).map(String.init)
        return ICEServer(urls: ["\(url[..<scheme]):\(url[url.index(after: at)...])"], username: credentials.first, credential: credentials.last)
    }
    let token = URLComponents(url: signal, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value ?? ""
    await serve(sessionID: UUID(), signaling: SignalingInfo(url: signal, token: token, iceServers: ice))
} else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}
