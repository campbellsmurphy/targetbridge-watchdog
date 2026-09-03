#!/bin/zsh
# Deploy the TargetBridge receiver watchdog to one or more receiver Macs over SSH.
# Usage: ./deploy.sh <host> [host...]     (SSH hosts or ~/.ssh/config aliases)
set -e

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then
  echo "usage: $0 <host> [host...]   (e.g. $0 receiver-a receiver-b)" >&2
  exit 1
fi

SRC_DIR="${0:a:h}"

for h in "${HOSTS[@]}"; do
  echo "=== deploying to $h ==="
  ssh "$h" 'mkdir -p "$HOME/bin" "$HOME/Library/Application Support/targetbridge-watchdog" "$HOME/Library/LaunchAgents"'
  ssh "$h" 'cat > "$HOME/bin/targetbridge-watchdog.sh"' < "$SRC_DIR/targetbridge-watchdog.sh"
  # The plist needs absolute paths, so the remote home directory is filled in there.
  ssh "$h" 'sed "s|__HOME__|$HOME|g" > "$HOME/Library/LaunchAgents/com.targetbridge.watchdog.plist"' < "$SRC_DIR/com.targetbridge.watchdog.plist"
  ssh "$h" '
    chmod +x "$HOME/bin/targetbridge-watchdog.sh"
    launchctl bootout gui/$(id -u)/com.targetbridge.watchdog 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.targetbridge.watchdog.plist"
    sleep 3
    launchctl list | grep targetbridge.watchdog && echo "loaded on '"$h"'" || echo "FAILED to load on '"$h"'"
  '
done
