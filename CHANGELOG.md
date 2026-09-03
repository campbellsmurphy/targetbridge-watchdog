# Changelog

## 2026-09-03: Public release

- Sender-side files renamed from `m5/` to `sender/` and the LaunchAgent label from `com.targetbridge.m5-reconnect` to `com.targetbridge.sender-reconnect`. If you installed an earlier copy, `launchctl bootout` the old label before running `sender/install-sender.sh`.
- Plists no longer hard-code a home directory; the install scripts substitute it.

## 2026-07-03 (later): Window pile-up bounded

Every `targetbridge://` URL delivered to the sender opens another main window (upstream app behaviour, verified with a no-op URL; no suppress option, no menu-bar mode). The watchdog's reconnects were therefore stacking windows indefinitely, which reads as "multiple TargetBridges open" even though it is one process.

- **Full-outage restart:** when a reconnect cycle starts and the sender has zero established streams, quit the running sender first and relaunch bare, which resets the window pile instead of adding to it. A lone-drop reconnect still reuses the running sender.
- **Attempt spacing:** connect retries at least 15s apart (`RETRY_SPACING`), so a normal ~10s connect no longer fires a second URL and window at the 5s poll.
- ensure-launch marks the restart done, so a sibling receiver cannot quit a sender that was launched moments earlier mid-connect.
- Verified with two live watchdog-driven recoveries: end state 1 process, 2 streams, 3 windows (launch plus one URL per receiver), which is the floor by app design.

## 2026-07-03: Single-instance guard (audio echo fix)

Duplicate sender instances were each streaming their own audio to the receivers, producing an audible echo. Root cause: firing `open targetbridge://connect` while the sender app is not yet registered with LaunchServices (cold start, the ~6s retry loop, or both receivers connecting in the same second) can launch a second app instance instead of routing to the first.

- **Reap extras every poll:** if more than one `TargetBridge` process exists, keep the one that owns the established display streams (port 54321; fallback: oldest) and close the rest.
- **Launch-then-hand-over:** before any connect URL, if the sender is not running, launch it explicitly (`open -ga`) and wait for it to register, so the URL always routes to the existing instance.
- Verified live: spawned a duplicate with `open -n`; the guard closed it within one 5s poll, and the stream-owning instance and both displays were untouched.

## 2026-07-02: Signed off

Full unplug and replug of both receivers: both disconnected, then both auto-reconnected in the correct order with no manual intervention.

```
2026-07-02 00:38:13 10.0.0.2: Thunderbolt link available -> reconnecting (session 1)
2026-07-02 00:38:13 10.0.0.2: connect attempt 1
2026-07-02 00:38:13 10.0.0.3: Thunderbolt link available -> reconnecting (session 2)
2026-07-02 00:38:13 10.0.0.3: connect attempt 1
2026-07-02 00:38:24 10.0.0.2: stream up, connected
2026-07-02 00:38:24 10.0.0.3: stream up, connected
```

### Sender reconnect: per-receiver rewrite
- Track each receiver's reachability independently; reconnect a single dropped display the moment its link returns (5s poll), instead of only reacting to the sender's own `bridge0` (which stays active while either link is up, so a lone drop was missed).
- Only fire `connect` once the peer is reachable, which structurally avoids `nw error 49 / EADDRNOTAVAIL`.
- Keeps the wake path (gated on prior-connected) and respects a manual disconnect.
- Diagnosed a hardware quirk on one receiver: the second Thunderbolt port did not relink but the first did. The watchdog waits without spamming until the link is actually present.

## 2026-07-01: Initial build

- **Receiver watchdog** (`com.targetbridge.watchdog`) on each receiver, edge-triggered on the Thunderbolt bridge link: relaunch the receiver on unplug (clears the frozen stale session), ensure it is running on replug. Verified with a real cable pull.
- **Sender auto-reconnect**: fires `targetbridge://connect` on replug and on wake; respects a manual disconnect. Native `autoRestartOnWake` left off (flagged unreliable in the URL-scheme docs).
- **Screen order** preserved automatically via the sender's per-receiver-IP saved arrangement.
