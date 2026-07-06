#!/usr/bin/env bun
// ada-brain — the persistent conversation loop (docs/PLAN.md §6).
//
// Pipeline: perception-voice `subscribe words` (partials + utterances)
//   → activation gate (PTT overlap / wake word / conversation window)
//   → agl agent turn (lm-studio, token streaming)
//   → sentence splitter → presence-voice speak, sentence by sentence
//   → state events to the avatar at every transition.
//
// The brain is the unix-socket *server* for the avatar (JSON lines,
// docs/PROTOCOL.md §4) and a *client* of both voice services.

import Agent from 'agl-ai';
import yaml from 'js-yaml';
import net from 'node:net';
import { existsSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'fs';
import { spawn } from './lib/spawn.mjs';
import { clamp, forceInt, forceRx } from './lib/validate.mjs';

// Single-instance lock: a second brain would steal the avatar socket and
// double-run every turn. Pidfile + liveness check (no flock in JS): a
// stale file from a crash is detected via kill(pid, 0) and taken over.
const LOCK_PATH = new URL('../.brain.lock', import.meta.url).pathname;

function acquireInstanceLock() {
  try {
    const pid = Number(readFileSync(LOCK_PATH, 'utf8').trim());
    if (pid && pid !== process.pid) {
      try {
        process.kill(pid, 0); // throws if not running
        console.error(`error: another ada-brain is already running (pid ${pid}, lock: ${LOCK_PATH})`);
        console.error('       stop it first: systemctl --user stop ada-brain');
        process.exit(1);
      } catch { /* stale lock from a dead process — take over */ }
    }
  } catch { /* no lock file */ }
  writeFileSync(LOCK_PATH, `${process.pid}\n`);
}

function releaseInstanceLock() {
  try {
    if (Number(readFileSync(LOCK_PATH, 'utf8').trim()) === process.pid) unlinkSync(LOCK_PATH);
  } catch { /* already gone */ }
}

const CFG = {
  brainSock: process.env.ADA_BRAIN_SOCK
    || `${process.env.XDG_RUNTIME_DIR || '/tmp'}/ada-brain.sock`,
  perceptionSock: process.env.ADA_PERCEPTION_SOCK
    || '/workspace/perception-voice/perception.sock',
  presenceSock: process.env.ADA_PRESENCE_SOCK || '/tmp/presence-voice.sock',
  voice: process.env.ADA_VOICE || 'ada',
  model: process.env.ADA_MODEL || 'lm-studio:google/gemma-4-e4b',
  wake: new RegExp(process.env.ADA_WAKE || '\\bada\\b', 'i'),
  convWindowMs: Number(process.env.ADA_CONV_WINDOW_MS || 8000),
  activityDir: process.env.ADA_ACTIVITY_DIR || '/workspace/mari/activity',
  sfxDir: new URL('../sfx/', import.meta.url).pathname,
  historyMax: 24,
};

const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 23)}]`, ...a);

// ---------------------------------------------------------------------------
// State machine + avatar socket server (JSON lines)

const state = { listening: false, active: false, thinking: false, speaking: false };
const avatars = new Set();

function broadcast(obj) {
  const line = JSON.stringify(obj) + '\n';
  for (const s of avatars) {
    try { s.write(line); } catch { /* dropped on close */ }
  }
}

function setState(patch) {
  let changed = false;
  for (const k of Object.keys(patch)) {
    if (state[k] !== patch[k]) { state[k] = patch[k]; changed = true; }
  }
  if (changed) broadcast({ ev: 'state', ...state });
}

function startAvatarServer() {
  if (existsSync(CFG.brainSock)) unlinkSync(CFG.brainSock);
  const server = net.createServer((sock) => {
    avatars.add(sock);
    sock.write(JSON.stringify({ ev: 'state', ...state }) + '\n');
    log('avatar connected');
    let acc = '';
    sock.on('data', (buf) => {
      acc += buf.toString();
      let idx;
      while ((idx = acc.indexOf('\n')) >= 0) {
        const line = acc.slice(0, idx).trim();
        acc = acc.slice(idx + 1);
        if (!line) continue;
        try { onAvatarEvent(JSON.parse(line)); } catch { log('bad avatar line:', line); }
      }
    });
    sock.on('close', () => { avatars.delete(sock); log('avatar disconnected'); });
    sock.on('error', () => avatars.delete(sock));
  });
  server.listen(CFG.brainSock);
  log(`avatar server listening on unix://${CFG.brainSock}`);
}

// ---------------------------------------------------------------------------
// PTT + activation gate

let pttDown = false;
const pttIntervals = []; // {down, up} unix seconds, recent only
let convWindowUntil = 0;

function onAvatarEvent(ev) {
  if (ev.ev === 'ptt') {
    const now = Date.now() / 1000;
    if (ev.down && !pttDown) {
      pttDown = true;
      pttIntervals.push({ down: now, up: null });
      sfx('squelch-on');
      setState({ active: true });
    } else if (!ev.down && pttDown) {
      pttDown = false;
      pttIntervals.at(-1).up = now;
      while (pttIntervals.length > 8) pttIntervals.shift();
      sfx('click-off');
      maybeIdle();
    }
  } else if (ev.ev === 'click') {
    cancelAll('click');
  } else if (ev.ev === 'quit') {
    log('avatar quit');
  }
}

// An utterance passes if PTT overlapped its time window, it names Ada, or
// it falls inside the post-exchange conversation window (plan §6.2).
function activationGate(utt) {
  const SLOP = 0.3; // seconds — VAD tails and clock slop
  if (pttDown) return 'ptt';
  if (utt.t_start && utt.t_end) {
    for (const iv of pttIntervals) {
      const up = iv.up ?? Date.now() / 1000;
      if (iv.down <= utt.t_end + SLOP && up >= utt.t_start - SLOP) return 'ptt';
    }
  }
  if (CFG.wake.test(utt.text)) return 'wake';
  if (Date.now() < convWindowUntil) return 'window';
  return null;
}

function maybeIdle() {
  if (!currentTurn && !pttDown && Date.now() >= convWindowUntil) {
    setState({ active: false });
  }
}

// ---------------------------------------------------------------------------
// sfx feedback (borrowed from /workspace/whisper's proven set)

function sfx(name) {
  const path = `${CFG.sfxDir}${name}.wav`;
  if (existsSync(path)) spawn('paplay', [path]); // fire and forget
}

// ---------------------------------------------------------------------------
// presence-voice speaker: `preset\ttext\n` → OK after playback completes,
// so one in-flight request at a time both serializes sentences and gives us
// an accurate "speaking" signal.

class Speaker {
  queue = [];
  pumping = false;

  enqueue(text, turn) {
    const clean = text.replace(/[\t\n]+/g, ' ').trim();
    if (!clean) return;
    this.queue.push({ text: clean, turn });
    this.pump();
  }

  clear() { this.queue.length = 0; }

  async pump() {
    if (this.pumping) return;
    this.pumping = true;
    try {
      while (this.queue.length) {
        const { text, turn } = this.queue.shift();
        if (turn?.cancelled) continue;
        setState({ speaking: true });
        const t0 = performance.now();
        try {
          await speakOnce(CFG.voice, text);
          turn?.lat && (turn.lat.lastAudioDone = performance.now());
          log(`spoke (${Math.round(performance.now() - t0)}ms): ${text}`);
        } catch (e) {
          log(`speak failed: ${e.message} — "${text}"`);
        }
      }
    } finally {
      this.pumping = false;
      setState({ speaking: false });
      if (!currentTurn) {
        convWindowUntil = Date.now() + CFG.convWindowMs;
        setTimeout(maybeIdle, CFG.convWindowMs + 50);
      }
    }
  }
}

function speakOnce(preset, text) {
  return new Promise((resolve, reject) => {
    let buf = '';
    let settled = false;
    const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
    const sock = net.connect(CFG.presenceSock, () => {
      // presence-voice line protocol: preset \t speaker \t effects \t text
      // (empty speaker/effects = daemon defaults)
      sock.write(`${preset}\t\t\t${text}\n`);
    });
    sock.on('data', (d) => {
      buf += d.toString();
      if (buf.includes('\n')) {
        sock.end();
        buf.startsWith('OK') ? done(resolve) : done(reject, new Error(buf.trim()));
      }
    });
    sock.on('error', (e) => done(reject, e));
    sock.on('close', () => done(reject, new Error('presence-voice closed early')));
  });
}

const speaker = new Speaker();

// ---------------------------------------------------------------------------
// Sentence splitter over the token stream: speak each sentence the moment
// it completes instead of waiting for the full reply (plan §6.4).

class SentenceSplitter {
  constructor(onSentence) { this.onSentence = onSentence; this.acc = ''; }
  push(delta) {
    this.acc += delta;
    let m;
    while ((m = this.acc.match(/^(.*?[.!?])(?:\s+|$)(?=\S|$)/s)) && /\S{2,}/.test(m[1])) {
      const sentence = m[1].trim();
      this.acc = this.acc.slice(m[0].length);
      if (sentence) this.onSentence(sentence);
      if (!this.acc) break;
    }
  }
  flush() {
    const rest = this.acc.trim();
    this.acc = '';
    if (rest) this.onSentence(rest);
  }
}

// ---------------------------------------------------------------------------
// Tools

// mari activity configs: aliased app launches + named commands (plan §9.2)
function loadActivities() {
  const apps = {};      // app name -> full shell line
  const commands = {};  // "activity.key" -> shell line
  if (!existsSync(CFG.activityDir)) return { apps, commands };
  for (const f of readdirSync(CFG.activityDir)) {
    if (!f.endsWith('.yml') && !f.endsWith('.yaml')) continue;
    let doc;
    try { doc = yaml.load(readFileSync(`${CFG.activityDir}/${f}`, 'utf8')); } catch { continue; }
    if (!doc?.name) continue;
    if (doc.shell_aliases) {
      for (const target of Object.values(doc.shell_aliases)) {
        apps[target] = doc.shell_prefix ? `${doc.shell_prefix} ${target}` : target;
      }
    }
    if (doc.commands) {
      for (const [key, val] of Object.entries(doc.commands)) {
        const shell = typeof val === 'string' ? val : val?.shell;
        if (typeof shell === 'string') commands[`${doc.name}.${key}`] = shell;
      }
    }
  }
  return { apps, commands };
}

const activities = loadActivities();
log(`activities: ${Object.keys(activities.apps).length} apps, ${Object.keys(activities.commands).length} commands`);

// Launcher-style commands may run long (apps, sessions): report started
// rather than hanging the turn.
async function shellTool(shellLine, timeoutMs = 10000) {
  const child = spawn('bash', ['-c', shellLine]);
  const timeout = new Promise((r) => setTimeout(() => r('TIMEOUT'), timeoutMs));
  const result = await Promise.race([child.promise, timeout]);
  if (result === 'TIMEOUT') return `started (still running): ${shellLine}`;
  return child.code === 0
    ? `ok: ${shellLine}${child.stdout ? ` — ${child.stdout.trim().slice(0, 200)}` : ''}`
    : `failed (exit ${child.code}): ${shellLine} — ${(child.stderr || child.stdout).trim().slice(0, 200)}`;
}

function registerTools(agent) {
  // -- home lights, ported from agl home.mjs --------------------------------
  agent.Tool('desk_light', 'control power and/or light color emitted by my govee RGB LED desk lamp. ' +
    'If the request names or implies a color (e.g. "turn it blue"), you MUST provide r, g, and b together. ' +
    'Only provide power when the request is purely about turning the lamp on/off, with no color mentioned.', {
    power: { type: 'boolean', description: 'turn the lamp on or off. omit unless the request is only about power.' },
    r: { type: 'integer', description: 'red 0-255, required together with g and b when a color is requested.' },
    g: { type: 'integer', description: 'green 0-255, required together with r and b when a color is requested.' },
    b: { type: 'integer', description: 'blue 0-255, required together with r and g when a color is requested.' },
    brightness: { type: 'integer', description: 'range 0-35; perceived brightness is non-linear, finer at low values.' },
  }, [], async (ctx, { power, r, g, b, brightness }) => {
    let result = '';
    if (typeof power === 'boolean') {
      const child = spawn('govee', [power ? 'on' : 'off']);
      await child.promise;
      result += child.code === 0 ? `lamp power is now ${power ? 'on' : 'off'}. ` : `failed to set lamp power. `;
    }
    if (r !== undefined || g !== undefined || b !== undefined) {
      r = clamp(forceInt(r, 0), 0, 255); g = clamp(forceInt(g, 0), 0, 255); b = clamp(forceInt(b, 0), 0, 255);
      const child = spawn('govee', ['rgb', r, g, b]);
      await child.promise;
      result += child.code === 0 ? `lamp color is now rgb(${r},${g},${b}). ` : `failed to set lamp color. `;
    }
    if (brightness) {
      brightness = clamp(forceInt(brightness, 0), 0, 35);
      const child = spawn('govee', ['brightness', brightness]);
      await child.promise;
      result += child.code === 0 ? `lamp brightness=${brightness}.` : `failed to set lamp brightness.`;
    }
    return result || 'no lamp action requested.';
  });

  agent.Tool('pc_light_color', 'control light color emitted by my desktop PC tower chassis LED strip', {
    color: { type: 'string', description: 'hex format, e.g. FF0000' },
    brightness: { type: 'integer', description: 'range 0-50. default 50' },
  }, ['color'], async (ctx, { color, brightness = 50 }) => {
    color = forceRx(/^[0-9A-Fa-f]{6}$/, color, '000000');
    brightness = clamp(forceInt(brightness, 0), 0, 50);
    const child = spawn('openrgb', ['-d', '0', '--mode', 'static', '--color', color, '--brightness', brightness]);
    await child.promise;
    return child.code === 0
      ? `PC light is now color=${color} brightness=${brightness}.`
      : `failed to set PC light color.`;
  });

  // -- mari activities -------------------------------------------------------
  const appNames = Object.keys(activities.apps);
  if (appNames.length) {
    agent.Tool('launch_app', 'launch a desktop application by name', {
      app: { type: 'string', enum: appNames, description: `one of: ${appNames.join(', ')}` },
    }, ['app'], async (ctx, { app }) => {
      const line = activities.apps[app];
      if (!line) return `unknown app: ${app}`;
      return shellTool(line, 5000);
    });
  }

  const cmdIds = Object.keys(activities.commands);
  if (cmdIds.length) {
    const listing = cmdIds.map((id) => `${id}: ${activities.commands[id]}`).join('\n');
    agent.Tool('run_activity_command',
      'run one of my predefined activity commands (home automation, work laptop, sessions). ' +
      'Available commands (id: shell):\n' + listing, {
      id: { type: 'string', enum: cmdIds, description: 'the command id to run' },
    }, ['id'], async (ctx, { id }) => {
      const line = activities.commands[id];
      if (!line) return `unknown command: ${id}`;
      return shellTool(line);
    });
  }
}

// ---------------------------------------------------------------------------
// Turn engine

const SYSTEM_PROMPT =
  'You are Ada, a spoken-voice desktop assistant. Your replies are read ' +
  'aloud by a text-to-speech engine, so: be conversational and concise ' +
  '(usually one or two short sentences), never use markdown, bullet ' +
  'points, emoji, or headings, and spell things the way they should be ' +
  'spoken. You hear the user through an always-on microphone; transcripts ' +
  'may contain small transcription errors — infer the intent.\n' +
  'You can control the home with tools. There are two independently ' +
  'controllable lights: the desk lamp (desk_light) and the PC tower LED ' +
  'strip (pc_light_color). When the user says "lights" (plural) or does ' +
  'not name a specific light, apply the request to BOTH lights. Call each ' +
  'necessary tool at most once. You can also launch desktop apps ' +
  '(launch_app) and run predefined activity commands (run_activity_command).\n' +
  'If the user is just talking, just talk back — do not use tools.';

const history = [];
let currentTurn = null;
let turnCounter = 0;

function renderPrompt(text) {
  const recent = history.slice(-CFG.historyMax);
  const ctx = recent.map((h) => `${h.who}: ${h.text}`).join('\n');
  return (ctx ? `(recent conversation for context:\n${ctx})\n\n` : '') + text;
}

async function runTurn(utt, gate) {
  // barge-in: a new passing utterance cancels whatever is pending/speaking
  if (currentTurn) currentTurn.cancelled = true;
  speaker.clear();

  const turn = {
    id: ++turnCounter,
    cancelled: false,
    reply: '',
    lat: {
      eou: utt.t_end ? utt.t_end * 1000 : null, // unix ms, perception clock
      utteranceArrived: Date.now(),
      start: performance.now(),
      firstToken: null,
      firstSentence: null,
      lastAudioDone: null,
    },
  };
  currentTurn = turn;

  if (gate !== 'ptt') sfx('activate');
  setState({ active: true, thinking: true });
  log(`turn ${turn.id} [${gate}]: ${utt.text}`);

  const splitter = new SentenceSplitter((sentence) => {
    if (turn.cancelled) return;
    if (turn.lat.firstSentence === null) turn.lat.firstSentence = performance.now();
    speaker.enqueue(sentence, turn);
  });

  try {
    // fresh agent per turn so a cancelled turn's late tokens stream into its
    // own dead splitter, never the new turn's
    const agent = await Agent.factory({
      model: CFG.model,
      parallel_tools: true,
      stream: true,
      system_prompt: SYSTEM_PROMPT,
      on_delta: (d) => {
        if (turn.cancelled) return;
        if (turn.lat.firstToken === null) turn.lat.firstToken = performance.now();
        turn.reply += d;
        splitter.push(d);
      },
    });
    registerTools(agent);
    await agent.run({ prompt: renderPrompt(utt.text) });
  } catch (e) {
    log(`turn ${turn.id} error: ${e.message}`);
    if (!turn.cancelled) speaker.enqueue('Sorry, something went wrong.', turn);
  }
  splitter.flush();

  if (!turn.cancelled) {
    history.push({ who: 'user', text: utt.text });
    if (turn.reply.trim()) history.push({ who: 'ada', text: turn.reply.trim() });
    while (history.length > CFG.historyMax * 2) history.shift();
  }

  if (currentTurn === turn) {
    currentTurn = null;
    setState({ thinking: false });
    convWindowUntil = Date.now() + CFG.convWindowMs;
    setTimeout(maybeIdle, CFG.convWindowMs + 50);
  }

  // latency report (plan §7)
  const l = turn.lat;
  const ms = (v) => (v === null ? ' n/a' : `${Math.round(v - l.start)}ms`);
  const eouToArrive = l.eou ? `${Math.round(l.utteranceArrived - l.eou)}ms` : 'n/a';
  log(`turn ${turn.id} latency: eou→utterance=${eouToArrive} ` +
    `utterance→first_token=${ms(l.firstToken)} first_sentence=${ms(l.firstSentence)} ` +
    `speech_done=${ms(l.lastAudioDone)}${turn.cancelled ? ' (cancelled)' : ''}`);
}

function cancelAll(reason) {
  if (currentTurn) {
    log(`cancel (${reason}): turn ${currentTurn.id}`);
    currentTurn.cancelled = true;
    currentTurn = null;
  }
  speaker.clear();
  sfx('click-off');
  convWindowUntil = 0;
  setState({ thinking: false, active: pttDown });
}

// ---------------------------------------------------------------------------
// perception-voice words stream (framed JSON: 4-byte BE length + payload)

function frameJson(obj) {
  const payload = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length);
  return Buffer.concat([header, payload]);
}

function onWordsEvent(msg) {
  if (msg.ev === 'partial') {
    // pre-activation feedback: light the orb up as soon as the wake word (or
    // a held PTT) is heard, before the utterance even finalizes
    if (!state.active && (pttDown || CFG.wake.test(msg.text || ''))) {
      setState({ active: true });
    }
    return;
  }
  if (msg.ev === 'utterance') {
    const gate = activationGate(msg);
    if (!gate) {
      log(`(unaddressed) ${msg.text}`);
      maybeIdle();
      return;
    }
    runTurn(msg, gate); // async; not awaited — barge-in handles overlap
  }
}

function connectWords(isRetry = false) {
  let acc = Buffer.alloc(0);
  let subscribed = false;
  const sock = net.connect(CFG.perceptionSock, () => {
    sock.write(frameJson({ command: 'subscribe', channel: 'words' }));
  });
  sock.on('data', (d) => {
    acc = Buffer.concat([acc, d]);
    while (acc.length >= 4) {
      const len = acc.readUInt32BE(0);
      if (acc.length < 4 + len) break;
      const payload = acc.subarray(4, 4 + len);
      acc = acc.subarray(4 + len);
      let msg;
      try { msg = JSON.parse(payload.toString('utf8')); } catch { continue; }
      if (!subscribed) {
        if (msg.status === 'ok') {
          subscribed = true;
          setState({ listening: true });
          log('subscribed to perception-voice words stream');
        } else {
          log(`words subscribe rejected: ${JSON.stringify(msg)}`);
          sock.end();
        }
      } else {
        onWordsEvent(msg);
      }
    }
  });
  sock.on('error', (e) => {
    if (!isRetry && !subscribed) {
      console.error(`error: perception-voice is not reachable (unix://${CFG.perceptionSock})`);
      console.error('       start it: systemctl --user start perception-voice');
      process.exit(1);
    }
  });
  sock.on('close', () => {
    setState({ listening: false });
    log('words stream lost; reconnecting…');
    setTimeout(() => connectWords(true), 1000);
  });
}

// ---------------------------------------------------------------------------
// startup

async function main() {
  acquireInstanceLock();
  Agent.default.concurrency = 4; // let a barge-in turn start while a cancelled one drains

  // fail fast if presence-voice isn't up (plan §9.3); systemd retries us.
  // Connect-only probe: the daemon closes wordlessly on bad requests, so
  // reachability (connect succeeds) is the only safe health signal.
  try {
    await new Promise((resolve, reject) => {
      const sock = net.connect(CFG.presenceSock, () => { sock.end(); resolve(); });
      sock.on('error', reject);
    });
  } catch (e) {
    console.error(`error: presence-voice daemon is not reachable (unix://${CFG.presenceSock})`);
    console.error('       start it: systemctl --user start voice');
    process.exit(1);
  }

  startAvatarServer();
  connectWords();
  log(`ada-brain ready (voice=${CFG.voice} model=${CFG.model} wake=${CFG.wake})`);

  // ADA_SELFTEST="<text>": run one synthetic utterance through the full
  // turn pipeline (gate → agent → splitter → speaker → latency report)
  // as if perception-voice had just finalized it. Dev tool; no mic needed.
  if (process.env.ADA_SELFTEST) {
    const now = Date.now() / 1000;
    setTimeout(() => onWordsEvent({
      ev: 'utterance',
      ts: now,
      text: process.env.ADA_SELFTEST,
      t_start: now - 2,
      t_end: now,
    }), 1500);
  }
}

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    try { if (existsSync(CFG.brainSock)) unlinkSync(CFG.brainSock); } catch {}
    releaseInstanceLock();
    process.exit(0);
  });
}
process.on('exit', releaseInstanceLock);

await main();
