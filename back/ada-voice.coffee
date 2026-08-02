#!/usr/bin/env bun
# ada-voice — `ada voice [text]`: make Ada say something.
#
# Preferred path: send {ev:'say', text} to the RUNNING ada-back over its
# avatar socket — the text then flows through the normal speech pipeline
# (sentence splitter → presence-voice with Ada's configured preset) AND the
# avatar renders per-sentence closed captions.
#
# TTS-only: does NOT arm Ada's post-speech conversation window (no follow-up
# STT without a wake word / PTT). That window is only for real dialogue turns.
#
# Fallback (back not running): speak directly to presence-voice using the
# `voice:` preset from config.yaml — no captions, but still Ada's voice.
#
# Text comes from argv (joined) or stdin when no argument is given.
import net from 'node:net'
import yaml from 'js-yaml'
import { readFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

ROOT = process.env.ADA_ROOT or dirname(dirname(fileURLToPath(import.meta.url)))
BACK_SOCK = process.env.ADA_BACK_SOCK or
  "#{process.env.XDG_RUNTIME_DIR or '/tmp'}/ada-back.sock"
PRESENCE_SOCK = process.env.ADA_PRESENCE_SOCK or '/tmp/presence-voice.sock'

readStdin = ->
  new Promise (resolve, reject) ->
    chunks = []
    process.stdin.on 'data', (c) -> chunks.push c
    process.stdin.on 'end', -> resolve Buffer.concat(chunks).toString('utf8')
    process.stdin.on 'error', reject

# Say via the running back (captions + configured voice). Resolves true on
# success, false if the back socket is unreachable.
sayViaBack = (text) ->
  new Promise (resolve) ->
    sock = net.connect BACK_SOCK, ->
      sock.write JSON.stringify({ ev: 'say', text }) + '\n'
      # the back replies with a state line on connect; a short grace period
      # lets the write flush before we exit
      setTimeout (-> sock.end(); resolve true), 150
    sock.on 'error', -> resolve false

# Fallback: presence-voice line protocol (preset \t speaker \t effects \t schedule \t text).
sayDirect = (text) ->
  preset = 'ada'
  try
    cfg = yaml.load(readFileSync(join(ROOT, 'config.yaml'), 'utf-8')) or {}
    preset = process.env.ADA_VOICE or cfg.voice or preset
  new Promise (resolve, reject) ->
    buf = ''
    sock = net.connect PRESENCE_SOCK, ->
      clean = text.replace(/[\t\n]+/g, ' ').trim()
      sock.write "#{preset}\t\t\tinterrupt\t#{clean}\n"
    sock.on 'data', (d) ->
      buf += d.toString()
      if buf.includes '\n'
        sock.end()
        if buf.startsWith 'OK' then resolve() else reject(new Error(buf.trim()))
    sock.on 'error', (e) -> reject(e)

text = process.argv.slice(2).join(' ').trim()
text = (await readStdin()).trim() unless text
unless text
  console.error 'usage: ada voice <text>   (or pipe text on stdin)'
  process.exit 1

if await sayViaBack(text)
  process.exit 0
console.error 'ada-back not running — speaking directly via presence-voice (no captions)'
try
  await sayDirect(text)
  process.exit 0
catch e
  console.error "voice failed: #{e.message}"
  process.exit 1
