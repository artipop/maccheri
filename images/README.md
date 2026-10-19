# Base images

Base images are macOS VMs in Tart's on-disk layout (`config.json`, `disk.img`, `nvram.bin`),
stored in the directory passed to `maccheri-agent --images`. The agent APFS-clones one per job,
so `--images` and `--work` must be on the same APFS volume. On the dev Mac that is the external SSD:
`/Volumes/Dev/vm/{images,work}`, with `TART_HOME=/Volumes/Dev/vm/tart`.

Tart comes from https://github.com/openai/tart/releases (`~/.local/bin/tart`). The Homebrew tap
`cirruslabs/cli` no longer installs with current Homebrew.

## `macos-27-xcode-27.2`

1. `tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.0 gg-vanilla`. It is about 29 GB compressed.
   The image comes with user `admin`/`admin`, SSH, auto-login and passwordless sudo.
2. `tart clone gg-vanilla macos-27-sim && tart set macos-27-sim --disk-size 90`.
   The guest grows its APFS container by itself on the next boot.
3. Stage the host's Xcode and simulator runtime:
   - pack Xcode as a tarball, because virtiofs breaks symlinks during `ditto`:
     `tar -cf staging/Xcode-beta.tar -C /Applications Xcode-beta.app`;
   - copy the runtime dmg from
     `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/*/AssetData/Restore/*.dmg`.
4. `tart run macos-27-sim --no-graphics --dir=staging:<staging>:ro`, then in the guest:
   ```
   sudo tar -xf "/Volumes/My Shared Files/staging/Xcode-beta.tar" -C /Applications
   sudo xcode-select -s /Applications/Xcode-beta.app
   sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
   xcrun simctl runtime add "/Volumes/My Shared Files/staging/iOS_27.2_24B5089g.dmg"
   ```
5. Shut the guest down, then `cp -c -R $TART_HOME/vms/macos-27-sim <images>/macos-27-xcode-27.2`.
6. Check it: `maccheri-vm --images <images> --work <work> --image macos-27-xcode-27.2`.

Still to do for CI jobs:
- install the GitHub Actions runner into `/Users/admin/actions-runner`;
- install `guest/runner/maccheri-runner.sh` and `dev.maccheri.runner.plist`;
- allow `admin` to run `shutdown` without a password. The vanilla image already has passwordless sudo.
