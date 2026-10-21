# Base images

Base images are macOS VMs in Tart's on-disk layout (`config.json`, `disk.img`, `nvram.bin`),
stored in the directory passed to `maccheri-agent --images`. The agent APFS-clones one per job,
so `--images` and `--work` must be on the same APFS volume. On the dev Mac that is the external SSD:
`/Volumes/Dev/vm/{images,work}`, with `TART_HOME=/Volumes/Dev/vm/tart`.

Next to `config.json` lies `maccheri.json` (`MaccheriProtocol.ImageMetadata`): runner labels, the
simulator devices created in the image and the version of the guest daemon. The agent fills
`HostCapacity` from it.

```json
{"labels": ["maccheri", "macos-27", "xcode-27.2"],
 "devices": [{"deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
              "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-2"}],
 "guestVersion": "20261021-26d28a0"}
```

Tart comes from https://github.com/openai/tart/releases (`~/.local/bin/tart`). The Homebrew tap
`cirruslabs/cli` no longer installs with current Homebrew.

## Building an image

```sh
images/build.sh                       # → /Volumes/Dev/vm/images/macos-27-xcode-27.2-v<N>
images/build.sh --devices "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro,com.apple.CoreSimulator.SimRuntime.iOS-27-2 \
                           com.apple.CoreSimulator.SimDeviceType.iPhone-17,com.apple.CoreSimulator.SimRuntime.iOS-27-2"
```

It takes the dev Mac's VM lock (`docs/contracts.md`) for the whole run and:

1. on the host, prepares `$VM_ROOT/staging` (kept and reused by the next build):
   - the Xcode `xcode-select -p` points to, as a tarball: virtiofs breaks symlinks during `ditto`;
   - the iOS runtime dmg of the first device, from `xcrun simctl runtime list`;
   - the latest GitHub actions runner for osx-arm64, checked against the SHA-256 in its release notes;
   - release builds of `maccheri-guestd` and `simstream`, the LaunchAgent and `maccheri.json`,
     in `staging/<name>/`;
2. clones `--from` (default `macos-27-vanilla`) into `$TART_HOME/vms/maccheri-build-<name>`, sets
   a random MAC and a 90 GB disk;
3. boots the clone with the staging directory shared read-only and runs `images/guest-setup.sh` over
   SSH: grows the APFS container, turns off Spotlight, software updates, sleep, the screen saver and
   screen lock, installs Xcode (license, first launch, developer mode) and the runtime, unpacks the
   runner into `~/actions-runner`, installs the guest daemon (`guest/README.md`) and simstream,
   creates the devices and warms them up: the first boot, then a cold launch of Safari, Maps,
   Calendar, Settings and Photos, which is where the simulator draws its black screen for seconds
   (`simstream/README.md`);
4. shuts the guest down and moves the VM into `<images>/<name>` with `maccheri.json`.

The name is `macos-<os>-xcode-<xcode>-v<N>` with the next free `N`, or `--name`. Existing images
are never touched. A failed build is deleted unless `--keep-failed` is given, in which case the
VM stays in Tart (`tart run maccheri-build-<name>`). Logs: `staging/<name>/guest-setup.log`.

The base, `macos-27-vanilla`, is Cirrus Labs' image (user `admin`/`admin`, SSH, auto-login and
passwordless sudo), about 29 GB compressed. It was pulled once and is not part of the build:

```sh
tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.0 gg-vanilla
cp -c -R $TART_HOME/vms/gg-vanilla /Volumes/Dev/vm/images/macos-27-vanilla
```

## Updating

- **New Xcode or runtime:** install it on the host, `xcode-select -s` it and run `build.sh`.
  The private APIs of simstream are tied to the Xcode version: check
  `simstream/Sources/SimulatorBridge/PrivateAPI.swift`. The old Xcode tarball in staging (about
  10 GB) can then be deleted.
- **New guest daemon or simstream:** run `build.sh` again; `guestVersion` follows the commit.
- **New macOS:** pull a new vanilla image and pass `--from`.

## Checking an image

```sh
agent/scripts/build.sh
maccheri-vm --images /Volumes/Dev/vm/images --work /Volumes/Dev/vm/work --image macos-27-xcode-27.2-v1
```

Then write `session.json` (see `guest/README.md`) into the `shared/` directory of the clone that
`maccheri-vm` prints.

## Older images

`macos-27-vanilla` and `macos-27-xcode-27.2` were built by hand. The latter has Xcode and the runtime
but neither the runner nor the guest daemon.
