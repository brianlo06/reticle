# Reticle

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

A window opens and the terminal prints a QR code. On each player's phone:

1. Scan the QR code, or open the printed `https://<your-mac-ip>:8444`.
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

## How it plays

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

## Not done yet

- Rounds and a timer. Right now it runs forever.
- No score feedback on the phone; the TV shows everything.
- Sound.
- The reticle colours assume four seats; a fifth player would reuse the first colour.
- Only tested with a single player on real hardware.

## Licence

MIT — see `LICENSE`.
