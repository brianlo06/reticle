# Reticle

[![CI](https://github.com/brianlo06/reticle/actions/workflows/ci.yml/badge.svg)](https://github.com/brianlo06/reticle/actions/workflows/ci.yml)

A light-gun shooting gallery for a Mac plugged into a TV. Your phone is the gun: aim it at
the screen to move your reticle, tap to fire. Up to four players, each with their own phone
and their own crosshair.

Built on [AirPoint](https://github.com/brianlo06/airpoint), which supplies the whole
phone-to-Mac stack — TLS, pairing, the WebSocket protocol, and the motion pipeline. This
repository adds a hundred-line handler and a game.

**Needs no operating-system permissions at all.** AirPoint requires Accessibility because it
moves the system cursor; a game draws its own reticle, so there is nothing to grant.

---

## Play

```bash
git clone https://github.com/brianlo06/reticle.git && cd reticle
swift build
./.build/debug/reticle
```

**The QR code is on the game screen**, in the lobby, alongside the address and the six-digit
code. Nobody has to look at the terminal — which is the point, since it is invisible when the
game is fullscreen on a television. The panel disappears when a round starts and comes back
between rounds, and the code refreshes on screen when it rotates.

On each player's phone:

1. Scan the QR code on the TV, or open `https://<your-mac-ip>:8444`.
2. Safari warns that the certificate is untrusted. Expected — the game signs its own,
   because it runs on your machine rather than a public server. *Show Details* →
   *visit this website*. TLS is not optional: `DeviceMotionEvent` is a secure-context API,
   so a controller served over plain HTTP could never read the gyroscope.
3. Tap **Enable motion** and allow the prompt.
4. Approve the player in the terminal.
5. **Hold the aim pad**, point the phone at the screen, and hit **FIRE**.

```
--port <n>          TLS port (default 8444, one above AirPoint so both can run at once)
--players <n>       Seats, 1–4 (default 4)
--fullscreen        Start filling the screen
--auto-approve      Skip the approval prompt. Testing only.
```

## Modes

Press **Mode** on the phone in the lobby to cycle. Changing mid-round is refused — it would
invalidate the scores the round is about to report.

| | |
|---|---|
| **Arcade** | 45s, mixed sizes, gentle drift |
| **Precision** | Small, slow, long-lived targets and a longer cooldown. Rewards a steady hand over a fast one. |
| **Survival** | Fast and small. Three misses and you are out; the round ends when everyone is. |

A mode is a named set of `Game.Settings` rather than a branch in the rules, so every mode is
covered by the same tests and adding one is a matter of choosing numbers.

Targets drift and **bounce off the walls** rather than wrapping — a target that teleports
across the arena cannot be tracked, and tracking is the point of making them move.

## How a round works

**Lobby** → everyone presses FIRE to ready up. **Countdown** → 3, 2, 1. **Round** → 45
seconds. **Results** → scores, accuracy and best streak for 12 seconds, then back to the
lobby.

The trigger means "shoot" during a round and "I'm ready" in the lobby or on the results
screen, so a match can be started and restarted **entirely from the couch** — nobody has to
get up and touch the Mac. Joining mid-round drops you straight into the round in progress
rather than making you watch.

- Targets fade as they age. Shoot them early and small for more points.
- Three consecutive hits raise your multiplier, up to ×5. A miss resets it.
- Firing faster than the cooldown is ignored rather than counted as a miss — a rejected shot
  never happened, so it cannot break a streak.
- Overlapping targets resolve to the nearest one, so aiming into a cluster is not a coin flip.
- Ties on the leaderboard break toward the more accurate player.

**Aiming is relative, not absolute.** The phone reports how far it turned, not where it
points, because absolute aiming needs a magnetometer heading that is unusable indoors next
to a television. The reticle is clamped to the arena and **Recentre** snaps it back, which
together make relative aiming practical. `docs/design.md` has the reasoning.

## What comes from AirPoint

| | |
|---|---|
| `RemoteKit` | Wire protocol, validation, rate limiting, pairing crypto |
| `RemoteServer` | TLS with SAN management, HTTP + WebSocket on one port, pairing, sessions |
| `motion.js` | Gyroscope axis resolution, One-Euro filter, dead zone, clutch |

Served, not copied — `motion.js` ships inside `RemoteServer`, so the code that took the most
hardware debugging to get right cannot drift between the two projects.

What this repository actually adds:

- **`Sources/ReticleCore/`** — the rules. No SpriteKit, no network, no clock of its own:
  time is passed in and randomness injected, so a round replays deterministically in a test.
- **`Sources/Reticle/GameHost.swift`** — a `RemoteSessionHandler`. This is the entire
  difference between "a remote that moves a cursor" and "a game", because everything
  underneath already knew how to get a validated `pointer_move` from a phone to this machine
  safely.
- **`Sources/Reticle/GameScene.swift`** — SpriteKit rendering.
- **`Sources/Reticle/Resources/web/`** — a controller with an aim pad and a trigger.

`ServerConfig.maxConcurrentSessions` is the one line separating the two products: AirPoint
sets it to 1 because two phones fighting over one cursor is not a feature; this sets it to
the number of seats.

A tap sends `left_click` rather than a bespoke `fire` event, so **the stock AirPoint
controller can play this game unmodified** — a useful property for a project whose point is
reuse.

## Development

```bash
./tools/dev.sh    # build, test, launch the game, join it with a simulated player
swift test        # rules only, no window server or phone needed
```

`tools/probe.mjs` joins a running game over the real protocol and asserts 21 behaviours —
pairing, seat allocation, aiming, firing, validation, rate limiting, version gating. It is
AirPoint's protocol probe with the assertions adapted, which is itself a form of reuse.

## Feedback

The phone is a gun that kicks. The Mac sends back short cues and the phone renders them as a
haptic pulse plus a synthesised tone:

| | |
|---|---|
| Hit | Rising click; harder the longer your streak, with the score flashed on screen |
| Miss | Low buzz |
| Ready / countdown | One beat per second, so `3, 2, 1` is felt rather than watched |
| Round start / end | A fanfare and a long buzz |
| A shot the cooldown refused | **Nothing.** It never happened, so it must not be felt |

Tones are synthesised in the browser rather than loaded, so there are no audio assets and no
failure mode where the sound arrives after the moment it was for.

The cue vocabulary lives in AirPoint's protocol and is about *feel*, not meaning —
`success` at some intensity, never `targetDestroyed`. The host owns meaning, the client owns
presentation, and any other project built on `RemoteServer` inherits it.

## Playing from elsewhere

A photo of the join code is enough to play **if you are on the same Wi-Fi** — that is the
design, since everyone in the room scans the same code off the television. Each player still
appears as an approval prompt on the Mac.

It is not enough from another network. The address in the code is a private one and is not
routable from outside, and there is deliberately no relay and no port forwarding. To play
from somewhere else, put both machines on a mesh VPN (Tailscale, WireGuard): the remote
player looks like they are on the LAN, the VPN handles authentication, and nothing is
exposed to the internet.

`--auto-approve` skips the approval prompt and is refused on anything but loopback. It is a
testing convenience, not a hosting mode.

## Not done yet

- Sound.
- The reticle colours assume four seats; a fifth player would reuse the first colour.
- **Tuning is unvalidated.** It has been played on real hardware and works, but the round
  length, target sizes, spawn pacing and aim gain were all chosen by guess and have had one
  session of feedback. Reticle inherits AirPoint's `aimGain: 1.0` unchanged, and a game
  probably wants something twitchier than a cursor remote. All of them are single constants
  in `Game.Settings`.
- Only played single-player on real hardware. Multiplayer is verified by
  `tools/multiplayer-check.mjs` — four concurrent sessions, simultaneous fire, per-player
  feedback and seat eviction all pass against a live host — but no two actual phones have
  been in a round together.
- Modes and moving targets are tested but have not been played on hardware.

## Licence

MIT — see `LICENSE`.
