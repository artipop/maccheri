#!/bin/bash
# Runs inside the guest during images/build.sh, as admin over SSH, with the build's staging
# directory shared read-only at $STAGE. Everything here must be safe to re-run.
#
#   STAGE=... XCODE_TAR=... RUNTIME_DMG=... RUNNER_TAR=... DEVICES="type,runtime ..." guest-setup.sh
set -euo pipefail
: "${STAGE:?}" "${XCODE_TAR:?}" "${RUNTIME_DMG:?}" "${RUNNER_TAR:?}" "${DEVICES:?}"
step() { echo "==> $*"; }

step "disk: grow the APFS container to the resized disk"
# Tart's images usually grow it on boot; do it explicitly in case this one doesn't.
CONTAINER="$(diskutil info -plist / | plutil -extract ParentWholeDisk raw -)"
yes | sudo diskutil repairDisk disk0 >/dev/null 2>&1 || true
sudo diskutil apfs resizeContainer "$CONTAINER" 0 >/dev/null 2>&1 || true
df -h /

step "settings: no Spotlight, updates, sleep, screen saver or screen lock"
sudo mdutil -a -i off >/dev/null || true
sudo softwareupdate --schedule off >/dev/null 2>&1 || true
for key in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate "$key" -bool false
done
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
sudo pmset -a powernap 0 standby 0 autorestart 0 >/dev/null 2>&1 || true
defaults -currentHost write com.apple.screensaver idleTime -int 0
sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0
sysadminctl -screenLock off -password admin >/dev/null 2>&1 || true

step "xcode: $XCODE_TAR"
APP="$(tar -tf "$STAGE/$XCODE_TAR" | head -1 | cut -d/ -f1)"
if [ ! -d "/Applications/$APP" ]; then
    # A tarball, because virtiofs breaks symlinks during ditto.
    sudo tar -xf "$STAGE/$XCODE_TAR" -C /Applications
fi
sudo xcode-select -s "/Applications/$APP"
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
sudo DevToolsSecurity -enable >/dev/null
sudo dseditgroup -o edit -a admin -t user _developer
xcodebuild -version

step "runtime: $RUNTIME_DMG"
BUILD="$(echo "$RUNTIME_DMG" | sed -E 's/.*_([0-9A-Za-z]+)\.dmg$/\1/')"
if ! xcrun simctl runtime list | grep -q "($BUILD)"; then
    xcrun simctl runtime add "$STAGE/$RUNTIME_DMG"
fi
xcrun simctl runtime list

step "actions runner: $RUNNER_TAR"
rm -rf ~/actions-runner
mkdir -p ~/actions-runner
tar -xzf "$STAGE/$RUNNER_TAR" -C ~/actions-runner
~/actions-runner/bin/Runner.Listener --version

step "maccheri-guestd and simstream"
sudo mkdir -p /usr/local/bin "/Library/Application Support/Maccheri"
for bin in maccheri-guestd simstream; do
    # New file + mv: a running binary overwritten in place is killed for an invalid signature.
    sudo cp "$STAGE/$bin" "/usr/local/bin/$bin.new"
    sudo mv -f "/usr/local/bin/$bin.new" "/usr/local/bin/$bin"
done
sudo cp "$STAGE/maccheri.json" "/Library/Application Support/Maccheri/maccheri.json"
sudo cp "$STAGE/dev.maccheri.guestd.plist" /Library/LaunchAgents/dev.maccheri.guestd.plist
sudo chown root:wheel /Library/LaunchAgents/dev.maccheri.guestd.plist /usr/local/bin/maccheri-guestd /usr/local/bin/simstream
sudo chmod 644 /Library/LaunchAgents/dev.maccheri.guestd.plist

step "devices and warm-up"
# The first boot of a device migrates its data and the first launch of an app builds caches;
# both are slow, and the cold launch is also where the simulator draws a black screen for seconds
# (simstream/README.md). Do them now, so a session starts from a warm device.
WARM_APPS="com.apple.mobilesafari com.apple.Maps com.apple.mobilecal com.apple.Preferences com.apple.mobileslideshow"
FIRST=""
for spec in $DEVICES; do
    TYPE="${spec%%,*}"; RUNTIME="${spec##*,}"
    UDID="$(xcrun simctl list -j devices | /usr/bin/jq -r --arg r "$RUNTIME" --arg t "$TYPE" \
        '.devices[$r] // [] | map(select(.deviceTypeIdentifier == $t and .isAvailable != false)) | .[0].udid // empty')"
    if [ -z "$UDID" ]; then
        NAME="$(echo "${TYPE##*.}" | tr '-' ' ')"
        UDID="$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME")"
    fi
    [ -n "$FIRST" ] || FIRST="$UDID"
    echo "$TYPE $RUNTIME: $UDID"
    START=$(date +%s)
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    echo "  booted in $(( $(date +%s) - START ))s"
    for app in $WARM_APPS; do
        xcrun simctl launch "$UDID" "$app" >/dev/null 2>&1 || { echo "  no $app"; continue; }
        sleep 6
        xcrun simctl terminate "$UDID" "$app" >/dev/null 2>&1 || true
    done
    xcrun simctl io "$UDID" screenshot /tmp/warm.png >/dev/null 2>&1 || true
    xcrun simctl shutdown "$UDID"
done
# simstream/scripts/run-in-guest.sh boots the device named here.
echo "$FIRST" > ~/udid

step "clean up"
rm -rf ~/Library/Logs/Maccheri /tmp/warm.png ~/.bash_history ~/.zsh_history ~/.zsh_sessions
df -h /
