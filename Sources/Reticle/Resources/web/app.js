// Reticle controller.
//
// The motion pipeline, gyroscope axis resolution and pairing handshake are AirPoint's,
// served from RemoteServer's own bundle rather than copied here — motion.js is the code
// that took the most hardware debugging to get right, and a fork of it would rot.
//
// What is specific to a game: a hold-to-aim surface and a trigger, and nothing else.

'use strict';

import {
  PointerPipeline,
  quatFromDeviceOrientation,
  quatConjugate,
  quatRotate,
  GyroAxisResolver,
  applyAxisCandidate,
} from '/motion.js';

const PROTOCOL_VERSION = 1;
const CLIENT_VERSION = '0.2.0';
const MAX_BUFFERED_BYTES = 32 * 1024;

const $ = (id) => document.getElementById(id);
const b64url = (v) => {
  const p = v.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(p + '='.repeat((4 - (p.length % 4)) % 4)), (c) => c.charCodeAt(0));
};
const toB64 = (bytes) => btoa(String.fromCharCode(...bytes));
const haptic = (p) => { if (navigator.vibrate) { try { navigator.vibrate(p); } catch {} } };

// Feedback for cues the Mac sends back.
//
// Tones are synthesised rather than loaded, so there are no audio assets to ship, nothing to
// preload, and no failure mode where the sound arrives after the moment it was for. iOS will
// not start an AudioContext without a user gesture, so it is created lazily on the first tap
// and resumed if the browser suspends it.
const Cue = {
  context: null,

  unlock() {
    try {
      if (!this.context) {
        const Ctor = window.AudioContext || window.webkitAudioContext;
        if (Ctor) this.context = new Ctor();
      }
      if (this.context && this.context.state === 'suspended') this.context.resume();
    } catch { this.context = null; }
  },

  // kind -> [vibration pattern, frequency Hz, duration s, waveform]
  recipes: {
    success: [[18], 880, 0.07, 'square'],
    failure: [[40], 160, 0.10, 'sawtooth'],
    warning: [[12, 60, 12], 500, 0.06, 'square'],
    start:   [[30, 60, 30, 60, 60], 660, 0.14, 'square'],
    finish:  [[120], 330, 0.30, 'triangle'],
    tick:    [[14], 740, 0.05, 'square'],
    info:    [[10], 520, 0.05, 'sine'],
  },

  play(kind, intensity = 0.6) {
    const recipe = this.recipes[kind] ?? this.recipes.info;
    const [pattern, frequency, duration, waveform] = recipe;
    const strength = Math.min(Math.max(intensity, 0), 1);

    // Intensity scales the buzz, so a five-streak hit is felt as harder than a first one.
    haptic(pattern.map((ms, i) => (i % 2 === 0 ? Math.round(ms * (0.5 + strength)) : ms)));

    if (!this.context || this.context.state !== 'running') return;
    try {
      const now = this.context.currentTime;
      const osc = this.context.createOscillator();
      const gain = this.context.createGain();
      osc.type = waveform;
      // A success rises in pitch with intensity; the rest hold their note.
      osc.frequency.setValueAtTime(frequency * (kind === 'success' ? 1 + strength * 0.5 : 1), now);
      // Ramped, never switched: an abrupt gain change is an audible click on every note.
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.02 + 0.10 * strength, now + 0.008);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
      osc.connect(gain).connect(this.context.destination);
      osc.start(now);
      osc.stop(now + duration + 0.02);
    } catch { /* audio is a bonus, never a requirement */ }
  },
};

function showError(message) {
  const el = $('connect-error');
  el.textContent = message;
  el.classList.remove('is-hidden');
}

function deviceId() {
  let id = localStorage.getItem('reticle.deviceId');
  if (!id || !/^[0-9a-f-]{1,64}$/.test(id)) {
    id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
                    (b) => b.toString(16).padStart(2, '0')).join('');
    localStorage.setItem('reticle.deviceId', id);
  }
  return id;
}

function playerName() {
  const ua = navigator.userAgent;
  if (/iPad/.test(ua)) return 'iPad';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/Android/.test(ua)) return 'Android';
  return 'Player';
}

function readFragment() {
  const hash = location.hash.replace(/^#/, '');
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  const secret = params.get('s');
  if (!secret) return null;
  history.replaceState(null, '', location.pathname);
  return { secret };
}

async function proof(keyBytes, nonce, id) {
  const key = await crypto.subtle.importKey('raw', keyBytes,
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const message = new Uint8Array(nonce.length + id.length);
  message.set(nonce, 0);
  message.set(new TextEncoder().encode(id), nonce.length);
  return toB64(new Uint8Array(await crypto.subtle.sign('HMAC', key, message)));
}

class Controller {
  constructor() {
    this.pipeline = new PointerPipeline();
    this.pipeline.setActive(false);
    this.axes = new GyroAxisResolver();
    this.credentials = readFragment();
    this.typedCode = null;
    this.seq = 0;
    this.socket = null;
    this.shouldReconnect = true;
    this.reconnectDelay = 250;

    this.attitude = null;
    this.rawRate = null;
    this.lastRateAt = 0;
    this.sampleCount = 0;
    this.previousGravity = null;
    this.lastGravityAt = null;
    this.usingRatePath = false;
    this.sensorError = null;
    this.sensorsAttached = false;

    this._wireUI();
  }

  // --- transport -----------------------------------------------------------

  connect() {
    try {
      this.socket = new WebSocket(`wss://${location.host}/`);
    } catch (error) {
      showError(`Could not open a connection: ${error.message}`);
      return;
    }
    this.socket.onopen = () => { this.reconnectDelay = 250; };
    this.socket.onmessage = (event) => this._receive(event.data);
    this.socket.onerror = () => showError(
      'Could not reach the game. If you have not accepted this Mac\'s certificate yet, '
      + 'reload and choose "visit this website". Otherwise check you are on the same Wi-Fi.');
    this.socket.onclose = () => {
      if (!this.shouldReconnect) return;
      setTimeout(() => this.connect(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 4000);
    };
  }

  send(type, payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.seq = (this.seq + 1) >>> 0;
    const frame = { v: PROTOCOL_VERSION, t: type, seq: this.seq, ts: Date.now() };
    if (payload !== undefined) frame.d = payload;
    this.socket.send(JSON.stringify(frame));
  }

  async _receive(raw) {
    let message;
    try { message = JSON.parse(raw); } catch { return; }

    if (message.t === 'challenge') {
      const nonce = b64url(message.d.nonce);
      const id = deviceId();
      let key;
      let channel;
      if (this.credentials) { key = b64url(this.credentials.secret); channel = 'qr'; }
      else if (this.typedCode) { key = new TextEncoder().encode(this.typedCode); channel = 'typed'; }
      else {
        $('connect-status').textContent = 'Join the game';
        $('code-entry').classList.remove('is-hidden');
        return;
      }
      this.send('hello', {
        deviceId: id,
        deviceName: playerName(),
        platform: 'web',
        clientVersion: CLIENT_VERSION,
        auth: { mode: 'code', proof: await proof(key, nonce, id), channel },
      });
    } else if (message.t === 'pair_pending') {
      $('connect-status').textContent = message.d.message || 'Approve on the Mac…';
    } else if (message.t === 'welcome') {
      $('screen-connect').classList.remove('is-visible');
      $('screen-play').classList.add('is-visible');
      this._startLoops();
      this._ensureMotion();
    } else if (message.t === 'cue') {
      Cue.play(message.d?.kind, message.d?.intensity ?? 0.6);
      if (message.d?.text) this._flash(message.d.text, message.d.kind);
    } else if (message.t === 'error') {
      if (message.d.fatal) {
        this.shouldReconnect = false;
        this.credentials = null;
        this.typedCode = null;
        $('screen-play').classList.remove('is-visible');
        $('screen-connect').classList.add('is-visible');
        $('code-entry').classList.remove('is-hidden');
        showError(message.d.message);
      }
    }
  }

  // --- sensors -------------------------------------------------------------

  static get needsPermission() {
    return typeof DeviceOrientationEvent !== 'undefined'
      && typeof DeviceOrientationEvent.requestPermission === 'function';
  }

  async _requestPermission() {
    if (!Controller.needsPermission) return true;
    try {
      const state = await DeviceOrientationEvent.requestPermission();
      if (typeof DeviceMotionEvent !== 'undefined'
          && typeof DeviceMotionEvent.requestPermission === 'function') {
        try { await DeviceMotionEvent.requestPermission(); } catch {}
      }
      return state === 'granted';
    } catch { return false; }
  }

  _ensureMotion() {
    if (typeof DeviceOrientationEvent === 'undefined') {
      showError('This browser exposes no motion sensors, so aiming will not work.');
      return;
    }
    if (Controller.needsPermission && localStorage.getItem('reticle.motion') !== 'yes') {
      $('screen-play').classList.remove('is-visible');
      $('screen-connect').classList.add('is-visible');
      $('code-entry').classList.add('is-hidden');
      $('motion-gate').classList.remove('is-hidden');
      return;
    }
    this._attachSensors();
  }

  _attachSensors() {
    if (this.sensorsAttached) return;
    this.sensorsAttached = true;
    const toRad = Math.PI / 180;
    window.addEventListener('deviceorientation', (event) => {
      if (event.alpha === null) return;
      this.attitude = quatFromDeviceOrientation(event.alpha, event.beta, event.gamma);
      this.sampleCount += 1;
      this._onSample();
    }, { passive: true });
    window.addEventListener('devicemotion', (event) => {
      const rate = event.rotationRate;
      if (!rate || rate.alpha === null) return;
      // Kept as the raw triple; which component is which axis is a per-browser question
      // that GyroAxisResolver answers from measurement.
      this.rawRate = [(rate.alpha || 0) * toRad, (rate.beta || 0) * toRad, (rate.gamma || 0) * toRad];
      this.lastRateAt = performance.now();
    }, { passive: true });
  }

  _onSample() {
    try { this._processSample(); }
    catch (error) { this.sensorError = error?.message ?? String(error); }
  }

  _processSample() {
    if (!this.attitude) return;
    const now = performance.now() / 1000;
    const gravity = quatRotate(quatConjugate(this.attitude), { x: 0, y: 0, z: -1 });
    const haveRate = this.rawRate && performance.now() - this.lastRateAt < 500;

    if (haveRate && gravity) {
      const dt = this.lastGravityAt === null ? 0 : now - this.lastGravityAt;
      this.axes.update(gravity, this.previousGravity, this.rawRate, dt);
      this.previousGravity = gravity;
      this.lastGravityAt = now;
      if (this.axes.isResolved) {
        this.usingRatePath = true;
        this.pipeline.processRate(applyAxisCandidate(this.axes.resolved, this.rawRate), gravity, now);
        return;
      }
    }
    this.usingRatePath = false;
    this.pipeline.process({ attitude: this.attitude, rotationRate: null,
                            accelerationG: null, timestamp: now });
  }

  _startLoops() {
    const tick = () => {
      requestAnimationFrame(tick);
      const delta = this.pipeline.drain(performance.now() / 1000);
      if (!delta) return;
      if (this.socket && this.socket.bufferedAmount > MAX_BUFFERED_BYTES) return;
      this.send('pointer_move', {
        dx: Math.round(delta.dx * 100) / 100,
        dy: Math.round(delta.dy * 100) / 100,
      });
    };
    requestAnimationFrame(tick);

    setInterval(() => this.send('ping', { id: 1 }), 2000);

    let lastCount = 0;
    let lastAt = performance.now();
    setInterval(() => {
      const now = performance.now();
      const hz = Math.round((this.sampleCount - lastCount) / ((now - lastAt) / 1000));
      lastCount = this.sampleCount;
      lastAt = now;
      const el = $('diag');
      const problem = this.sensorError ? `error: ${this.sensorError}`
        : hz === 0 ? 'no sensor data reaching the page' : null;
      el.textContent = problem
        ? `⚠ ${problem}`
        : `${this.usingRatePath ? 'gyro' : 'orient'} ${hz} Hz · `
          + `${this.axes.isResolved ? '' : 'axes:resolving · '}`
          + `aim ${this.pipeline.isActive ? 'ON' : 'off'}`;
      el.classList.toggle('is-bad', problem !== null);
    }, 500);
  }

  /// Briefly shows what just happened, for the glance down after a shot.
  _flash(text, kind) {
    const el = $('flash');
    if (!el) return;
    el.textContent = text;
    el.className = `flash is-${kind ?? 'info'}`;
    clearTimeout(this.flashTimer);
    this.flashTimer = setTimeout(() => { el.className = 'flash is-hidden'; }, 700);
  }

  // --- controls ------------------------------------------------------------

  _wireUI() {
    $('code-submit').addEventListener('click', () => {
      const code = $('code-input').value.trim();
      if (!/^\d{6}$/.test(code)) { showError('The code is six digits.'); return; }
      this.typedCode = code;
      $('connect-error').classList.add('is-hidden');
      $('code-entry').classList.add('is-hidden');
      $('connect-status').textContent = 'Approve on the Mac…';
      this.shouldReconnect = true;
      if (this.socket && this.socket.readyState === WebSocket.OPEN) this.socket.close();
      else this.connect();
    });

    $('enable-motion').addEventListener('click', async () => {
      if (!await this._requestPermission()) {
        showError('Motion access was denied, so aiming will not work.');
        return;
      }
      Cue.unlock();
      localStorage.setItem('reticle.motion', 'yes');
      $('motion-gate').classList.add('is-hidden');
      $('screen-connect').classList.remove('is-visible');
      $('screen-play').classList.add('is-visible');
      this._attachSensors();
    });

    // Hold to aim. The clutch is inherited from AirPoint and matters even more here: a gun
    // you cannot lower is a gun that fires wherever you were gesturing.
    const aim = $('aim');
    const engage = () => {
      this.pipeline.setActive(true);
      aim.classList.add('is-engaged');
      if (this.attitude) this.pipeline.recenter(this.attitude);
      haptic(8);
    };
    const release = () => {
      this.pipeline.setActive(false);
      aim.classList.remove('is-engaged');
    };
    aim.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      Cue.unlock();
      if (aim.setPointerCapture) { try { aim.setPointerCapture(event.pointerId); } catch {} }
      engage();
    }, { passive: false });
    aim.addEventListener('pointerup', (event) => { event.preventDefault(); release(); }, { passive: false });
    aim.addEventListener('pointercancel', release);

    // Fires on press, not on click: a trigger with the browser's tap delay feels broken.
    $('fire').addEventListener('pointerdown', (event) => {
      event.preventDefault();
      // Unlocking here rather than once at startup: iOS suspends the context when the page
      // backgrounds, and the trigger is the tap the player makes most often.
      Cue.unlock();
      this.send('left_click', { clicks: 1 });
    }, { passive: false });

    $('recenter').addEventListener('click', () => {
      if (this.attitude) this.pipeline.recenter(this.attitude);
      this.send('recenter', { toCenter: true });
      haptic(12);
    });

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { this.pipeline.setActive(false); this.pipeline.reset(); }
    });
    document.addEventListener('gesturestart', (event) => event.preventDefault());
  }
}

const controller = new Controller();
controller.connect();
