# Reticle — design notes

## Why relative aiming, when a light gun is the obvious metaphor

A real light gun is absolute: it knows where on the screen it points. Reproducing that with a
phone needs a stable heading, which means the magnetometer — and indoors, beside a laptop and
a television, magnetic heading is noisy and laggy. AirPoint hit exactly this: horizontal
aiming was visibly worse than vertical, because iOS derives `deviceorientation`'s alpha from
the magnetometer while pitch comes from clean gyro fusion.

So aiming here is relative, driven from the gyroscope, and the shooting-gallery form is built
around that choice rather than fighting it:

- The reticle is **clamped to the arena**, so drift cannot carry it somewhere unrecoverable.
- **Recentre** snaps it to the middle, and engaging the aim clutch re-seeds the reference, so
  every time you raise the phone you start from a known state.
- Targets are large enough that a few pixels of accumulated drift never decides a hit.

Absolute aiming would be better if the room could be trusted. It cannot, so the game is
designed for what the sensors actually deliver.

## Why the rules have no clock

`Game` takes the time as a parameter and its randomness as an injected generator. Nothing in
it reads `Date()` or `SystemRandomNumberGenerator` on its own. That makes a whole round
replayable: spawn pacing, scoring, streak multipliers and expiry are all verified in
milliseconds without a window server or a phone.

The property that made this worth doing is the spawn equilibrium. With a 0.75 s interval and
2.2–4.0 s lifetimes, the field settles at roughly four targets regardless of the cap — and
that number, not `maxTargets`, is what determines how busy the screen feels. A test pins the
relationship, because changing either constant alone silently changes the feel of the game.

## Why a rejected shot is not a miss

Firing faster than the cooldown returns `.tooSoon`, which does not increment the shot count
and does not break a streak. A shot that never happened should not be punished — otherwise
the cooldown becomes a trap rather than a pacing mechanism, and holding the trigger becomes
actively harmful rather than merely useless.

## Why `left_click` and not a `fire` event

Adding a bespoke event would have been trivial. Reusing the existing one means the stock
AirPoint controller can play this game with no changes at all, which is a real test of
whether the protocol was designed at the right level of abstraction. It was: the wire format
describes *what the user did*, not *what it should mean*, and the meaning is the host's.

## What building this found in the library

Two bugs, both invisible from inside AirPoint and both surfacing within minutes of a second
host existing:

- `PairingService` held its approver weakly, so a caller constructing one inline had every
  pairing refused with a message indistinguishable from a wrong code.
- `sessionDidEnd` fired for connections that never became sessions, so every plain HTTPS
  request for a static file looked like a player joining and leaving.

Neither would have been found by more careful reading of AirPoint. That is the argument for
extracting a library by actually building on it rather than by planning to.
