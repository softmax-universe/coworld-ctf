## Coworld Checkpoints (Metta spec 0157) for Paintbot: embedded replay
## keyframes and game checkpoint save / restore / reseed.

import
  helpers,
  std/[json, os, unittest],
  ctf/[broadcast, checkpoint, replay_codec, replay_runtime, replays, sim],
  shell/replay_records

const
  FixturePath = GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"
  SeekTarget = 1234
  KeyframeInterval = 200

proc inGameDir[T](body: proc (): T): T =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = body()
  finally:
    setCurrentDir(previousDir)

proc freshSim(configJson: string): SimServer =
  var config = defaultGameConfig()
  config.update(configJson)
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false

proc walkFromZero(data: CtfReplayData, tick: int): uint64 =
  ## Reference: a keyframe-free walk from tick 0 to `tick`.
  var stripped = data
  stripped.keyframeBlob = ""
  var sim = freshSim(stripped.replay.configJson)
  var player = initReplayPlayer(stripped)
  player.mismatchQuit = true
  while sim.tickCount < tick:
    player.stepReplay(sim)
  sim.gameHash()

suite "embedded replay keyframes":
  let
    legacyBytes = readFile(FixturePath)
    keyedBytes = inGameDir(proc (): string =
      embedReplayKeyframes(legacyBytes, KeyframeInterval))
    legacy = parseCtfReplayBytesFull(legacyBytes)
    keyed = parseCtfReplayBytesFull(keyedBytes)

  test "trailer round-trips and leaves the record stream untouched":
    check legacy.keyframeBlob.len == 0
    check keyed.keyframeBlob.len > 0
    check keyed.replay.configJson == legacy.replay.configJson
    check keyed.replay.hashes == legacy.replay.hashes
    check keyed.replay.inputs == legacy.replay.inputs
    check replayRecordBytes(keyedBytes, CtfReplaySpec) ==
      replayRecordBytes(legacyBytes, CtfReplaySpec)
    let embedded = decodeEmbeddedKeyframes(keyed.keyframeBlob)
    check embedded.interval == KeyframeInterval
    check embedded.keyframes[0].tick == 0
    check embedded.keyframes[^1].tick == int(legacy.replay.hashes[^1].tick)
    # Re-embedding replaces the trailer instead of stacking a second one.
    let again = inGameDir(proc (): string =
      embedReplayKeyframes(keyedBytes, KeyframeInterval))
    check again == keyedBytes
    echo "  replay ", legacyBytes.len, " B -> ", keyedBytes.len, " B with ",
      embedded.keyframes.len, " keyframes"

  test "legacy replays load with no embedded keyframes":
    let player = initReplayPlayer(legacy)
    check not player.embeddedKeyframes
    check player.keyframes.len == 0

  test "a corrupt trailer falls back to the precompute walk":
    var broken = keyed
    broken.keyframeBlob = "not a keyframe block"
    let player = initReplayPlayer(broken)
    check not player.embeddedKeyframes

  test "frame-1 seek past tick 1000 matches a tick-0 walk exactly":
    let maxTick = int(legacy.replay.hashes[^1].tick)
    require maxTick > SeekTarget + 100
    var runtime = inGameDir(proc (): InitializedReplay =
      initReplayRuntime(keyed, mismatchQuit = true,
        gameEventLoggingEnabled = false))
    check runtime.player.embeddedKeyframes
    # The background precompute walk has barely started, yet every keyframe
    # of the whole match is already present.
    check not runtime.player.scanComplete
    check runtime.player.keyframes.len >= maxTick div KeyframeInterval
    check runtime.player.keyframes[^1].tick == maxTick
    # ONE presentation frame: the seek restores the nearest keyframe <= T
    # and converges the < interval gap inside the same frame.
    discard runtime.player.advanceReplayFrame(
      runtime.sim, runtime.tracker, [SeekTarget], [])
    check runtime.sim.tickCount == SeekTarget
    check runtime.player.pendingSeekTick == -1
    let reference = inGameDir(proc (): uint64 =
      walkFromZero(legacy, SeekTarget))
    check runtime.sim.gameHash() == reference
    # And playback from the restored state still matches every recorded
    # hash to the end of the match (mismatchQuit raises otherwise).
    while runtime.sim.tickCount < maxTick:
      runtime.player.stepReplay(runtime.sim)
    check not runtime.player.hashValidationFailed

  test "every embedded keyframe restores to its walked gameHash":
    let embedded = decodeEmbeddedKeyframes(keyed.keyframeBlob)
    var runtime = inGameDir(proc (): InitializedReplay =
      initReplayRuntime(keyed, mismatchQuit = true,
        gameEventLoggingEnabled = false))
    for keyframe in [embedded.keyframes[1], embedded.keyframes[^2]]:
      runtime.player.seekReplay(runtime.sim, keyframe.tick)
      check runtime.sim.tickCount == keyframe.tick
      check runtime.sim.gameHash() == inGameDir(proc (): uint64 =
        walkFromZero(legacy, keyframe.tick))

suite "game checkpoints":
  let
    data = parseCtfReplayBytesFull(readFile(FixturePath))
    maxTick = int(data.replay.hashes[^1].tick)
    checkpointTick = 900

  proc runTo(player: var ReplayPlayer, sim: var SimServer, tick: int) =
    while sim.tickCount < tick:
      player.stepReplay(sim)

  test "checkpoint tick schedules parse":
    check parseCheckpointTicks("300,600, 900", 1000) == @[300, 600, 900]
    check parseCheckpointTicks("interval:250", 1000) == @[250, 500, 750]
    check parseCheckpointTicks("1200,5", 1000) == @[5]
    check parseCheckpointTicks("", 1000).len == 0

  test "restore with the same seed reproduces every gameHash to the end":
    var player = initReplayPlayer(data)
    player.mismatchQuit = true
    var sim = inGameDir(proc (): SimServer = freshSim(data.replay.configJson))
    player.runTo(sim, checkpointTick)
    let snapshotBytes = encodeGameSnapshot(
      captureGameSnapshot(player, sim))
    # A brand-new process: fresh sim (donor of the static bakes) + player.
    var restoredSim = inGameDir(proc (): SimServer =
      freshSim(data.replay.configJson))
    var restoredPlayer = initReplayPlayer(data)
    restoredPlayer.mismatchQuit = true
    let snapshot = decodeGameSnapshot(snapshotBytes)
    check snapshot.tick == checkpointTick
    restoredPlayer.restoreGameSnapshot(restoredSim, snapshot)
    check restoredSim.tickCount == checkpointTick
    check restoredSim.gameHash() == sim.gameHash()
    var
      hashesA: seq[uint64]
      hashesB: seq[uint64]
    while sim.tickCount < maxTick:
      player.stepReplay(sim)
      restoredPlayer.stepReplay(restoredSim)
      hashesA.add(sim.gameHash())
      hashesB.add(restoredSim.gameHash())
    check hashesA == hashesB
    check not restoredPlayer.hashValidationFailed

  test "COGAME_RESEED diverges deterministically from the checkpoint":
    var player = initReplayPlayer(data)
    var sim = inGameDir(proc (): SimServer = freshSim(data.replay.configJson))
    player.runTo(sim, checkpointTick)
    let snapshotBytes = encodeGameSnapshot(
      captureGameSnapshot(player, sim))

    proc rollout(seed: int): seq[uint64] =
      var rsim = inGameDir(proc (): SimServer =
        freshSim(data.replay.configJson))
      var rplayer = initReplayPlayer(data)
      rplayer.mismatchQuit = false
      rplayer.restoreGameSnapshot(rsim, decodeGameSnapshot(snapshotBytes))
      if seed >= 0:
        rsim.reseedSim(seed)
      # The recorded inputs keep driving every seat; only chance changes.
      # The recorded hashes stop applying once chance changes, so the
      # counterfactual runs unchecked (hashes cleared) to the recorded end.
      rplayer.data.hashes = @[]
      while rsim.tickCount < maxTick:
        rplayer.stepReplay(rsim)
        result.add(rsim.gameHash())

    let
      same = rollout(-1)
      seeded7a = rollout(7)
      seeded7b = rollout(7)
      seeded8 = rollout(8)
    check seeded7a == seeded7b          # deterministic by seed
    check seeded7a != same              # diverges from the recorded match
    check seeded7a != seeded8           # and differs between seeds
    check seeded7a.len > 0
    echo "  reseed rollouts: ", seeded7a.len, " ticks each from tick ",
      checkpointTick

  test "snapshot directory layout: game.snapshot then manifest.json":
    var player = initReplayPlayer(data)
    var sim = inGameDir(proc (): SimServer = freshSim(data.replay.configJson))
    player.runTo(sim, 300)
    let dir = getTempDir() / ("ctf-ckpt-test-" & $getCurrentProcessId())
    removeDir(dir)
    let snap = captureGameSnapshot(player, sim)
    let tickDir = writeCheckpointDir(dir, snap, %*{"seed": sim.config.seed})
    check tickDir == dir / "tick_000300"
    check fileExists(tickDir / "game.snapshot")
    let manifest = parseJson(readFile(tickDir / "manifest.json"))
    check manifest["tick"].getInt == 300
    check manifest["game_version"].getStr == GameVersion
    check decodeGameSnapshot(readFile(tickDir / "game.snapshot")).tick == 300
    removeDir(dir)

  test "snapshot config carries the episode seed and map, never tokens":
    var player = initReplayPlayer(data)
    var sim = inGameDir(proc (): SimServer = freshSim(data.replay.configJson))
    player.runTo(sim, 300)
    let snap = decodeGameSnapshot(encodeGameSnapshot(
      captureGameSnapshot(player, sim)))
    let config = snap.snapshotConfig()
    check config.seed == sim.config.seed
    check config.mapPath == sim.config.mapPath
    for slot in config.slots:
      check slot.token.len == 0
    check checkpointAckTick("""{"type":"checkpoint_ack","tick":300}""") == 300
    check checkpointAckTick("""{"type":"other","tick":300}""") == -1
    check checkpointAckTick("not json") == -1
    check parseJson(checkpointMessage(300)) ==
      %*{"type": "checkpoint", "tick": 300, "deadline_ms": 2000}

suite "replay writer continuation (live resume)":
  ## A resumed server reopens its replay from the checkpoint's record prefix
  ## and keeps writing. The resumed file must be byte-identical to the file an
  ## uninterrupted writer produces from the same record sequence, so the
  ## match has ONE replay whose hash chain and (format 2) manifest chains
  ## span the restart.

  proc firstHalf(writer: var CtfReplayWriter, shell: bool) =
    writer.writeJoin(0, 0, "Player1", 0, "")
    writer.writeJoin(0, 1, "Player2", 1, "")
    writer.lastMasks = @[0'u8, 0'u8]
    for tick in 1 .. 5:
      writer.writeInputMaskChange(tickTime(tick - 1), tick mod 2,
        uint8(tick))
      writer.writeHash(uint32(tick), uint64(tick) * 7919'u64)
    if shell:
      writer.writeLobbyChat(LobbyChatRecord(replayTimeMs: tickTime(5),
        ordinal: 1, seat: 0, team: 0, text: "gl"))
      writer.writeHash(6, 6'u64 * 7919'u64)

  proc secondHalf(writer: var CtfReplayWriter, shell: bool) =
    for tick in 7 .. 12:
      writer.writeInputMaskChange(tickTime(tick - 1), tick mod 2,
        uint8(tick mod 3))
      writer.writeHash(uint32(tick), uint64(tick) * 7919'u64)
    if shell:
      writer.writeLobbyChat(LobbyChatRecord(replayTimeMs: tickTime(12),
        ordinal: 2, seat: 1, team: 1, text: "gg"))

  proc roundTrip(shell: bool) =
    let
      base = getTempDir() / ("ctf-resume-" & $getCurrentProcessId() &
        (if shell: "-f2" else: "-f1"))
      straight = base & "-straight.bitreplay"
      resumed = base & "-resumed.bitreplay"
      configJson = if shell: """{"slots":[{"control":"play"},{"control":"play"}]}"""
                   else: "{}"
    var a = openReplayWriter(straight, configJson, CtfReplaySpec,
      shellEpisode = shell, shellSeatCount = (if shell: 2 else: 0),
      openedAtMs = 1'u64)
    a.firstHalf(shell)
    a.flushReplayWriter()
    let prefix = readFile(straight)
    let masks = a.lastMasks
    a.secondHalf(shell)
    a.closeReplayWriter()
    var b = resumeReplayWriter(resumed, prefix, CtfReplaySpec,
      ReplayCompatibleGameVersions, masks)
    check b.enabled
    check b.shellEpisode == shell
    check b.lastMasks == masks
    b.secondHalf(shell)
    b.closeReplayWriter()
    check readFile(resumed) == readFile(straight)
    let parsed = parseCtfReplayBytesFull(readFile(resumed))
    check parsed.replay.hashes.len == (if shell: 12 else: 11)
    if shell:
      check parsed.shell.manifestVerified
      check parsed.shell.lobbyTranscript.len == 2
    removeFile(straight)
    removeFile(resumed)

  test "format 1 (bitworld records) continues byte-identically":
    roundTrip(shell = false)

  test "format 2 continues byte-identically with a verified manifest":
    roundTrip(shell = true)
