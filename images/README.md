# Base images

Base images are macOS VMs in Tart's on-disk layout (`config.json`, `disk.img`, `nvram.bin`),
stored in the directory passed to `maccheri-agent --images`. The agent APFS-clones one per job,
so `--images` and `--work` must be on the same APFS volume.

A CI image with Xcode takes 60–80 GB. Building one is blocked until the host has that much free space.

Planned steps for `macos-27-xcode-27.2`:

1. `tart create --from-ipsw latest macos-27-xcode-27.2`, then `tart run` and finish Setup Assistant
   (user `admin`, auto-login, SSH on, sleep off).
2. Install Xcode 27.2 and the GitHub Actions runner into `/Users/admin/actions-runner`.
3. Install `guest/runner/maccheri-runner.sh` to `/usr/local/bin/` and
   `guest/runner/dev.maccheri.runner.plist` to `/Library/LaunchDaemons/`.
4. Allow `admin` to run `shutdown` without a password.
5. Shut down and copy `~/.tart/vms/macos-27-xcode-27.2` to the images directory.
