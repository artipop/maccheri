#!/bin/sh
# Virtualization.framework refuses to start VMs from binaries without the entitlement.
set -eu
cd "$(dirname "$0")/.."
swift build -c "${CONFIGURATION:-debug}"
BIN_DIR="$(swift build -c "${CONFIGURATION:-debug}" --show-bin-path)"
for product in maccheri-agent maccheri-vm; do
    codesign --force --sign - --entitlements scripts/maccheri-agent.entitlements "$BIN_DIR/$product"
    echo "$BIN_DIR/$product"
done
