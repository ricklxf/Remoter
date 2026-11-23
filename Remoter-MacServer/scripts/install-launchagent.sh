#!/usr/bin/env bash
# Install/update the com.remoter.agent LaunchAgent with KeepAlive=true
# so macOS automatically restarts RemoterAgent within 2s if it ever crashes or exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:-$SCRIPT_DIR/../build/RemoterAgent.app}"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
BIN_PATH="$APP_PATH/Contents/MacOS/RemoterAgent"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: RemoterAgent binary not found at $BIN_PATH" >&2
    exit 1
fi

LABEL="com.remoter.agent"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Remoter"
UID_NUM="$(id -u)"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

# Stop any previously manually-launched instance before launchd takes ownership
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -f "RemoterAgent.app/Contents/MacOS/RemoterAgent" 2>/dev/null || true
sleep 0.5

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd-stderr.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_NUM/$LABEL"
sleep 1

echo "LaunchAgent $LABEL installed and running:"
pgrep -fl "RemoterAgent" || { echo "Error: RemoterAgent failed to start" >&2; exit 1; }
