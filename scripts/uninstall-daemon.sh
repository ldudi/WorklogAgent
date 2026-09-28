#!/bin/bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/dev.labh.worklog-agent.plist"
launchctl bootout "gui/$(id -u)/dev.labh.worklog-agent" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed WorklogAgent launch daemon."
