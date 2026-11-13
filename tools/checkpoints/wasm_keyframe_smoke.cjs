#!/usr/bin/env node
// Coworld Checkpoints (spec 0157): proves the wasm32 replay viewer decodes a
// replay's EMBEDDED keyframes (the CTFKEYF1 trailer, portable_flatty framed)
// and seeks with them on the first frame, before any precompute walk.
//
//   node tools/checkpoints/wasm_keyframe_smoke.cjs <dist-dir> <keyframed-replay> [seek-tick]
//
// Fails unless: the replay loads, ctf_embedded_keyframes() > 0, one ctf_frame
// after ctf_seek(T) lands exactly on T with no hash mismatch, and playback
// from there runs to the end with no hash mismatch. Run it on a replay
// without a trailer to see ctf_embedded_keyframes() == 0 (the fallback).

'use strict';
const fs = require('fs');
const path = require('path');

const distDir = path.resolve(process.argv[2] || 'static-replay-viewer');
const replayPath = process.argv[3];
const seekTarget = parseInt(process.argv[4] || '1100', 10);
if (!replayPath) {
  console.error('usage: wasm_keyframe_smoke.cjs <dist-dir> <replay> [seek-tick]');
  process.exit(2);
}
const watchdog = setTimeout(() => {
  console.error('FAIL: did not finish within 300s');
  process.exit(1);
}, 300000);

const Module = {
  locateFile: (p) => path.join(distDir, p),
  onRuntimeInitialized: run,
  onAbort: (what) => {
    console.error('FAIL: wasm runtime aborted: ' + what);
    process.exit(1);
  },
};

function errorText() {
  const length = Module._ctf_error_len();
  if (!length) return '(no error text)';
  const pointer = Module._ctf_error_ptr();
  return Buffer.from(Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
}

function run() {
  for (const name of ['_ctf_embedded_keyframes', '_ctf_seek', '_ctf_play', '_ctf_tick']) {
    if (typeof Module[name] !== 'function') {
      console.error('FAIL: bundle predates the checkpoint exports (' + name + ' missing); rebuild it');
      process.exit(1);
    }
  }
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._ctf_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (loaded !== 1) {
    console.error('FAIL: ctf_load_replay rejected the replay\n' + errorText());
    process.exit(1);
  }
  const keyframes = Module._ctf_embedded_keyframes();
  console.log('embedded keyframes decoded by wasm32: ' + keyframes);
  if (keyframes <= 0) {
    console.error('FAIL: no embedded keyframes (no trailer, or the wasm32 decode rejected it)');
    process.exit(1);
  }
  const started = Date.now();
  Module._ctf_seek(seekTarget);
  if (Module._ctf_frame() !== 1) {
    console.error('FAIL: seek frame died\n' + errorText());
    process.exit(1);
  }
  const landed = Module._ctf_tick();
  console.log('first-frame seek to ' + seekTarget + ' landed on tick ' + landed +
    ' in ' + (Date.now() - started) + ' ms; mismatch tick ' + Module._ctf_mismatch_tick());
  if (landed !== seekTarget || Module._ctf_mismatch_tick() !== -1) {
    console.error('FAIL: seek did not land exactly, or the restored sim diverged');
    process.exit(1);
  }
  Module._ctf_play();
  let frames = 0;
  let previous = landed;
  let stalled = 0;
  let wrapped = false;
  while (Module._ctf_frame() === 1 && frames < 200000) {
    frames++;
    const now = Module._ctf_tick();
    if (now < previous) { // the viewer loops back to the start after the end hold
      wrapped = true;
      break;
    }
    if (now === previous) {
      if (++stalled > 600) break; // paused at the end hold
    } else {
      stalled = 0;
      previous = now;
    }
  }
  if (Module._ctf_error_len()) {
    console.error('FAIL: playback died after the seek\n' + errorText());
    process.exit(1);
  }
  if (Module._ctf_mismatch_tick() !== -1) {
    console.error('FAIL: hash mismatch at tick ' + Module._ctf_mismatch_tick() + ' after the seek');
    process.exit(1);
  }
  const finalTick = wrapped ? previous : Module._ctf_tick();
  if (finalTick <= landed) {
    console.error('FAIL: playback did not advance past the seek (tick ' + finalTick + ')');
    process.exit(1);
  }
  clearTimeout(watchdog);
  console.log('ok: played ' + frames + ' frames from tick ' + landed + ' to tick ' + finalTick +
    ' with no hash mismatch' + (wrapped ? ' (reached the end; the viewer then loops)' : ''));
  process.exit(0);
}

const bundlePath = path.join(distDir, 'ctf_replay.js');
new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(bundlePath, 'utf8'))(Module, require, bundlePath, distDir);
