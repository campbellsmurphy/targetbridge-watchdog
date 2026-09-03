# targetbridge-watchdog

A small hack that makes [TargetBridge](https://github.com/swellweb/targetBridge) reconnect on its own.

TargetBridge streams a Mac's display to another Mac acting as an external monitor. It works well until a cable is pulled without disconnecting the session first: the receiver freezes on a stale "connected" screen and needs a manual kill and relaunch, and the sender needs its Connect button clicked again after every unplug, replug or wake from sleep. These two LaunchAgents remove the manual steps.

- **Receiver watchdog** (runs on each receiver Mac): clears a frozen receiver when the link drops and has a fresh one waiting when it returns.
- **Sender reconnect** (runs on the sending Mac): re-establishes each session automatically when its link comes back or the sender wakes from sleep, and keeps the sender to a single instance.

Built and tested on a Thunderbolt bridge (`bridge0`) between one sender and two receivers, but nothing here is tied to that count or to any particular Mac model.

## Receiver watchdog

A LaunchAgent (`com.targetbridge.watchdog`) polls the Thunderbolt bridge link state (`ifconfig bridge0`, `status: active`) every 10 seconds and acts only on transitions, with a 2 second debounce on the inactive read:

- **unplug** (active to inactive): quit, `pkill -9` as a fallback, then relaunch the receiver. Clears the stale session and leaves a fresh receiver ready.
- **replug** (inactive to active): make sure the receiver is running so a reconnect from the sender cannot fail.

Edge-triggered, so it never loops and takes no action during normal connected use. It is receiver-only and not a keep-alive: a deliberate manual close stays closed until the next replug.

Installed layout on each receiver:

- `~/bin/targetbridge-watchdog.sh`
- `~/Library/LaunchAgents/com.targetbridge.watchdog.plist` (`StartInterval` 10, `RunAtLoad`)
- `~/Library/Application Support/targetbridge-watchdog/` holds `last-link-status` and `watchdog.log`

Deploy from the sender over SSH to every receiver:

```sh
./deploy.sh receiver-a receiver-b
```

Arguments are SSH hosts or aliases. Re-run any time to update.

```sh
# see what it has done
ssh receiver-a 'cat "$HOME/Library/Application Support/targetbridge-watchdog/watchdog.log"'
# disable on one box (for example to keep a receiver closed)
ssh receiver-a 'launchctl bootout gui/$(id -u)/com.targetbridge.watchdog'
# re-enable
ssh receiver-a 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.targetbridge.watchdog.plist'
```

## Sender reconnect

`com.targetbridge.sender-reconnect` polls every 5 seconds and fires the `targetbridge://connect` URL per receiver, independently, so a single dropped display recovers on its own. It reconnects a receiver when:

- **its link becomes available**: that receiver's reachability goes from no to yes (reseat, replug, link restored), or
- **the sender wakes from sleep**: detected as a gap between polls, and only if that receiver was connected before sleeping.

Tracking each receiver separately matters because the sender's `bridge0` stays active as long as any receiver's link is up, so a whole-bridge trigger never notices that one of several dropped.

It respects a deliberate disconnect: turning a display off in the sender leaves its link reachable, so there is no reachability edge and no reconnect, and the wake path is gated on "was connected before". It only fires connect when the peer is actually reachable (so it cannot hit `nw error 49 / EADDRNOTAVAIL` by connecting before the address exists) and the stream is down, with bounded retries that stop the instant the stream is up. This replaces TargetBridge's native `autoRestartOnWake`, which the URL-scheme docs flag as unreliable, so leave that off.

Two upstream behaviours it works around:

- **Duplicate sender instances.** Firing a connect URL while the sender is still registering with LaunchServices can launch a second instance, and each instance streams its own audio, which you hear as an echo. The script launches the sender explicitly first and reaps extra instances on every poll, keeping the one that owns the established streams.
- **Window pile-up.** Every `targetbridge://` URL delivered to a running sender opens another main window. When everything is down anyway, the sender is quit and relaunched bare so the pile resets, and retries are spaced at least 15 seconds apart.

Configure the receivers at the top of `sender/targetbridge-sender-reconnect.sh`:

```sh
SESSION=( 10.0.0.2 1  10.0.0.3 2 )   # receiver IP -> saved session index (1-indexed)
RECEIVERS=( 10.0.0.2 10.0.0.3 )
LOCAL_IP=10.0.0.1                     # the sender's own bridge address
PRESET=smooth1440p60
```

The session index must match the receiver saved in the sender for that session: `connect` with the wrong index rewrites that session's saved receiver.

Install on the sender:

```sh
./sender/install-sender.sh
```

Logs and state live in `~/Library/Application Support/targetbridge-sender-reconnect/`. Disable with `launchctl bootout gui/$(id -u)/com.targetbridge.sender-reconnect`.

## Notes

- Screen arrangement is preserved automatically: the sender persists it per receiver IP (`com.targetbridge.sender.extended-arrangement.<ip>.<res>`), so each receiver returns to its saved position on every reconnect.
- Manual reconnect one-liner, if you ever need it:
  `open "targetbridge://connect?receiver=10.0.0.2&session=1&mode=extended&preset=smooth1440p60&transport=net&local-ip=10.0.0.1"`
- See [CHANGELOG](CHANGELOG.md) for what was verified and when.

## Licence

MIT.
