#!/bin/sh
# Runs inside the macOS guest at boot: takes the JIT config the host shared,
# runs exactly one GitHub Actions job and powers the VM off. The host then deletes the clone.
set -u
SHARE="/Volumes/My Shared Files/maccheri"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"

# virtiofs automount appears a few seconds after login window.
for _ in $(seq 1 60); do
    [ -f "$SHARE/jitconfig" ] && break
    sleep 1
done

if [ -f "$SHARE/jitconfig" ]; then
    "$RUNNER_DIR/run.sh" --jitconfig "$(cat "$SHARE/jitconfig")"
    echo "runner exited with $?"
else
    echo "no jitconfig in $SHARE" >&2
fi

sudo /sbin/shutdown -h now
