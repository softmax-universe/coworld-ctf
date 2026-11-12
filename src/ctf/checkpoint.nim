## Coworld Checkpoints (Metta spec 0157) for Paintbot: the game-side world
## snapshot (`game.snapshot`) and its save / restore / reseed helpers.
##
## A snapshot is one portable ReplayKeyframe (the SimServer minus its static
## map bakes, plus the replay cursors when a ReplayPlayer drives the sim),
## the tick, and provenance. Connection tokens are blanked before encoding
## (GAME.md: "never store tokens in the snapshot"); a restoring server takes
## them from its fresh COGAME_CONFIG_URI. On the wire:
## zlib(toPortableFlatty(GameSnapshot)), the same pointer-width-portable
## framing as the embedded replay keyframes, so a snapshot cut by a native
## server also restores in the wasm viewer.

import
  std/[algorithm, json, os, random, strutils],
  zippy,
  build_stamp, portable_flatty, replays, sim

type
  GameSnapshot* = object
    version*: int
    tick*: int
    seed*: int
    gameVersion*: string
    simStamp*: string
    keyframe*: ReplayKeyframe
    replayRecords*: string
      ## The live server's replay record stream up to `tick` (uncompressed,
      ## no keyframe trailer), so a resumed match writes ONE continuous
      ## `.bitreplay`. Empty when the snapshot was cut outside a recording
      ## server (tests, offline tools).

const
  GameSnapshotVersion* = 1
  GameSnapshotFile* = "game.snapshot"
  CheckpointManifestFile* = "manifest.json"
  CogameLoadSnapshotUriEnv* = "COGAME_LOAD_SNAPSHOT_URI"
  CogameReseedEnv* = "COGAME_RESEED"
  CogameSnapshotDirEnv* = "COGAME_SNAPSHOT_DIR"
  CogameCheckpointTicksEnv* = "COGAME_CHECKPOINT_TICKS"
  CogameCheckpointRestartEnv* = "COGAME_CHECKPOINT_RESTART"
  CheckpointDeadlineMs* = 2000

proc parseCheckpointTicks*(spec: string, maxTicks: int): seq[int] =
  ## `COGAME_CHECKPOINT_TICKS`: a comma-separated tick list (`300,600`) or
  ## `interval:K`. Ticks <= 0 or at/beyond `maxTicks` (when positive) are
  ## dropped; the result is ascending and unique.
  let text = spec.strip()
  if text.len == 0:
    return
  var ticks: seq[int]
  if text.startsWith("interval:"):
    let interval = parseInt(text["interval:".len .. ^1].strip())
    if interval <= 0:
      raise newException(ValueError,
        CogameCheckpointTicksEnv & " interval must be positive")
    if maxTicks <= 0:
      raise newException(ValueError,
        CogameCheckpointTicksEnv & " interval needs a finite maxTicks")
    var tick = interval
    while tick < maxTicks:
      ticks.add(tick)
      tick += interval
  else:
    for part in text.split(','):
      let item = part.strip()
      if item.len > 0:
        ticks.add(parseInt(item))
  for tick in ticks:
    if tick > 0 and (maxTicks <= 0 or tick < maxTicks) and tick notin result:
      result.add(tick)
  result.sort()

proc withoutTokens(sim: var SimServer): seq[string] =
  ## Blanks every configured slot token, returning them for `restoreTokens`.
  for slot in sim.config.slots.mitems:
    result.add(slot.token)
    slot.token = ""

proc restoreTokens(sim: var SimServer, tokens: seq[string]) =
  for i in 0 ..< min(tokens.len, sim.config.slots.len):
    sim.config.slots[i].token = tokens[i]

proc captureGameSnapshot*(
  player: ReplayPlayer,
  sim: var SimServer,
  replayRecords = ""
): GameSnapshot =
  ## Cuts a snapshot of `sim` (and of `player`'s replay cursors; pass a
  ## default ReplayPlayer for a live server) at its current tick.
  let tokens = sim.withoutTokens()
  try:
    result = GameSnapshot(
      version: GameSnapshotVersion,
      tick: sim.tickCount,
      seed: sim.config.seed,
      gameVersion: GameVersion,
      simStamp: ctfSimSourcesStamp,
      keyframe: player.saveReplayKeyframe(sim, portable = true),
      replayRecords: replayRecords)
  finally:
    sim.restoreTokens(tokens)

proc encodeGameSnapshot*(snapshot: GameSnapshot): string =
  compress(snapshot.toPortableFlatty(), BestSpeed, dfZlib)

proc decodeGameSnapshot*(bytes: string): GameSnapshot =
  ## Raises ValueError on a snapshot this engine cannot restore.
  result = uncompress(bytes, dfZlib).fromPortableFlatty(GameSnapshot)
  if result.version != GameSnapshotVersion:
    raise newException(ValueError,
      "unsupported game.snapshot version " & $result.version)
  if result.gameVersion != GameVersion:
    raise newException(ValueError,
      "game.snapshot was cut by GameVersion " & result.gameVersion &
        "; this engine is " & GameVersion)
  if not result.keyframe.portable:
    raise newException(ValueError, "game.snapshot keyframe is not portable")

proc restoreGameSnapshot*(
  player: var ReplayPlayer,
  sim: var SimServer,
  snapshot: GameSnapshot
) =
  ## Replaces `sim` (which donates its static map bakes and its connection
  ## tokens: build it from the restoring process's own config) with the
  ## snapshot's state, and restores `player`'s replay cursors.
  var tokens: seq[string]
  for slot in sim.config.slots:
    tokens.add(slot.token)
  player.restoreReplayKeyframe(sim, snapshot.keyframe)
  sim.restoreTokens(tokens)

proc reseedSim*(sim: var SimServer, seed: int) =
  ## COGAME_RESEED: re-seeds the simulation RNG (`sim.rng`, every chance
  ## draw from tick T+1 on). Map geometry, already generated, is unaffected.
  ## The recorded `config.seed` is left as the episode's original seed.
  sim.rng = initRand(int64(seed))

proc uriPath*(uri: string): string =
  ## file:// URI or bare path -> filesystem path.
  if uri.startsWith("file://"): uri["file://".len .. ^1] else: uri

proc writeAtomic(path, bytes: string) =
  let tmp = path & ".tmp"
  writeFile(tmp, bytes)
  moveFile(tmp, path)

proc checkpointTickDir*(dir: string, tick: int): string =
  dir / ("tick_" & align($tick, 6, '0'))

proc writeCheckpointDir*(
  dir: string,
  snapshot: GameSnapshot,
  extraManifest: JsonNode = nil
): string =
  ## Writes `dir/tick_{T:06d}/game.snapshot`, then `manifest.json` LAST (the
  ## runner's completion marker), both atomically. Returns the tick dir.
  result = checkpointTickDir(dir.uriPath, snapshot.tick)
  createDir(result)
  writeAtomic(result / GameSnapshotFile, encodeGameSnapshot(snapshot))
  var manifest = %*{
    "tick": snapshot.tick,
    "game": GameName,
    "game_version": snapshot.gameVersion,
    "sim_stamp": snapshot.simStamp,
    "seed": snapshot.seed,
    "snapshot_format": "ctf.portable_flatty.zlib.v" & $GameSnapshotVersion
  }
  if extraManifest != nil and extraManifest.kind == JObject:
    for key, value in extraManifest:
      if not manifest.hasKey(key):
        manifest[key] = value
  writeAtomic(result / CheckpointManifestFile, manifest.pretty())

proc loadGameSnapshotUri*(uri: string): GameSnapshot =
  decodeGameSnapshot(readFile(uri.uriPath))
