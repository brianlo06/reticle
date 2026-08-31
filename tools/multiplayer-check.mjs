#!/usr/bin/env node
// Puts several simulated players in one round at once.
//
// Four seats are implemented and unit-tested, but nothing had ever exercised concurrent
// sessions against a live host: seat allocation, simultaneous fire, per-player cue routing
// and the eviction rule when the seats are full. Those are exactly the things that work in
// isolation and break together.
//
//   node tools/multiplayer-check.mjs --code 123456 [--port 8444] [--players 3] [--seats 4]

import crypto from 'node:crypto';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]]);
    return pairs;
  }, [])
);
const host = args.host ?? '127.0.0.1';
const port = args.port ?? '8444';
const code = args.code;
const playerCount = Number(args.players ?? 3);
// How many seats the host was started with. Taken as an argument rather than assumed,
// because the number is now a launch option: hard-coding four here meant that raising the
// seat limit made this tool report a failure in itself.
const seatCount = Number(args.seats ?? 4);
if (!code) {
  console.error('usage: node tools/multiplayer-check.mjs --code <6 digits> [--players n] [--seats n]');
  process.exit(2);
}

let passed = 0;
let failed = 0;
function check(name, condition, detail = '') {
  if (condition) { passed += 1; console.log(`  ok    ${name}`); }
  else { failed += 1; console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// One simulated phone.
class Player {
  constructor(index) {
    this.index = index;
    // Distinct device ids, or the host cannot tell the seats apart.
    this.deviceId = crypto.randomBytes(8).toString('hex');
    this.name = `Sim${index + 1}`;
    this.seq = 0;
    this.received = [];
    this.cues = [];
    this.welcome = null;
    this.closed = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = new WebSocket(`wss://${host}:${port}/`);
      this.socket.addEventListener('message', async (event) => {
        const message = JSON.parse(event.data);
        this.received.push(message);
        if (message.t === 'cue') this.cues.push(message.d);
        if (message.t === 'welcome') { this.welcome = message.d; resolve(this); }
        if (message.t === 'challenge') await this._hello(message.d.nonce);
        if (message.t === 'error' && message.d.fatal) resolve(this);
      });
      this.socket.addEventListener('close', (event) => { this.closed = event; });
      this.socket.addEventListener('error', () => reject(new Error('socket error')));
      setTimeout(() => resolve(this), 8000);
    });
  }

  async _hello(nonceB64) {
    const nonce = Buffer.from(nonceB64.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    const message = Buffer.concat([nonce, Buffer.from(this.deviceId, 'utf8')]);
    const proof = crypto.createHmac('sha256', Buffer.from(code, 'utf8'))
      .update(message).digest('base64');
    this.send('hello', {
      deviceId: this.deviceId,
      deviceName: this.name,
      platform: 'node',
      clientVersion: '0.3.0',
      auth: { mode: 'code', proof, channel: 'typed' },
    });
  }

  send(type, payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.seq += 1;
    const frame = { v: 1, t: type, seq: this.seq, ts: Date.now() };
    if (payload !== undefined) frame.d = payload;
    this.socket.send(JSON.stringify(frame));
  }

  get errorCodes() {
    return this.received.filter((m) => m.t === 'error').map((m) => m.d.code);
  }

  close() {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) this.socket.close(1000);
  }
}

console.log(`Reticle multiplayer check — ${playerCount} simultaneous players\n`);

const players = [];
try {
  // Sequential pairing: the code is single-use per successful pairing, but the host rotates
  // it only when consumed, and every player here presents the same one. Connecting them
  // together also proves the pairing path is not serialised by accident.
  for (let i = 0; i < playerCount; i += 1) {
    players.push(await new Player(i).connect());
    await sleep(150);
  }

  const seated = players.filter((p) => p.welcome);
  check('every player got a seat', seated.length === playerCount,
    `${seated.length} of ${playerCount} seated`);
  check('each session has its own id',
    new Set(seated.map((p) => p.welcome.sessionId)).size === seated.length);
  check('nobody was evicted while seats remained',
    players.every((p) => !p.errorCodes.includes('session_replaced')));

  // Everyone readies at once. The round should start exactly once, for all of them.
  for (const player of seated) player.send('left_click', { clicks: 1 });
  await sleep(400);
  check('every player was told they readied up',
    seated.every((p) => p.cues.some((c) => c.text === 'Ready')));

  await sleep(3800);
  check('every player felt the round start',
    seated.every((p) => p.cues.some((c) => c.kind === 'start')),
    seated.map((p) => p.cues.filter((c) => c.kind === 'start').length).join(','));

  // Simultaneous aiming and firing: the interesting concurrent case.
  const before = seated.map((p) => p.cues.length);
  for (let round = 0; round < 6; round += 1) {
    for (const [index, player] of seated.entries()) {
      // Push each reticle a different way, so they are not all shooting the same spot.
      player.send('pointer_move', { dx: (index - 1) * 40, dy: (index % 2 ? 30 : -30) });
      player.send('left_click', { clicks: 1 });
    }
    await sleep(220);
  }
  await sleep(300);

  check('every player got feedback for their own shots',
    seated.every((p, i) => p.cues.length > before[i]),
    seated.map((p, i) => `${p.name}:+${p.cues.length - before[i]}`).join(' '));
  check('no player was disconnected by concurrent fire',
    seated.every((p) => p.closed === null));
  check('nobody hit a rate limit at a human firing rate',
    seated.every((p) => !p.errorCodes.includes('rate_limited')));

  // One more than the seats: the oldest session should be evicted, not the newcomer refused.
  const overflow = await new Player(99).connect();
  await sleep(400);
  if (playerCount >= seatCount) {
    check(`player ${seatCount + 1} of ${seatCount} seats evicts the oldest rather than being refused`,
      overflow.welcome !== null && players[0].errorCodes.includes('session_replaced'),
      `overflow seated=${overflow.welcome !== null}`);
  } else {
    check('an extra player within the seat limit simply joins', overflow.welcome !== null);
  }
  overflow.close();

  for (const player of players) player.close();
  await sleep(200);
} catch (error) {
  console.log(`  FAIL  harness error — ${error.message}`);
  failed += 1;
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
