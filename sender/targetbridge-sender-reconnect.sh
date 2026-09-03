#!/bin/zsh
# Sender-side TargetBridge auto-reconnect, per-receiver aware.
#
# Each receiver is tracked independently, so a single dropped display recovers on
# its own. Reacting only to the sender's own bridge0 does not work: it stays active
# while any one receiver's link is up, so a lone drop is never noticed.
#
# Reconnects a receiver when:
#   - its Thunderbolt link becomes available (reachability no->yes edge: reseat /
#     replug / link restored), regardless of prior state (a reseat should bring
#     the display back), or
#   - the sender wakes from sleep AND that receiver was connected before sleeping.
#
# Respects a manual disconnect: turning a display off in the sender leaves its link
# reachable, so there is no reachability edge and no reconnect. The wake path is
# gated on "was connected before" for the same reason.
#
# Guarded: only fires connect when the peer is actually reachable (so it can never
# hit nw error 49 / EADDRNOTAVAIL from connecting before the address exists) and
# the stream is down; stops the instant the stream is up. Bounded retries.
#
# Session pairing is fixed to the saved sender config: connect with the wrong
# session index rewrites that session's saved receiver, so keep them paired.

# ---- configure these for your setup ----
typeset -A SESSION
SESSION=( 10.0.0.2 1  10.0.0.3 2 )     # receiver IP -> saved session index (1-indexed)
RECEIVERS=( 10.0.0.2 10.0.0.3 )
LOCAL_IP=10.0.0.1                       # the sender's own bridge address
PRESET=smooth1440p60
WAKE_GAP=90                             # run gap > this (s) ~= woke from sleep
MAX_ATTEMPTS=6                          # give up a reachable-but-unconnectable receiver after this many polls
RETRY_SPACING=15                        # min seconds between connect attempts (each URL opens a sender window)

DIR="$HOME/Library/Application Support/targetbridge-sender-reconnect"
LOG="$DIR/reconnect.log"
mkdir -p "$DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }
rd()  { cat "$DIR/$1" 2>/dev/null; }
wr()  { printf '%s' "$2" > "$DIR/$1"; }

# ---- single-instance guard ----
# Duplicate sender instances each stream their own audio, heard as an echo. A connect URL
# fired while the sender is still registering with LaunchServices can spawn a
# second instance, so reap extras every poll: keep the one that owns the active
# display streams (fallback: oldest), close the rest.
pids=( $(pgrep -x TargetBridge) )
if (( ${#pids} > 1 )); then
  keep=$(lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | awk '$1 ~ /^TargetBri/ && /:54321/ {print $2; exit}')
  [[ -z "$keep" ]] && keep=${pids[1]}
  for p in $pids; do [[ "$p" != "$keep" ]] && kill "$p" 2>/dev/null; done
  log "duplicate sender instances (pids: ${pids}), kept $keep, closed the rest"
fi

# Launch the sender explicitly and wait for it to register before handing over
# any targetbridge:// URL: an open on the URL alone races the app launch and
# is what created the duplicate instances.
ensure_sender_running() {
  pgrep -x TargetBridge >/dev/null && return
  log "sender not running, launching it before connecting"
  open -ga TargetBridge
  for i in {1..20}; do pgrep -x TargetBridge >/dev/null && break; sleep 0.5; done
  sleep 3
  did_restart=1   # fresh sender has no window pile; don't let a sibling receiver quit it mid-connect
}

reachable() { ping -c1 -t1 "$1" >/dev/null 2>&1; }
stream_up() { netstat -an 2>/dev/null | grep -i established | grep -q "${1}\.54321"; }

now=$(date +%s)
last_run=$(rd last-run-epoch); [[ -z "$last_run" ]] && last_run=$now
gap=$(( now - last_run ))
woke=0; [[ $gap -gt $WAKE_GAP ]] && woke=1
[[ $woke -eq 1 ]] && log "long run gap (${gap}s), treating as wake"

did_restart=0
for ip in $RECEIVERS; do
  sess=${SESSION[$ip]}
  fresh=0
  reachable "$ip" && r=yes || r=no
  stream_up "$ip" && s=yes || s=no
  prev_r=$(rd "reach.$ip");   [[ -z "$prev_r" ]]  && prev_r=$r
  desired=$(rd "desired.$ip"); [[ -z "$desired" ]] && desired=no
  pend=$(rd "pending.$ip");    [[ -z "$pend" ]]    && pend=0

  # ---- triggers -> arm a reconnect (pending attempt counter) ----
  if [[ "$s" == no && "$r" == yes && $pend -eq 0 ]]; then
    if [[ "$prev_r" == no ]]; then
      log "$ip: Thunderbolt link available -> reconnecting (session $sess)"
      pend=1
    elif [[ $woke -eq 1 && "$desired" == yes ]]; then
      log "$ip: woke and was connected -> reconnecting (session $sess)"
      pend=1
    fi
    [[ $pend -eq 1 ]] && fresh=1
  fi

  # ---- full outage: restart the sender before reconnecting ----
  # Each targetbridge:// URL delivered to a running sender opens another main
  # window (upstream app behaviour, no suppress option), so when EVERYTHING is
  # down anyway, reset the window pile with a bare relaunch. A lone-drop
  # reconnect still reuses the running sender (can't quit without killing the
  # healthy stream) and adds at most one window until the next full recovery.
  if [[ $fresh -eq 1 && $did_restart -eq 0 ]] && pgrep -x TargetBridge >/dev/null && \
     ! netstat -an 2>/dev/null | grep -i established | grep -q '\.54321'; then
    log "full outage, quitting sender so reconnect windows do not pile up"
    osascript -e 'tell application "TargetBridge" to quit' >/dev/null 2>&1
    for i in {1..10}; do pgrep -x TargetBridge >/dev/null || break; sleep 1; done
    did_restart=1
  fi

  # ---- act on a pending reconnect ----
  if [[ $pend -ge 1 ]]; then
    if [[ "$s" == yes ]]; then
      log "$ip: stream up, connected"
      pend=0
    elif [[ "$r" == yes ]]; then
      if [[ $pend -le $MAX_ATTEMPTS ]]; then
        last_try=$(rd "attempt-epoch.$ip"); [[ -z "$last_try" ]] && last_try=0
        if (( now - last_try >= RETRY_SPACING )); then
          log "$ip: connect attempt $pend"
          ensure_sender_running
          open "targetbridge://connect?receiver=${ip}&session=${sess}&mode=extended&preset=${PRESET}&transport=net&local-ip=${LOCAL_IP}"
          wr "attempt-epoch.$ip" "$now"
          pend=$(( pend + 1 ))
        fi
      else
        log "$ip: gave up after ${MAX_ATTEMPTS} attempts (reachable but not connecting)"
        pend=0
      fi
    else
      pend=1   # link dropped again mid-reconnect; hold, retry when it returns
    fi
  fi

  # ---- remember desired state (for wake gating / respecting manual off) ----
  if [[ "$s" == yes ]]; then
    desired=yes
  elif [[ "$r" == yes && $pend -eq 0 ]]; then
    desired=no          # stream down while link up and not reconnecting = manual off
  fi                    # link down or reconnect pending: leave desired unchanged

  wr "reach.$ip" "$r"
  wr "desired.$ip" "$desired"
  wr "pending.$ip" "$pend"
done

wr last-run-epoch "$now"
