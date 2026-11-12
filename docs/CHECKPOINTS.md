# Coworld Checkpoints in Paintbot (Metta spec 0157, Stage 2)

Status: partial. Embedded replay keyframes and the game-side snapshot primitives
are implemented and tested. Live restore, the player checkpoint message, and a
Docker end-to-end run are not finished yet (see "Not done yet").

## Embedded replay keyframes

A `.bitreplay` can carry its own seek keyframes, so the replay viewer
(`ctf_replay.wasm` or the native replay server) can seek to any tick on the
first frame. It restores the newest keyframe at or before the target tick and
steps at most `interval - 1` ticks. Without embedded keyframes it has to wait
for the background `initReplayScan` walk.

- **Layout.** The keyframes are a trailer after the unchanged record stream:
  `<replay records><block: N bytes><u64 LE N>"CTFKEYF1"`. Format 1 is parsed
  by bitworld's codec and format 2 must end with its manifest, so neither can
  take a new record type. The trailer leaves the record stream, its hash chain
  and its manifest chains byte-for-byte unchanged.
  `replay_codec.splitKeyframeTrailer` strips it before parsing.
- **Block.** `zlib(portable_flatty(EmbeddedKeyframeSet))`. Each keyframe is a
  normal `ReplayKeyframe` (the sim without its static map bakes, plus the
  replay cursors) with `portable = true`.
- **Why `portable_flatty`.** Plain flatty writes `int` at pointer width and
  memcpys object arrays, so bytes from the 64-bit server would not decode in
  the 32-bit wasm viewer. `src/ctf/portable_flatty.nim` does the same field
  walk with 64-bit ints and memcpys only fixed-width scalars.
- **Producing them.** `embedReplayKeyframes(bytes, interval)` re-walks the
  finished match from tick 0, so every keyframe matches the viewer's own
  walk exactly (same `gameHash`). The live server embeds them on close when
  `CTF_REPLAY_KEYFRAME_TICKS=<K>` is set. This is off by default because
  readers older than this change reject a replay that has a trailer. The
  default interval is 200 (`DefaultEmbeddedKeyframeTicks`), below
  `SeekTicksPerFrame`. On the `capture-seed1` fixture (6,662 ticks) that is
  35 keyframes, and the file grows from 118 KB to 927 KB.
- **Reading them.** `initReplayPlayer(CtfReplayData)` loads the keyframes and
  sets `embeddedKeyframes`. The scan keeps them and only derives the chrome
  series (momentum, beats, lulls). A block from another GameVersion or
  sim-sources stamp, or a corrupt block, is logged and ignored. The viewer
  then falls back to the scan.

## Game snapshot (`src/ctf/checkpoint.nim`)

- `captureGameSnapshot(player, sim, replayRecords)` and
  `encodeGameSnapshot` / `decodeGameSnapshot` handle `game.snapshot`
  (portable framing, zlib). Connection tokens are blanked before encoding;
  `restoreGameSnapshot` takes them from the restoring process's own config.
- `reseedSim(sim, seed)` reseeds `sim.rng` for `COGAME_RESEED`. Map
  geometry is already generated and does not change.
- `parseCheckpointTicks` reads `COGAME_CHECKPOINT_TICKS` (`300,600` or
  `interval:K`).
- `writeCheckpointDir` writes `tick_{T:06d}/game.snapshot`, then
  `manifest.json` last, both atomically.

Server wiring in `runServerLoop`:

| Variable | Behavior |
| --- | --- |
| `COGAME_SNAPSHOT_DIR` + `COGAME_CHECKPOINT_TICKS` | After tick `T` is stepped, hashed and its inputs recorded, the server writes the snapshot directory before anything observes `T`. The snapshot includes the replay record stream so far. |
| `COGAME_LOAD_SNAPSHOT_URI` | At boot the server replaces the fresh sim with the snapshot, keeping the fresh sim's bakes and tokens. |
| `COGAME_RESEED` | Used with `COGAME_LOAD_SNAPSHOT_URI`: reseeds the RNG before tick `T + 1`. |
| `CTF_REPLAY_KEYFRAME_TICKS` | Embeds replay keyframes when the replay closes. |

## Verified

`tests/test_coworld_checkpoints.nim` (shard 3):

1. The trailer round-trips and leaves the record stream unchanged. Legacy and
   corrupt-trailer replays fall back to the scan.
2. One `advanceReplayFrame` seek to tick 1234 lands there, with the scan not
   yet complete, and matches a tick-0 walk's `gameHash`. Playback from there
   then matches every recorded hash to the end.
3. A snapshot at tick 900, restored into a fresh sim and player, reproduces
   every `gameHash` to the end of the match. Reseeding with 7 diverges from
   the recorded match, two runs with seed 7 are identical, and seed 8
   differs.
4. Checkpoint-tick parsing and the snapshot directory layout.

## Not done yet

- **Live resume.** After a load, seats must rebind to their existing cogs
  instead of joining as new players. The resumed writer must also continue
  from `snapshot.replayRecords` (the format-2 manifest chains need the prefix
  re-fed) so the match yields one valid `.bitreplay`. Neither is verified
  end-to-end.
- **Player checkpoint message.** The pause that sends
  `{"type":"checkpoint","tick":T,"deadline_ms":2000}` and waits up to 2 s
  for `checkpoint_ack` is not wired. Play seats use the binary play-seat
  protocol, so the message needs a protocol addition.
- **Player state.** `COWORLD_PLAYER_STATE_IN` / `_OUT` are not implemented
  in `players/baseline` (s2play) or the starters.
- **Docker end-to-end run.** Not run with the Stage 1 runner
  (`coworld run-episode --checkpoint-ticks` / `--from-checkpoint`).
- **Viewer bundle.** The wasm viewer has not been rebuilt
  (`tools/build_replay_viewer.sh`), and the wasm32 decode of embedded
  keyframes has not been exercised in a browser.
