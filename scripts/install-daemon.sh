#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${WORKLOG_INTERVAL:-90}"
MODEL="${WORKLOG_MODEL:-gemma4:e4b}"
APP_SUPPORT="$HOME/Library/Application Support/WorklogAgent"
BIN="$APP_SUPPORT/bin/WorklogAgent"
PLIST="$HOME/Library/LaunchAgents/dev.labh.worklog-agent.plist"
LOG_DIR="$HOME/Library/Logs"

cd "$ROOT"
swift build -c release --product WorklogAgent
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$(dirname "$BIN")" "$HOME/Library/LaunchAgents" "$LOG_DIR"
cp "$BIN_DIR/WorklogAgent" "$BIN"
chmod +x "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.labh.worklog-agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>daemon</string>
    <string>--interval</string><string>$INTERVAL</string>
    <string>--model</string><string>$MODEL</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG_DIR/WorklogAgent.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/WorklogAgent.error.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/dev.labh.worklog-agent" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/dev.labh.worklog-agent"

echo "Installed WorklogAgent launch daemon."
echo "Interval: $INTERVAL minutes"
echo "Model: $MODEL"
echo "Logs: $LOG_DIR/WorklogAgent.log"
