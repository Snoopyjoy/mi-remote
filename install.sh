#!/bin/bash
# Install MiRemote.app to ~/Applications and register a LaunchAgent (login start, keep alive).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/MiRemote.app
cp -R dist/MiRemote.app ~/Applications/MiRemote.app
rm -rf dist/MiRemote.app # keep exactly one MiRemote.app on disk to avoid picking the wrong one in TCC dialogs
PLIST=~/Library/LaunchAgents/com.miremote.daemon.plist
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.miremote.daemon</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/MiRemote.app/Contents/MacOS/MiRemote</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mi-remote.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mi-remote.log</string>
</dict></plist>
PLIST

mkdir -p ~/.config/mi-remote
if [ ! -f ~/.config/mi-remote/config.json ]; then
  cat > ~/.config/mi-remote/config.json <<'JSON'
{
  "doubleClickMs": 260,
  "longPressMs": 360,
  "focusCombos": {
    "com.todesktop.230313mzl4w4u92": {"keycode": 37, "modifiers": ["command"]},
    "com.openai.codex": {"keycode": 41, "modifiers": ["command"]}
  },
  "newChatCombos": {
    "com.todesktop.230313mzl4w4u92": {"keycode": 45, "modifiers": ["command"]},
    "com.openai.codex": {"keycode": 45, "modifiers": ["command"]}
  },
  "sessionCombos": {
    "com.openai.codex": {
      "prev": {"keycode": 124, "modifiers": ["command", "option"]},
      "next": {"keycode": 123, "modifiers": ["command", "option"]}
    }
  }
}
JSON
  echo "Wrote ~/.config/mi-remote/config.json"
fi

launchctl bootout "gui/$(id -u)/com.miremote.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Grant Accessibility + Input Monitoring to ~/Applications/MiRemote.app if needed."
echo "Log: ~/Library/Logs/mi-remote.log"
