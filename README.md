# maccheri

Maccheri runs other people's macOS/iOS CI jobs on idle Macs, each job in a disposable
Virtualization.framework VM.

| Directory | What | Build / test |
|---|---|---|
| `protocol/` | Agent ↔ control plane types, remote simulator stream protocol (SwiftPM) | `swift test --package-path protocol` |
| `agent/` | Host agent: APFS clone → VM → JIT runner → destroy | `swift test --package-path agent`, `agent/scripts/build.sh` |
| `guest/` | What runs inside the macOS guest | — |
| `hostapp/` | Menu bar app; project in the JSON `.xcproj` format (Xcode 27.2+) | `xcodebuild -project hostapp/Maccheri.xcodeproj -scheme Maccheri build` |
| `simstream/` | Remote iOS Simulator: guest-side streamer, private-API bridge, client library; see `simstream/README.md` | `swift test --package-path simstream` |
| `viewer/` | Mac app that shows and drives a remote simulator; JSON `.xcproj` | `viewer/scripts/package.sh` |
| `controlplane/` | Vapor server: GitHub App webhooks, job queue, JIT runner configs | `swift test --package-path controlplane` |
| `images/` | How base VM images are built | — |
| `bench/simstream/` | Remote simulator click → frame latency | `RESULTS.md` |
| `bench/mlx/` | MLX benchmark, host vs. VM | `uv run bench/mlx/bench.py --label host --out …` |

## Control plane

Environment: `GITHUB_WEBHOOK_SECRET`, `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` (PEM),
`AGENT_TOKENS` (comma-separated), optional `RUNNER_LABEL` (`maccheri`), `DEFAULT_IMAGE`,
`JOB_TIMEOUT_SECONDS`. The GitHub App needs *Administration: write* on repositories (to create
JIT runners) and the `workflow_job` webhook event.

## Agent

    maccheri-agent --control-plane https://… --token … --images ~/maccheri/images --work ~/maccheri/work

Networking is `VZNATNetworkDeviceAttachment` for now; the isolated socketpair + WireGuard path
comes next.
