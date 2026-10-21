# Guest

`maccheri-guestd` is the only Maccheri code inside the VM. Every boot of a clone does exactly one
thing: one CI job or one simulator session. Then the guest shuts down and the host deletes the clone.

| What | Where |
|---|---|
| The hand-off: `session.json`, share path, simstream port | `protocol/Sources/MaccheriProtocol/Guest.swift` |
| The daemon | `Sources/GuestCore`, `Sources/maccheri-guestd` |
| LaunchAgent | `launchd/dev.maccheri.guestd.plist` → `/Library/LaunchAgents/` |
| Smoke-test repository for CI | `ci-smoke/` |

## What it does

1. Starts as a LaunchAgent in `admin`'s auto-login GUI session (`LimitLoadToSessionType Aqua`): the
   simulator does not boot without one.
2. If `session.json` is not there yet (a VM waiting in the warm pool), pre-boots the image's default
   device (`devices.first` of `/Library/Application Support/Maccheri/maccheri.json`), so that
   a simulator session starts from a booted device. A cold VM finds its session at once and skips this.
3. Polls `/Volumes/My Shared Files/maccheri/session.json` every 0.5 s. The file may appear long after
   boot (warm pool). A half-written file fails to decode and is read again on the next poll.
   Until the agent moves to `session.json`, a bare `jitconfig` file (the current `JobRunner`) also
   counts as a CI job.
4. `ci`: shuts the pre-booted device down, runs `~/actions-runner/run.sh --jitconfig …` and waits
   for it to exit.
5. `simulator`: finds an available device of the requested type and runtime (a booted one wins,
   a missing one is created), boots it and starts `/usr/local/bin/simstream --udid … --port …`.
   The session is over when simstream exits or `session.json` disappears from the share.
6. Shuts the guest down with `sudo -n shutdown -h now`.

launchd restarts the daemon if it crashes; a clean exit means the guest is going down.

## Logs

- unified log: `log show --last 1h --predicate 'subsystem == "dev.maccheri.guestd"'`;
- files in `~/Library/Logs/Maccheri/`: `guestd.log`, `actions-runner.log`, `simstream.log`.

## Testing without a VM or control plane

The daemon runs on any Mac with Xcode:

```sh
swift test --package-path guest
swift build -c release --package-path guest --product maccheri-guestd
mkdir -p /tmp/share
.build/release/maccheri-guestd --share /tmp/share --metadata /path/to/maccheri.json \
    --simstream <simstream> --logs /tmp/logs --no-shutdown
# in another terminal
echo '{"simulator":{"_0":{"sessionID":"'$(uuidgen)'","device":{"deviceType":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-27-2"},"simstreamPort":7399}}}' > /tmp/share/session.json
nc -z 127.0.0.1 7399 && rm /tmp/share/session.json
```

In a VM: boot a clone of the image with `maccheri-vm` and write `session.json` into the clone's
`shared/` directory on the host (the path is in `maccheri-vm`'s `clone:` line). The guest sees it at
`/Volumes/My Shared Files/maccheri/`.

Options: `--share`, `--metadata`, `--runner`, `--simstream`, `--logs`, `--no-shutdown`, `--no-preboot`.
