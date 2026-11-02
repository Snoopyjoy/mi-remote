#!/bin/bash
# Install MiRemote.app to ~/Applications and register a LaunchAgent (login start, keep alive).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/MiRemote.app
cp -R dist/MiRemote.app ~/Applications/MiRemote.app
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
launchctl bootout "gui/$(id -u)/com.miremote.daemon" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Now grant: System Settings > Privacy & Security > Accessibility > add ~/Applications/MiRemote.app (and Input Monitoring if asked)."
echo "Log: ~/Library/Logs/mi-remote.log"

# Session-switch combos (live-verified); only written when absent so user edits survive.
mkdir -p ~/.config/mi-remote
if [ ! -f ~/.config/mi-remote/config.json ]; then
  cat > ~/.config/mi-remote/config.json <<'JSON'
{
  "hidMapping": [["0x35","0x6B"],["0x4A","0x6F"],["0x66","0x6C"],["0x80","0x6D"],["0x81","0x6E"],["0x3E","0xE6"]],
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
