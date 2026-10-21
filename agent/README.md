# Agent

The part of Maccheri that runs on an owner's Mac: it enrolls the Mac with the control plane, reports
what the Mac can take on, long-polls for work and runs every CI job and simulator session in a
single-use macOS VM.

- `AgentCore`: the library. Maccheri.app (`hostapp/`) links it and runs the agent in-process.
- `maccheri-agent`: the same agent without a UI.
- `maccheri-vm`: boots one throwaway VM by hand, for checking images.

```sh
scripts/build.sh                       # builds and signs with the virtualization entitlement
B=.build/out/Products/Debug            # or: swift build --show-bin-path
$B/maccheri-agent enroll --control-plane https://maccheri.example.com --user-token TOKEN
$B/maccheri-agent run --images /Volumes/Dev/vm/images --work /Volumes/Dev/vm/work
$B/maccheri-vm --images /Volumes/Dev/vm/images --work /Volumes/Dev/vm/work --image NAME --forward 2222:22
```

`enroll` stores the agent token in the login keychain (service `dev.maccheri.agent`), `run` reads it
from there. `--control-plane URL --token TOKEN` skips the keychain.

## How it works

```
Agent ── heartbeat every 15 s (HostCapacity) ──────────────▶ control plane
      ◀─ endedSessions ───────────────────────────────────
      ── POST /agent/v1/work (freeSlots = free + warm) ────▶
      ◀─ WorkLease.ci / .simulator ────────────────────────
VMPool: warm guest of the right image, or a free slot, or evict a warm guest of another image
        clone (clonefile) → boot → write session.json → … → stop → delete the clone
```

- **Pool.** Slots = min(owner's cap, 2 for Apple's license, memory budget / VM memory). By default
  the budget is all RAM but 4 GB, so a 16 GB Mac runs one 8 GB guest. A warm guest is booted from
  a fresh clone with an empty share and counts against the slots; it is handed to the next lease of
  the same image and replaced once the slot is free again. Nothing is ever reused.
- **CI.** `session.json` = `GuestSession.ci`; the guest runs the job and powers off; the agent reports
  `finished`, or kills the VM at `timeoutSeconds` and reports `timedOut`.
- **Simulator.** Report `starting` → VM → `GuestSession.simulator` → poll the guest's `:7300` every
  0.5 s → `ready` → `SimulatorPeer.run` with a loopback port that leads to the guest's `:7300` →
  when the viewer leaves, the session times out, the control plane lists it in `endedSessions` or
  answers `410 Gone`, the VM is destroyed and the agent reports `ended` (or `failed`).
  The peer is `SignalingStubPeer` (joins signaling as the host, waits for `bye`, no media) until D's
  `HostPeer` lands.
- **Cleanup.** Clones live in `<work>/<lease id>`. The agent holds an exclusive `flock` on
  `<work>/.lock` and, on start, deletes every UUID-named directory there: whatever a crashed agent
  left behind. Quitting the app or Ctrl-C on the CLI stops the VMs and deletes their clones.

## Guest network: user-space NAT

The guest must reach the internet but not the owner's LAN (RFC 1918, link-local), nor the Mac itself.

**Choice:** the VM's NIC is a `VZFileHandleNetworkDeviceAttachment` (one end of a datagram
socketpair) and `GuestNetwork` is everything on the other end, in the agent's process:

- an Ethernet segment `10.233.0.0/24` with the gateway `10.233.0.1` (ARP, DHCP, DNS) and the guest at
  `10.233.0.2`. The subnet exists only inside the agent: no host interface has it, so nothing on the
  Mac or the LAN can route to the guest;
- NAT: the guest's TCP, UDP and ICMP echo become ordinary sockets of the agent process, but only to
  destinations `EgressPolicy` permits. It refuses every non-public range (RFC 6890: `10/8`,
  `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10` (CGNAT, Tailscale), `127/8`, multicast, …) and
  the Mac's own interface addresses. A refused TCP connection gets an RST, so tools fail fast;
- DNS: the guest asks the gateway; the agent forwards to the host's resolvers from `/etc/resolv.conf`.
  The guest never talks to the owner's router itself. Private addresses in answers are useless to
  it, connections to them are refused;
- IPv4 only: IPv6 frames are dropped.
- The agent reaches the guest through `probe(port:)` (readiness of `:7300`) and
  `forward(guestPort:)`: a listener on `127.0.0.1:<random>` relayed to the guest. That is what the
  host peer's `connectToGuest` opens.

Why not the alternatives:

- **pf rules through a privileged helper (SMAppService).** Kernel-speed, but needs root and a signed
  helper the owner must approve, and changes system-wide pf state that VPN clients, Docker and
  Internet Sharing also touch. vmnet's NAT subnet (`192.168.64/24`) can also collide with the owner's
  LAN. With the user-space stack each VM's policy lives and dies with its VM.
- **vsock + a proxy in the guest.** Needs a tun device or proxy settings in the guest, and not every
  CI tool honours `https_proxy`.

Costs: our TCP is minimal (in-order receive, go-back-N, window scaling, no SACK/timestamps). The
link between guest and agent is local, so that is enough; throughput is bounded by the agent's
CPU rather than the kernel's. No IP fragments (the guest sends with DF at MTU 1500), no DNS over TCP.

The tests (`GuestNetworkTests`) play the guest with hand-made frames: DHCP, ARP, refusals, TCP both
ways with windowing, forwarding, probes, UDP.

### Checking from a guest

```sh
maccheri-vm --images … --work … --image NAME --forward 2222:22
ssh -p 2222 admin@127.0.0.1
curl -sI https://github.com                 # works
ping -c 2 1.1.1.1                           # works
ping -c 2 192.168.1.1                       # the owner's router: no reply
curl -m 5 http://192.168.1.1                # refused
nc -z -G 3 <host's LAN IP> 22               # refused
```

Results on the dev Mac (M4, 2026-10-21, image `macos-27-xcode-27.2-v1`, host on Wi-Fi `10.10.20.0/24`
plus a VPN on `utun4`):

| From the guest | Result |
|---|---|
| DHCP lease | 19–22 s after start (the guest's boot, not the server) |
| `curl https://github.com` | 200 |
| download 10 MB | 2.0 MB/s (the host itself: 1.4–2 MB/s) |
| upload 5 MB | 142 KB/s (the host itself: 108 KB/s, the uplink is the limit) |
| `ping 1.1.1.1` | replies |
| router `10.10.20.1`: ping, `:80` | no reply, refused |
| host's LAN `10.10.20.86:22`, VPN `172.16.9.1:22` | refused |
| gateway `10.233.0.1:22`, `100.100.100.100:53`, `169.254.1.1` | refused / no reply |

`MACCHERI_NET_DEBUG=1` logs frame counters every 5 s and per-connection TCP counters on close.

Two things the first real runs taught, both covered by tests now: replies larger than the MTU (DNS
with EDNS, QUIC) must be IP-fragmented, a frame over the MTU breaks the NIC; and the stack needs a
congestion window, because the virtual NIC drops silently when the guest's receive ring is full,
and resending a multi-megabyte guest window after every loss drowned all of the guest's traffic.
