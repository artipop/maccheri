# maccheri

Maccheri runs other people's macOS/iOS CI jobs and remote iOS Simulator sessions on idle Macs, each in a
disposable Virtualization.framework VM.

| Directory | What | Build / test |
|---|---|---|
| `protocol/` | Shared contracts: agent ↔ control plane, sessions, signaling, guest hand-off; simulator stream protocol | `swift test --package-path protocol` |
| `agent/` | Host agent: warm VM pool, CI jobs and simulator sessions, user-space guest network, WebRTC host peer; `maccheri-vm` for images | `swift test --package-path agent`, `agent/scripts/build.sh` |
| `hostapp/` | Maccheri.app: menu bar app with the agent inside; JSON `.xcproj` | `xcodebuild -project hostapp/Maccheri.xcodeproj -scheme Maccheri build` |
| `guest/` | `maccheri-guestd` inside the guest, GitHub App registration, CI smoke repo | `swift test --package-path guest` |
| `images/` | One-command base image build | `images/build.sh` |
| `simstream/` | Remote iOS Simulator: guest streamer, private-API bridge, WebRTC host peer (libdatachannel) | `swift test --package-path simstream` |
| `web/` | Browser client for the remote simulator (TypeScript) | `cd web && npm ci && npm test && npm run build` |
| `viewer/` | Mac viewer for measurements; JSON `.xcproj` | `viewer/scripts/package.sh` |
| `controlplane/` | Vapor + SQLite: hosts, work long-poll, sessions, signaling, TURN, GitHub webhooks; see `DESIGN.md` | `swift test --package-path controlplane` |
| `deploy/` | Docker Compose: control plane, Caddy, coturn; server and local variants | see `deploy/README.md` |
| `bench/` | Measurements: MLX, VideoToolbox, simulator latency, guest VM, remote simulator | `RESULTS.md` in each |

## Docs

| | |
|---|---|
| `docs/product.md` | Idea, workloads, segments, Apple licensing, competitors, what the product still needs |
| `docs/threat-model.md` | Owner ↔ renter threats and mitigations |
| `docs/networking.md` | Guest network, owner's IP options, tunnels, WebRTC vs VPN |
| `docs/remote-simulator.md` | Remote simulator landscape, architecture, measurements |
| `docs/decisions.md` | Decision log |
| `docs/roadmap.md` | Plan from prototype to product |
| `docs/contracts.md` | Rules and interfaces between the parallel work streams |
