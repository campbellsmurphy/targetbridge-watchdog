#!/bin/zsh
# Install the sender-side TargetBridge auto-reconnect LaunchAgent (run locally on the sender).
set -e
SRC_DIR="${0:a:h}"
LABEL=com.targetbridge.sender-reconnect

mkdir -p "$HOME/bin" "$HOME/Library/Application Support/targetbridge-sender-reconnect" "$HOME/Library/LaunchAgents"
cp "$SRC_DIR/targetbridge-sender-reconnect.sh" "$HOME/bin/"
chmod +x "$HOME/bin/targetbridge-sender-reconnect.sh"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/$LABEL.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$LABEL.plist"
sleep 3
launchctl list | grep sender-reconnect && echo "loaded" || echo "FAILED to load"
