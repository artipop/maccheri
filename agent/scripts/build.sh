#!/bin/sh
# Virtualization.framework refuses to start VMs from binaries without the entitlement.
set -eu
cd "$(dirname "$0")/.."
swift build -c "${CONFIGURATION:-debug}" --product maccheri-agent
BIN="$(swift build -c "${CONFIGURATION:-debug}" --show-bin-path)/maccheri-agent"
codesign --force --sign - --entitlements scripts/maccheri-agent.entitlements "$BIN"
echo "$BIN"
