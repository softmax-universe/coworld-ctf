# Coworld Checkpoints in Paintbot (Metta spec 0157, Stage 2)

Status: implemented and run end to end, locally only. A Paintbot match can
save a checkpoint mid-episode, kill and respawn every player from its saved
seat state, resume a fresh game process from the checkpoint, and embed seek
keyframes in its replay. Everything is opt-in: with none of the variables
below set, the server behaves as before.

The contract is Metta's `GAME.md` and `PLAYER.md` "Checkpoints" sections.
This page records how Paintbot implements it.

## Game-side variables

| Variable | Behavior |
| --- | --- |
| `COGAME_SNAPSHOT_DIR` + `COGAME_CHECKPOINT_TICKS` | At each checkpoint tick `T`, after `T` is stepped, hashed and its inputs recorded and before anything observes it: prompt every player seat, wait up to 2 s for acks, write `tick_{T:06d}/game.snapshot`, then `manifest.json` last. |
| `COGAME_CHECKPOINT_RESTART=1` | After the snapshot, hold tick `T` until every prompted seat has reconnected (input seats must also have sent input), for at most 30 s. |
| `COGAME_LOAD_SNAPSHOT_URI` | Boot at the snapshot's tick instead of tick 0, then hold for at most 90 s until every restored seat has connected. |
| `COGAME_RESEED` | With a load, reseed `sim.rng` before tick `T + 1`. Map geometry does not change. |
| `COGAME_GAME_PATCH_URI` | Not supported, because the snapshot is binary. It is logged and ignored. |
| `CTF_REPLAY_KEYFRAME_TICKS=K` | Embed seek keyframes every `K` ticks when the replay closes. |

### The checkpoint handshake

The play-seat protocol and the Sprite protocol are both binary, so the
handshake uses WebSocket **text** frames, which every existing client
already ignores. `s2play.nim` discarded `TextMessage`, the Python starters
skip `str` messages, and the server dropped any text it received.

- Server to player: `{"type": "checkpoint", "tick": T, "deadline_ms": 2000}`
- Player to server: `{"type": "checkpoint_ack", "tick": T}`

The manifest records `prompted_slots`, `acked_slots` and `play_seats_saved`.
The server does not wait past 2 s for a seat that has not acked.

### What `game.snapshot` holds

`game.snapshot` is `zlib(portable_flatty(GameSnapshot))`, version 2
(`src/ctf/checkpoint.nim`). It holds:

- The sim, as a portable `ReplayKeyframe` with the static map bakes removed
  and the slot tokens blanked.
- The replay record stream so far (`replayRecords`). It also holds the
  replay writer's input dedupe state (`replayLastMasks`, `replayLastDirectAim`)
  and the inputs applied at tick `T` (`prevInputMasks`), which tick `T + 1`
  reads to detect button presses.
- The game-side shell state of each play seat (`shellSeats`, described below).

### Live resume (`COGAME_LOAD_SNAPSHOT_URI`)

1. **Config from the snapshot.** The server rebuilds the donor sim from the
   snapshot's own `GameConfig` (seed and map), using this process's fresh
   tokens. This matters because boot randomizes a seed that the config does
   not pin, and the map is installed process-wide from the config. Before this
   fix, a restore onto a freshly seeded sim took the bakes from the wrong map
   and diverged on the first resumed tick.
2. **Seat rebinding.** Every restored cog keeps its row. A socket that
   reconnects for slot `S` rebinds to the cog whose `joinOrder` is `S`, so
   there is no join record and no new player. Play seats rebind through the
   shell's ingress binding, and input seats through `resumeSeatPlayerIndices`.
3. **One replay.** The writer reopens with the checkpoint's record prefix
   (`resumeReplayWriter`). For format 2 it re-feeds the call, annotation and
   transcript manifest chains from the prefix, so the final manifest covers
   the whole match. Format 1 continues through a raw writer that emits the
   same record bytes as bitworld. A test checks that a resumed file is
   byte-identical to an uninterrupted writer fed the same records.
4. **Play-seat shell state is serialized** rather than re-uploaded on
   reconnect, because the upload window closes when play starts and a player
   cannot upload into a restored game. For each play seat, the snapshot
   carries the admitted module bytes (by upload id), the ingress id floors and
   budgets, and the standing ladder call. At boot, before tick `T + 1`, the
   server re-admits the modules, compiles them synchronously, and re-accepts
   the call under its original call number (`restorePlaySeat`,
   `primeCallNumber`, `restoreUploadHistory`). The cog keeps running its plays
   even if its player never reconnects. Three things are not carried:
   - Play-instance guest memory. Each standing entry restarts from a fresh
     instance.
   - The lobby transcript buffer. Lobby chat has ended by then.
   - Status ordinals. Statuses restart at 1 on the new connection.

During a restart hold, a player socket that drops keeps its cog, with no leave
record and no abandonment charge.

## Player side

`COWORLD_PLAYER_STATE_IN` / `COWORLD_PLAYER_STATE_OUT` hold JSON, written
atomically through a temporary file and a rename.

- **`players/baseline` (s2play)**, the manifest's player, saves its upload
  and proposal id floors, whether its playbook is uploaded, and its standing
  ladder. A restored process skips the upload pass and resumes ladder
  maintenance at once. Without the state (`BASELINE_DISCARD_STATE=1`), a
  respawned baseline re-uploads under ids the server has already admitted.
  The server treats those uploads as duplicates and never answers, so the
  baseline waits out 20 s upload timeouts for the rest of a short match and
  never sends another call.
- **`policies/poc_llm_policy` `PlaySeat`**, the base class of every starter,
  acks the handshake and saves and restores its id floors. Subclasses can
  extend `checkpoint_state()` and `restore_checkpoint_state()`. After a
  restore, the starters still re-upload their playbook and replay their
  opening turns.
- The deprecated Sprite v1 half of the baseline does not answer the
  handshake.

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
  finished match from tick 0, so every keyframe matches the viewer's own walk
  exactly (same `gameHash`). The live server embeds them on close when
  `CTF_REPLAY_KEYFRAME_TICKS=<K>` is set; `tools/checkpoints/embed_keyframes.nim`
  does the same pass offline. Embedding is off by default because readers
  older than this change reject a replay that has a trailer. The default
  interval is 200 (`DefaultEmbeddedKeyframeTicks`), below
  `SeekTicksPerFrame`. On the `capture-seed1` fixture (6,662 ticks) that is 35
  keyframes, and the file grows from 118 KB to 927 KB.
- **Reading them.** `initReplayPlayer(CtfReplayData)` loads the keyframes and
  sets `embeddedKeyframes`. The scan keeps them and only derives the chrome
  series (momentum, beats, lulls). A block from another GameVersion or
  sim-sources stamp, or a corrupt block, is logged and ignored, and the viewer
  falls back to the scan. The wasm viewer exports `ctf_embedded_keyframes`,
  `ctf_seek` and `ctf_tick` for `tools/checkpoints/wasm_keyframe_smoke.cjs`.

## Verified

- `tests/test_coworld_checkpoints.nim` (shard 3) has 12 tests. They cover:
  - the trailer round-trip and its fallbacks
  - frame-1 seek parity
  - snapshot restore with hash parity to the end of a match
  - reseed divergence
  - tick parsing and the directory layout
  - the snapshot config and handshake parsing
  - writer continuation for format 1 and format 2 (byte-identical to an
    uninterrupted writer, with a verified manifest)
- `tools/checkpoints/local_resume_check.py` runs a native harness with four
  baseline play seats on the battle-royale-s2 rules. Episode A checkpoints at
  tick 600 with restarts: all four seats acked, the hold was released in about
  150 ms, and every baseline restored its state and skipped the re-upload.
  Episode B boots from the checkpoint. Both replays pass `tools/expand_replay`,
  which checks hash parity over the whole match, including the resumed half.
  `tools/checkpoints/snapshot_diff.nim` checks that a snapshot equals the sim
  that a replay walk reaches at the same tick.
- The rebuilt wasm32 bundle (`static-replay-viewer/`) decodes all 35
  embedded keyframes of `capture-seed1` (embedded with
  `tools/checkpoints/embed_keyframes.nim`). A first-frame seek to tick 1234,
  and one to tick 6400, each land exactly on the target and play to the end
  (tick 6663) with no hash mismatch (`wasm_keyframe_smoke.cjs`). Without a
  trailer, the smoke script reports 0 keyframes and fails as designed.
  `tools/wasm_replay_smoke.cjs` still passes on every committed fixture
  except `gen-colossal-4team`, whose OOM is already known (b2295cf0).
- A Docker run used Metta's Stage 1 runner (`coworld run-episode`, branch
  `sasmith/coworld-checkpoints`), with
  `tools/checkpoints/make_e2e_manifest.py` and a player image that includes a
  shell (`tools/checkpoints/Dockerfile.baseline-e2e`). It ran
  `--checkpoint-ticks 600` (the runner's supervisor SIGKILLs and respawns each
  player), then `--from-checkpoint`, then `--from-checkpoint --reseed 7`, all
  with `--verify-replay`.

## Running it

```bash
# Native
nim c -d:release --threads:on -d:noSignalHandler -d:shellStaticWasmtime -o:/tmp/ctf src/ctf.nim   # with WASMTIME_C_API set
nim c -d:release -o:/tmp/baseline players/baseline/baseline.nim
nim c -d:release -o:/tmp/expand tools/expand_replay.nim
policies/starters/common/build_playbook.sh /tmp/playbook
tools/checkpoints/local_resume_check.py --server /tmp/ctf --baseline /tmp/baseline \
  --expand /tmp/expand --playbook /tmp/playbook [--discard-state]

# Docker (local images only)
docker build -t coworld-ctf-game:ckpt .
docker build -f tools/checkpoints/Dockerfile.baseline-e2e -t coworld-ctf-baseline:ckpt .
tools/checkpoints/make_e2e_manifest.py "$OUT/coworld_manifest.json" \
  --game-image coworld-ctf-game:ckpt --player-image coworld-ctf-baseline:ckpt
COWORLD_AGENT_GUIDANCE=0 coworld run-episode "$OUT/coworld_manifest.json" --variant checkpoint-e2e \
  -o "$OUT/a" --checkpoint-ticks 600 --verify-replay
COWORLD_AGENT_GUIDANCE=0 coworld run-episode "$OUT/coworld_manifest.json" --variant checkpoint-e2e \
  -o "$OUT/b" --from-checkpoint "$OUT/a/checkpoints/tick_000600" --verify-replay
```

`COWORLD_AGENT_GUIDANCE=0` stops the CLI from editing AGENTS.md or CLAUDE.md
above the manifest's directory.

## Known limits

- The production baseline image has no shell, so the runner's `/bin/sh`
  restart supervisor cannot run in it, and the Docker run uses a Debian-based
  image instead. Running checkpoint enforcement against the real image needs a
  shell in `players/baseline/Dockerfile`, for example a static busybox.
- Play-instance guest memory does not survive a game restore (see above).
- `COGAME_GAME_PATCH_URI` is not supported.
