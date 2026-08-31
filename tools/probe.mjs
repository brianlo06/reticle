#!/usr/bin/env node
// Reticle game probe.
//
// Joins a running game as a player without needing a phone: pairs with a typed code, takes
// a seat, aims and fires, and checks the replies. Adapted from AirPoint's protocol probe,
// which is itself a form of reuse — the wire protocol is the same one.
//
// Usage:
//   node tools/probe.mjs --code 123456 [--port 8444] [--hold 20]
//
// The game must be running. Self-signed certificate verification is disabled because the
// whole point of the game's certificate is that it signs itself.

import crypto from 'node:crypto';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]]);
    return pairs;
  }, [])
);

const host = args.host ?? '127.0.0.1';
// Keeps the session open after the assertions, for observing host-side behaviour that only
// happens while a client is connected — focus reporting, idle timeouts, and the like.
const holdSeconds = Number(args.hold ?? 0);
const port = args.port ?? '8443';
const code = args.code;
if (!code) {
  console.error('usage: node tools/probe.mjs --code <6 digits> [--host h] [--port p]');
  process.exit(2);
}

const DEVICE_ID = 'abcdef0123456789';
let seq = 0;
let passed = 0;
let failed = 0;
const received = [];
let closeEvent = null;

function check(name, condition, detail = '') {
  if (condition) {
    passed += 1;
    console.log(`  ok    ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

function send(socket, type, payload) {
  seq += 1;
  const frame = { v: 1, t: type, seq, ts: Date.now() };
  if (payload !== undefined) frame.d = payload;
  socket.send(JSON.stringify(frame));
}

function waitFor(type, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const existing = received.find((m) => m.t === type);
    if (existing) return resolve(existing);
    const started = Date.now();
    const poll = setInterval(() => {
      const found = received.find((m) => m.t === type);
      if (found) {
        clearInterval(poll);
        resolve(found);
      } else if (Date.now() - started > timeoutMs) {
        clearInterval(poll);
        reject(new Error(`timed out waiting for '${type}'; saw: ${received.map((m) => m.t).join(', ') || 'nothing'}`));
      }
    }, 20);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const socket = new WebSocket(`wss://${host}:${port}/`);

socket.addEventListener('message', (event) => {
  try {
    received.push(JSON.parse(event.data));
  } catch {
    console.log('  FAIL  server sent a non-JSON frame');
    failed += 1;
  }
});

socket.addEventListener('error', (event) => {
  console.error('socket error:', event.message ?? event);
  process.exit(1);
});

socket.addEventListener('close', (event) => {
  closeEvent = event;
  // The final assertions deliberately provoke a fatal error, so the close arrives while a
  // check is still pending. Give it a moment to finish rather than exiting mid-assertion.
  setTimeout(() => {
    console.log(`\nsocket closed: code=${event.code} reason=${event.reason || '(none)'}`);
    check('a fatal error closes with a reason, not a bare reset',
      event.code !== 1006, `got close code ${event.code}`);
    console.log(`\n${passed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  }, 400);
});

socket.addEventListener('open', async () => {
  console.log(`connected to wss://${host}:${port}/\n`);
  try {
    // --- Handshake ---
    const challenge = await waitFor('challenge');
    check('server sends a challenge before hello', typeof challenge.d?.nonce === 'string');
    check('challenge carries the server version', typeof challenge.d?.serverVersion === 'string');

    // proof = HMAC-SHA256(code, nonce || deviceId)
    const nonce = Buffer.from(challenge.d.nonce.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    const message = Buffer.concat([nonce, Buffer.from(DEVICE_ID, 'utf8')]);
    const proof = crypto.createHmac('sha256', Buffer.from(code, 'utf8')).update(message).digest('base64');

    send(socket, 'hello', {
      deviceId: DEVICE_ID,
      deviceName: 'Protocol probe',
      platform: 'node',
      clientVersion: '0.1.0',
      auth: { mode: 'code', proof },
    });

    const welcome = await waitFor('welcome', 8000);
    check('pairing succeeds and yields a welcome', typeof welcome.d?.sessionId === 'string');
    check('welcome reports displays', Array.isArray(welcome.d?.displays) && welcome.d.displays.length > 0);
    // A game needs no OS permission at all — it draws its own reticle rather than moving
    // the system cursor — so it reports readiness rather than an accessibility grant.
    check('welcome reports the host as ready', welcome.d?.permissions?.ready === true);
    check('welcome advertises aiming and firing',
      welcome.d?.features?.includes('pointer') && welcome.d?.features?.includes('fire'));
    check('welcome does not advertise cursor-remote features',
      !welcome.d?.features?.includes('keyboard') && !welcome.d?.features?.includes('media'));
    check('the arena is reported as a display', (welcome.d?.displays?.[0]?.w ?? 0) > 0);

    // --- Latency ---
    const sentAt = Date.now();
    send(socket, 'ping', { id: 99 });
    const pong = await waitFor('pong');
    check('ping is answered with a matching id', pong.d?.id === 99);
    console.log(`        round-trip: ${Date.now() - sentAt} ms`);

    // --- Feedback cues coming back from the host ---
    //
    // The whole point of this addition: the phone should be told what happened. Readying up
    // starts a countdown, which should produce a beat per second and then a start cue.
    const cueMark = received.length;
    send(socket, 'left_click', { clicks: 1 });          // ready up
    await sleep(200);
    const readyCue = received.slice(cueMark).find((m) => m.t === 'cue');
    check('readying up is acknowledged with a cue', readyCue?.d?.kind === 'info',
      `got ${readyCue ? readyCue.d.kind : 'no cue'}`);

    await sleep(3600);                                   // countdown, then the round starts
    const cues = received.slice(cueMark).filter((m) => m.t === 'cue');
    check('the countdown is felt beat by beat',
      cues.filter((m) => m.d.kind === 'tick').length >= 2,
      `saw ${cues.filter((m) => m.d.kind === 'tick').length} ticks`);
    check('the round start is felt', cues.some((m) => m.d.kind === 'start'));
    check('every cue carries an intensity in range',
      cues.every((m) => typeof m.d.intensity === 'number'
                        && m.d.intensity >= 0 && m.d.intensity <= 1));

    // Now in a round: a shot at an empty patch of arena should read as a miss.
    const shotMark = received.length;
    send(socket, 'left_click', { clicks: 1 });
    await sleep(250);
    const shotCue = received.slice(shotMark).find((m) => m.t === 'cue');
    check('a shot during a round produces a hit or miss cue',
      shotCue?.d?.kind === 'failure' || shotCue?.d?.kind === 'success',
      `got ${shotCue ? shotCue.d.kind : 'no cue'}`);

    // --- Every event type is accepted ---
    const before = received.length;
    // Aim toward a corner, then fire a burst. Events the game ignores are sent too: they
    // must be dropped silently, not rejected, since a stock AirPoint controller offers them.
    for (let i = 0; i < 30; i += 1) send(socket, 'pointer_move', { dx: -12, dy: 8 });
    send(socket, 'pointer_move', { dx: 3.5, dy: -2 });
    send(socket, 'scroll', { dx: 0, dy: -40, unit: 'px' });
    send(socket, 'left_click', { clicks: 1 });
    send(socket, 'right_click', { clicks: 1 });
    send(socket, 'drag_start', { button: 'left' });
    send(socket, 'drag_end', { button: 'left' });
    send(socket, 'key_press', { key: 'ArrowDown', mods: [] });
    send(socket, 'text_input', { text: 'hello from the probe' });
    send(socket, 'media_command', { command: 'play_pause' });
    send(socket, 'recenter', { toCenter: false });
    send(socket, 'calibration', { stage: 'complete', holdMs: 1200, noiseRadS: 0.001 });
    await sleep(300);
    check('no errors for any valid event type',
      received.slice(before).every((m) => m.t !== 'error'),
      JSON.stringify(received.slice(before).filter((m) => m.t === 'error')));

    // --- Validation ---
    async function expectError(name, frame, expectedCode) {
      const mark = received.length;
      socket.send(JSON.stringify(frame));
      await sleep(200);
      const error = received.slice(mark).find((m) => m.t === 'error');
      check(name, error?.d?.code === expectedCode,
        `got ${error ? error.d.code : 'no error'}, wanted ${expectedCode}`);
    }

    await expectError('rejects an unknown event type',
      { v: 1, t: 'exec_shell', seq: ++seq, ts: Date.now(), d: {} }, 'unknown_type');
    await expectError('rejects a key outside the allowlist',
      { v: 1, t: 'key_press', seq: ++seq, ts: Date.now(), d: { key: 'Eject' } }, 'invalid_payload');
    await expectError('rejects an unknown modifier',
      { v: 1, t: 'key_press', seq: ++seq, ts: Date.now(), d: { key: 'a', mods: ['hyper'] } }, 'invalid_payload');
    await expectError('rejects over-long text',
      { v: 1, t: 'text_input', seq: ++seq, ts: Date.now(), d: { text: 'x'.repeat(2000) } }, 'invalid_payload');
    await expectError('rejects a media command that does not exist',
      { v: 1, t: 'media_command', seq: ++seq, ts: Date.now(), d: { command: 'format_disk' } }, 'invalid_payload');

    // Clamping, not rejection: the cursor must stay usable during a burst.
    const clampMark = received.length;
    send(socket, 'pointer_move', { dx: 1e6, dy: -1e6 });
    await sleep(200);
    check('clamps an out-of-range pointer delta instead of erroring',
      !received.slice(clampMark).some((m) => m.t === 'error'));

    // --- Rate limiting ---
    const floodMark = received.length;
    for (let i = 0; i < 600; i += 1) send(socket, 'pointer_move', { dx: 0.5, dy: 0 });
    await sleep(400);
    const limited = received.slice(floodMark).filter((m) => m.d?.code === 'rate_limited');
    check('throttles a pointer flood', limited.length > 0);
    check('throttling is not fatal', limited.every((m) => m.d.fatal === false));

    // A click must still get through immediately after a flood: per-type buckets mean a
    // pointer flood cannot starve the user's ability to click or disconnect.
    const clickMark = received.length;
    send(socket, 'left_click', { clicks: 1 });
    await sleep(200);
    check('a click still works during a pointer flood',
      !received.slice(clickMark).some((m) => m.d?.code === 'rate_limited'));

    // --- Version gate --- (skipped when holding, since it ends the session)
    if (holdSeconds > 0) {
      console.log(`\n  holding the session open for ${holdSeconds}s — switch apps now`);
      await sleep(holdSeconds * 1000);
      if (socket.readyState === WebSocket.OPEN) socket.close(1000);
      return;
    }
    const versionMark = received.length;
    socket.send(JSON.stringify({ v: 2, t: 'ping', seq: ++seq, ts: Date.now(), d: { id: 1 } }));
    await sleep(200);
    const versionError = received.slice(versionMark).find((m) => m.t === 'error');
    check('refuses an unsupported protocol version',
      versionError?.d?.code === 'unsupported_version' && versionError.d.fatal === true);

    if (holdSeconds > 0) {
      console.log(`\n  holding the session open for ${holdSeconds}s — switch apps now`);
      // Skip the version-gate assertion, which deliberately provokes a fatal close.
      await sleep(holdSeconds * 1000);
      if (socket.readyState === WebSocket.OPEN) socket.close(1000);
      return;
    }

    await sleep(300);
    if (socket.readyState === WebSocket.OPEN) socket.close(1000);
  } catch (error) {
    console.error(`\nprobe failed: ${error.message}`);
    failed += 1;
    if (socket.readyState === WebSocket.OPEN) socket.close(1000);
    else process.exit(1);
  }
});
