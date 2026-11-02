#!/bin/bash
# Stop daemon, remove LaunchAgent/App, and clear the per-device hidutil mapping.
set -euo pipefail
launchctl bootout "gui/$(id -u)/com.miremote.daemon" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.miremote.daemon.plist
rm -rf ~/Applications/MiRemote.app
hidutil property --matching '{"VendorID":10007,"ProductID":12984}' --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 || true
echo "Uninstalled; remote is back to stock behaviour."
