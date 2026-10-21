#!/bin/sh
# Builds simstream, copies it into a running guest, boots the simulator whose UDID is in the
# guest's ~/udid (or $UDID), optionally launches an app, and starts simstream there.
#
#   scripts/run-in-guest.sh GUEST_IP [bundle-id] [-- simstream options]
#
# Guest login comes from GUEST_USER / GUEST_PASSWORD (base images: admin / admin).
set -eu
cd "$(dirname "$0")/.."
GUEST="$1"; shift
APP=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then APP="$1"; shift; fi
[ "${1:-}" = "--" ] && shift

ASKPASS="$(mktemp -t askpass)"
trap 'rm -f "$ASKPASS"' EXIT
printf '#!/bin/sh\necho "%s"\n' "${GUEST_PASSWORD:-admin}" > "$ASKPASS"
chmod +x "$ASKPASS"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TARGET="${GUEST_USER:-admin}@$GUEST"

swift build -c release --product simstream
BIN="$(swift build -c release --show-bin-path)/simstream"
ssh $SSH_OPTS "$TARGET" 'mkdir -p ~/simstream'
# New file + mv: overwriting a running binary in place gets it killed for an invalid signature.
scp $SSH_OPTS "$BIN" "$TARGET:simstream/simstream.new"
ssh $SSH_OPTS "$TARGET" "
    set -e
    U='${UDID:-}'
    [ -n \"\$U\" ] || U=\$(cat ~/udid)
    xcrun simctl boot \$U 2>/dev/null || true
    xcrun simctl bootstatus \$U -b > /dev/null
    [ -z '$APP' ] || xcrun simctl launch \$U '$APP' > /dev/null
    cd ~/simstream
    pkill -x simstream || true
    mv -f simstream.new simstream
    nohup sh -c \"./simstream --udid \$U $*; echo exit=\\\$?\" > log.txt 2>&1 < /dev/null &
    sleep 3
    cat log.txt
"
