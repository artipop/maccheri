#!/bin/bash
# Builds a base image from the vanilla one in one go, without manual steps:
#
#   vanilla → clone → 90 GB disk → Xcode and the iOS runtime from this Mac → GitHub actions runner
#   → maccheri-guestd and simstream → devices, booted once to warm up → guest settings → shutdown
#   → <images>/macos-<os>-xcode-<xcode>-v<N> with maccheri.json next to config.json
#
#   images/build.sh [--from NAME] [--name NAME] [--devices "type,runtime ..."] [--keep-failed]
#
# Xcode is the one `xcode-select -p` points to, the runtime the matching one from `simctl runtime`.
# Large inputs are cached in $VM_ROOT/staging and reused by the next build. Old images are never
# touched; the name gets the next free -vN unless --name is given. Holds the dev Mac's VM lock
# (docs/contracts.md) for the whole build.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

VM_ROOT="${VM_ROOT:-/Volumes/Dev/vm}"
IMAGES="${IMAGES:-$VM_ROOT/images}"
STAGING="${STAGING:-$VM_ROOT/staging}"
export TART_HOME="${TART_HOME:-$VM_ROOT/tart}"
TART="${TART:-$HOME/.local/bin/tart}"
FROM="macos-27-vanilla"
NAME=""
DEVICES="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro,com.apple.CoreSimulator.SimRuntime.iOS-27-2"
DISK_GB=90
KEEP_FAILED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --devices) DEVICES="$2"; shift 2 ;;
        --keep-failed) KEEP_FAILED=1; shift ;;
        *) sed -n '2,13p' "$0" >&2; exit 64 ;;
    esac
done

step() { echo "==> $(date +%H:%M:%S) $*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -d "$IMAGES/$FROM" ] || die "no base image $IMAGES/$FROM"
[ -x "$TART" ] || die "no tart at $TART"

# MARK: - Versions and name

XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 { print $2 }')"
OS_MAJOR="$(echo "$FROM" | sed -nE 's/^macos-([0-9]+).*/\1/p')"
[ -n "$OS_MAJOR" ] || die "can't tell the macOS version from $FROM"
if [ -z "$NAME" ]; then
    N=1
    while [ -e "$IMAGES/macos-$OS_MAJOR-xcode-$XCODE_VERSION-v$N" ]; do N=$((N + 1)); done
    NAME="macos-$OS_MAJOR-xcode-$XCODE_VERSION-v$N"
fi
[ ! -e "$IMAGES/$NAME" ] || die "$IMAGES/$NAME exists; old images are not overwritten"
VM="maccheri-build-$NAME"
GUEST_VERSION="$(date +%Y%m%d)-$(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet HEAD -- guest simstream protocol || echo -dirty)"
step "building $NAME from $FROM: $XCODE_APP ($XCODE_VERSION), guest $GUEST_VERSION"

# MARK: - VM lock

LOCK="$VM_ROOT/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    die "the VM is taken: $(cat "$LOCK/owner" 2>/dev/null || echo '?') (docs/contracts.md)"
fi
echo "C: images/build.sh $NAME (pid $$)" > "$LOCK/owner"

TART_PID=""
ASKPASS="$(mktemp -t askpass)"
cleanup() {
    status=$?
    if [ -n "$TART_PID" ] && kill -0 "$TART_PID" 2>/dev/null; then
        "$TART" stop "$VM" --timeout 30 >/dev/null 2>&1 || kill "$TART_PID" 2>/dev/null || true
        wait "$TART_PID" 2>/dev/null || true
    fi
    if [ $status -ne 0 ] && [ -d "$TART_HOME/vms/$VM" ]; then
        if [ $KEEP_FAILED = 1 ]; then
            echo "kept the failed build: $TART_HOME/vms/$VM (tart run $VM)"
        else
            "$TART" delete "$VM" >/dev/null 2>&1 || rm -rf "$TART_HOME/vms/$VM"
        fi
    fi
    rm -f "$ASKPASS"
    rm -rf "$LOCK"
    exit $status
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: - Inputs on the host

mkdir -p "$STAGING/$NAME"
FILES="$STAGING/$NAME"

XCODE_TAR="$(basename "$XCODE_APP" .app)-$XCODE_VERSION.tar"
# The tar the manual recipe made is reused if it is the same Xcode.
if [ ! -f "$STAGING/$XCODE_TAR" ] && [ -f "$STAGING/$(basename "$XCODE_APP" .app).tar" ] &&
    [ "$(tar -xOf "$STAGING/$(basename "$XCODE_APP" .app).tar" "$(basename "$XCODE_APP")/Contents/version.plist" 2>/dev/null | plutil -extract CFBundleShortVersionString raw - 2>/dev/null)" = "$XCODE_VERSION" ]; then
    mv "$STAGING/$(basename "$XCODE_APP" .app).tar" "$STAGING/$XCODE_TAR"
fi
if [ ! -f "$STAGING/$XCODE_TAR" ]; then
    step "packing $XCODE_APP (a tarball: virtiofs breaks symlinks during ditto)"
    tar -cf "$STAGING/$XCODE_TAR.partial" -C "$(dirname "$XCODE_APP")" "$(basename "$XCODE_APP")"
    mv "$STAGING/$XCODE_TAR.partial" "$STAGING/$XCODE_TAR"
fi

for spec in $DEVICES; do
    RUNTIME_ID="${spec##*,}"
    INFO="$(xcrun simctl runtime list -j | jq -r --arg r "$RUNTIME_ID" \
        'map(select(.runtimeIdentifier == $r and .state == "Ready")) | first | select(.) | "\(.version) \(.build) \(.path)"')"
    [ -n "$INFO" ] || die "runtime $RUNTIME_ID is not installed on this Mac"
    read -r RT_VERSION RT_BUILD RT_PATH <<< "$INFO"
    break  # one runtime per image for now: the first device's
done
RUNTIME_DMG="iOS_${RT_VERSION}_${RT_BUILD}.dmg"
if [ ! -f "$STAGING/$RUNTIME_DMG" ]; then
    step "copying the iOS $RT_VERSION runtime"
    cp "$(ls "$RT_PATH"/Restore/*.dmg | head -1)" "$STAGING/$RUNTIME_DMG.partial"
    mv "$STAGING/$RUNTIME_DMG.partial" "$STAGING/$RUNTIME_DMG"
fi

RELEASE="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
RUNNER_VERSION="$(echo "$RELEASE" | jq -r .tag_name | sed 's/^v//')"
RUNNER_TAR="actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"
if [ ! -f "$STAGING/$RUNNER_TAR" ]; then
    step "downloading actions runner $RUNNER_VERSION"
    curl -fsSL -o "$STAGING/$RUNNER_TAR.partial" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$RUNNER_TAR"
    WANT="$(echo "$RELEASE" | jq -r .body | sed -nE 's/.*<!-- BEGIN SHA osx-arm64 -->([0-9a-f]{64})<!-- END SHA osx-arm64 -->.*/\1/p')"
    GOT="$(shasum -a 256 "$STAGING/$RUNNER_TAR.partial" | cut -d' ' -f1)"
    [ -z "$WANT" ] || [ "$WANT" = "$GOT" ] || die "actions runner checksum mismatch: $GOT, release says $WANT"
    mv "$STAGING/$RUNNER_TAR.partial" "$STAGING/$RUNNER_TAR"
fi

step "building maccheri-guestd and simstream"
swift build -c release --package-path guest --product maccheri-guestd
swift build -c release --package-path simstream --product simstream
cp "$(swift build -c release --package-path guest --show-bin-path)/maccheri-guestd" "$FILES/"
cp "$(swift build -c release --package-path simstream --show-bin-path)/simstream" "$FILES/"
cp guest/launchd/dev.maccheri.guestd.plist images/guest-setup.sh "$FILES/"

DEVICES_JSON="$(for spec in $DEVICES; do
    jq -n --arg t "${spec%%,*}" --arg r "${spec##*,}" '{deviceType: $t, runtime: $r}'
done | jq -s .)"
jq -n --argjson devices "$DEVICES_JSON" --arg v "$GUEST_VERSION" \
    --arg os "macos-$OS_MAJOR" --arg xcode "xcode-$XCODE_VERSION" \
    '{labels: ["maccheri", $os, $xcode], devices: $devices, guestVersion: $v}' > "$FILES/maccheri.json"

# MARK: - Guest

step "cloning $FROM into $VM"
mkdir -p "$TART_HOME/vms"
"$TART" delete "$VM" >/dev/null 2>&1 || true
cp -c -R "$IMAGES/$FROM" "$TART_HOME/vms/$VM"
"$TART" set "$VM" --random-mac --disk-size "$DISK_GB"

step "booting"
"$TART" run "$VM" --no-graphics --no-audio --dir="staging:$STAGING:ro" > "$FILES/tart-run.log" 2>&1 &
TART_PID=$!
IP="$("$TART" ip "$VM" --wait 180)" || die "no IP for $VM"

printf '#!/bin/sh\necho admin\n' > "$ASKPASS"
chmod +x "$ASKPASS"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 "admin@$IP")
for _ in $(seq 1 60); do
    "${SSH[@]}" -o ConnectTimeout=5 true 2>/dev/null && break
    sleep 2
done
# The virtiofs share appears after login.
"${SSH[@]}" 'for i in $(seq 1 60); do [ -d "/Volumes/My Shared Files/staging" ] && exit 0; sleep 1; done; exit 1' ||
    die "the staging share did not appear in the guest"

step "setting up the guest at $IP"
STAGE="/Volumes/My Shared Files/staging"
"${SSH[@]}" "STAGE='$STAGE' FILES='$STAGE/$NAME' XCODE_TAR='$XCODE_TAR' RUNTIME_DMG='$RUNTIME_DMG' \
    RUNNER_TAR='$RUNNER_TAR' DEVICES='$DEVICES' /bin/bash '$STAGE/$NAME/guest-setup.sh'" 2>&1 | tee "$FILES/guest-setup.log"
[ "${PIPESTATUS[0]}" = 0 ] || die "guest setup failed, see $FILES/guest-setup.log"

step "shutting down"
"${SSH[@]}" 'sudo shutdown -h now' >/dev/null 2>&1 || true
wait "$TART_PID" || true
TART_PID=""

# MARK: - Image

step "publishing $IMAGES/$NAME"
mkdir -p "$IMAGES/$NAME.partial"
for file in config.json disk.img nvram.bin; do
    mv "$TART_HOME/vms/$VM/$file" "$IMAGES/$NAME.partial/"
done
cp "$FILES/maccheri.json" "$IMAGES/$NAME.partial/"
mv "$IMAGES/$NAME.partial" "$IMAGES/$NAME"
rm -rf "$TART_HOME/vms/$VM"
rm -f "$FILES/maccheri-guestd" "$FILES/simstream"
step "done: $IMAGES/$NAME"
cat "$IMAGES/$NAME/maccheri.json"
