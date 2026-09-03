#!/bin/zsh
# TargetBridge Receiver watchdog.
# Edge-triggered on the Thunderbolt-bridge link state so an accidental cable
# unplug (without disconnecting in the sender first) can't leave the receiver
# frozen on a stale "connected" screen.
#   unplug (link active->inactive): kill+relaunch the receiver -> clears the
#     stale session and leaves a fresh receiver ready.
#   replug (link inactive->active): ensure the receiver is running so a
#     reconnect from the sender cannot fail.
# Only acts on transitions, so it never loops and does not fight a manual close
# during normal connected use. Managed by com.targetbridge.watchdog LaunchAgent.

APP="TargetBridge Receiver"
STATE_DIR="$HOME/Library/Application Support/targetbridge-watchdog"
STATE_FILE="$STATE_DIR/last-link-status"
LOG="$STATE_DIR/watchdog.log"
mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

link_active() { ifconfig bridge0 2>/dev/null | grep -q 'status: active'; }
receiver_running() { pgrep -i targetbridge >/dev/null 2>&1; }

# Current link state, with a short re-confirm to debounce transient flaps.
if link_active; then cur=active; else cur=inactive; fi
if [ "$cur" = inactive ]; then
  sleep 2
  link_active && cur=active
fi

prev=$(cat "$STATE_FILE" 2>/dev/null)
[ -z "$prev" ] && prev="$cur"   # first run: seed, no transition

restart_receiver() {
  osascript -e 'quit app "TargetBridge Receiver"' >/dev/null 2>&1
  for i in 1 2 3 4 5; do receiver_running || break; sleep 1; done
  receiver_running && { pkill -9 -i targetbridge; sleep 1; }
  open -a "$APP"
}

if [ "$cur" != "$prev" ]; then
  if [ "$cur" = inactive ]; then
    log "link active->inactive (cable unplugged): clearing stale session, relaunching receiver"
    restart_receiver
  else
    log "link inactive->active (cable replugged): ensuring receiver is running"
    receiver_running || open -a "$APP"
  fi
fi

printf '%s' "$cur" > "$STATE_FILE"
