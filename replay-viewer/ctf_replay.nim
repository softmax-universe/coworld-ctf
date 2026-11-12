import
  std/json,
  ctf/[broadcast, build_stamp, global, replay_runtime, replays, sim],
  shell/replay_records

var
  runtimeLoaded = false
  pendingSeekTick = -1
  pendingPlay = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string
  # SEASON 2: the huddle transcript + ballot, decoded ONCE from the replay's
  # verified `.shell` metadata right after a successful load (see
  # `ctfLoadReplay` below) and re-sent on every `buildReplayViewerPacket`
  # call -- that proc itself only forwards them into the chrome on the lead
  # frame (`sendLead`), matching `achievementBadges`' "send once" contract.
  # `nil` (never assigned) on a replay whose `.shell` carries neither, so
  # the client simply never sees a "huddle"/"vote" key -- the degrade-to-
  # nothing path.
  lobbyChatJson: JsonNode
  ballotJson: JsonNode
  # SEASON 2 observability: the accepted play-call ("flash") records --
  # shell record `0x10`, RecPlayCall -- serialized ONCE at load into a
  # stable string the page reads through ctf_calls_ptr/len (same contract
  # as ctf_error_*: pointer into this module's linear memory, valid until
  # the next ctf_load_replay). Unlike huddle/vote this does NOT ride the
  # per-frame chrome (`buildReplayViewerPacket` stays untouched -- that
  # proc is a sim source and this is pure viewer plumbing): the worker
  # pulls it once after a successful load and hands it to the page beside
  # the 'loaded' message. Empty on a replay whose `.shell` carries no
  # calls -- the degrade-to-nothing path, exactly like "huddle"/"vote".
  callsJsonText: string

proc safeTeam(raw: uint8): Team =
  ## Defensive `Team` conversion for bytes that came off disk, not out of a
  ## live sim: a corrupt or forward-dated replay file must never abort the
  ## wasm module over a purely cosmetic huddle/vote row. Out-of-range clamps
  ## to Red rather than raising -- the same "never trust a stored byte"
  ## posture as `readReplayString`'s length checks.
  if raw.int <= ord(high(Team)): Team(raw) else: Red

proc lobbyChatRecordsJson(records: openArray[LobbyChatRecord]): JsonNode =
  ## SEASON 2 huddle: the lobby chat transcript (shell record `0x13`), in
  ## the order it was recorded. `ms`/`ord` ride along so the client can sort
  ## defensively and show relative timing even though it renders the whole
  ## transcript at once (the phase is over almost as soon as playback
  ## reaches it).
  result = newJArray()
  for rec in records:
    result.add(%*{
      "ms": rec.replayTimeMs,
      "ord": rec.ordinal,
      "seat": rec.seat,
      "team": teamText(safeTeam(rec.team)),
      "text": rec.text
    })

proc ballotRecordsJson(records: openArray[BallotRecord]): JsonNode =
  ## SEASON 2 vote: the pre-match ballot (shell record `0x17`) -- every
  ## accepted cast plus the resolution, in recorded order. This purely
  ## RENDERS what the replay carries; it does not recompute the section-5
  ## tally/resolution (the gameplay hash chain is that check, per
  ## docs/designs/prematch-vote-wire-2026-08-31.md §4).
  result = newJArray()
  for rec in records:
    case rec.kind
    of brkCast:
      result.add(%*{
        "k": "cast",
        "ms": rec.replayTimeMs,
        "ord": rec.ordinal,
        "seat": rec.seat,
        "team": teamText(safeTeam(rec.team)),
        "opt": rec.option
      })
    of brkResolved:
      result.add(%*{
        "k": "resolved",
        "ms": rec.replayTimeMs,
        "ord": rec.ordinal,
        "cat": rec.category,
        "tie": rec.tieBreakDrawn,
        "final": rec.finalOption
      })

proc playCallRecordsJson(records: openArray[PlayCallRecord]): JsonNode =
  ## SEASON 2 observability: every accepted play call ("flash") in recorded
  ## order -- when the caller flashed each seat, and the entry ids of the
  ## ladder it flashed (the readable play names). `ladderBytes` stays out on
  ## purpose: it is the opaque compiled ladder, useless to a viewer and by
  ## far the heaviest field. The call number (wire key `epoch`) lets the feed
  ## show "this seat's Nth flash" without recounting.
  result = newJArray()
  for rec in records:
    var plays = newJArray()
    for entry in rec.entries:
      plays.add(%entry.entryId)
    result.add(%*{
      "ms": rec.replayTimeMs,
      "seat": rec.seat,
      "epoch": rec.callNumber,
      "plays": plays
    })

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping (that is how oversized replays
## used to die with ctf_error_len() == 0 and no diagnostic at all). The
## bundle is therefore linked with -s ABORTING_MALLOC=1 — allocation failure
## aborts the runtime loudly — and this fixed buffer, stamped BEFORE each
## risky phase, stays readable from JS after the abort (aborting kills the
## call stack, not the linear memory), so the page can still report what the
## runtime was doing when the 2 GB address space ran out.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string  ## prebuilt once per load; re-stamped every frame

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(
    replay, viewer, nextViewer, events, lobbyChatJson, ballotJson)
  viewer = nextViewer

proc ctfLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "ctf_load_replay", cdecl.} =
  try:
    lastError = ""
    # Reset SEASON 2 shell chrome across reloads (this proc may be called
    # more than once per wasm session) so a huddle/vote panel from a
    # PREVIOUS replay can never bleed into a freshly loaded one.
    lobbyChatJson = nil
    ballotJson = nil
    callsJsonText = ""
    stampStage("parse replay")
    # Keeps `.shell` (huddle transcript, ballot) instead of the discarding
    # `parseReplayBytes` -- see `parseCtfReplayBytesFull`'s own doc comment.
    # Format-2 shell metadata is already fully decoded+verified during this
    # call regardless (parseReplayBytes wraps the same parse and throws the
    # result away), so this costs nothing extra to keep.
    let ctfData = parseCtfReplayBytesFull(data.bytesFromPointer(int(length)))
    if ctfData.shell.lobbyTranscript.len > 0:
      lobbyChatJson = lobbyChatRecordsJson(ctfData.shell.lobbyTranscript)
    if ctfData.shell.calls.len > 0:
      callsJsonText = $playCallRecordsJson(ctfData.shell.calls)
    stampStage("initialize replay runtime")
    # Match the native replay server default: keep a historical replay usable
    # after the first integrity mismatch and surface the warning in the shared
    # replay chrome. `--mismatch-quit` remains a native diagnostic mode.
    #
    # MAP VOTE: hand the runtime the FULL CtfReplayData (the overload the
    # native replay server has always used), not the bare `.replay` half —
    # that is what retains `.shell`'s lifecycle stream AND ballots on the
    # ReplayPlayer, so playback re-applies recorded 0x17 casts at their
    # tick and the resolved winner map installs inside the wasm viewer
    # exactly as it did live (replays.applyReplayEvents).
    var initialized = initReplayRuntime(
      ctfData,
      mismatchQuit = false,
      gameEventLoggingEnabled = false
    )
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    if ctfData.shell.ballots.len > 0:
      # The vote surface the 4-quadrant renderer consumes (see the
      # episodeflow lane + prematch-vote-wire addendum §4): the decoded
      # 0x17 stream under "records", plus the pinned candidate map names
      # under "candidates" (option index == array index), read from the
      # SAME header config playback just booted from.
      var vote = newJObject()
      vote["records"] = ballotRecordsJson(ctfData.shell.ballots)
      if game.config.voteMapSpecs.len > 0:
        var candidates = newJArray()
        for spec in game.config.voteMapSpecs:
          candidates.add(%parseJson(spec)["name"].getStr(""))
        vote["candidates"] = candidates
      ballotJson = vote
    let mapNote =
      " (map " & $game.gameMap.width & "x" & $game.gameMap.height & ")"
    # Refuse boards whose render buffers cannot fit the 32-bit address space
    # BEFORE baking starts, so the page gets a clean diagnostic instead of an
    # OOM abort. Every supported size class passes (oversize boards emit at
    # 1x — see MaxSupersampledMapPixels); this trips only on a future class
    # bigger than colossal.
    stampStage("check viewer capacity" & mapNote)
    let predicted =
      predictedViewerRenderBytes(game.gameMap.width, game.gameMap.height)
    if predicted > WasmViewerBudgetBytes:
      raise newException(CtfError,
        "replay board is too large for the browser viewer" & mapNote &
        ": needs ~" & $(predicted shr 20) &
        " MB of render buffers, beyond the wasm32 2 GB address space")
    frameStage = "advance replay" & mapNote
    stampStage("render first frame" & mapNote)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ctfInput(data: ptr uint8, length: cint)
    {.exportc: "ctf_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ctfFrame(): cint {.exportc: "ctf_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    var seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    if pendingSeekTick >= 0:
      seekTicks = @[pendingSeekTick]
      pendingSeekTick = -1
    var commands = viewer.replayCommands
    if pendingPlay:
      commands.add('p')
      pendingPlay = false
    let events = replay.advanceReplayFrame(
      game,
      tracker,
      seekTicks,
      commands
    )
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc ctfPacketPointer(): ptr uint8
    {.exportc: "ctf_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    packet[0].addr

proc ctfPacketLength(): cint {.exportc: "ctf_packet_len", cdecl.} =
  cint(packet.len)

proc ctfMismatchTick(): cint {.exportc: "ctf_mismatch_tick", cdecl.} =
  if runtimeLoaded:
    cint(replay.hashMismatchTick)
  else:
    -1

# Coworld Checkpoints (spec 0157) diagnostics, used by
# tools/checkpoints/wasm_keyframe_smoke.cjs: how many keyframes the loaded
# replay EMBEDDED (0 when it carried none, or they were rejected), a
# programmatic seek consumed by the next ctf_frame, and the current tick.
proc ctfEmbeddedKeyframes(): cint {.exportc: "ctf_embedded_keyframes", cdecl.} =
  if runtimeLoaded and replay.embeddedKeyframes:
    cint(replay.keyframes.len)
  else:
    0

proc ctfSeek(tick: cint) {.exportc: "ctf_seek", cdecl.} =
  pendingSeekTick = int(tick)

proc ctfPlay() {.exportc: "ctf_play", cdecl.} =
  ## A seek pauses playback; this resumes it on the next frame.
  pendingPlay = true

proc ctfTick(): cint {.exportc: "ctf_tick", cdecl.} =
  if runtimeLoaded: cint(game.tickCount) else: -1

proc ctfErrorPointer(): ptr uint8 {.exportc: "ctf_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ctfErrorLength(): cint {.exportc: "ctf_error_len", cdecl.} =
  cint(lastError.len)

proc ctfCallsPointer(): ptr uint8 {.exportc: "ctf_calls_ptr", cdecl.} =
  ## The play-call ("flash") records JSON -- see callsJsonText's own doc
  ## comment. nil/0 on a replay with no calls; the worker degrades to
  ## simply never forwarding a calls payload.
  if callsJsonText.len == 0:
    nil
  else:
    cast[ptr uint8](callsJsonText[0].addr)

proc ctfCallsLength(): cint {.exportc: "ctf_calls_len", cdecl.} =
  cint(callsJsonText.len)

proc ctfStagePointer(): ptr uint8 {.exportc: "ctf_stage_ptr", cdecl.} =
  ## The progress note (see stageNote above). Unlike ctf_error_*, this stays
  ## valid after an allocation-failure abort, so JS can report what the
  ## runtime was doing when the address space ran out.
  if stageNoteLen == 0:
    nil
  else:
    cast[ptr uint8](stageNote[0].addr)

proc ctfStageLength(): cint {.exportc: "ctf_stage_len", cdecl.} =
  cint(stageNoteLen)

var gameVersionCopy: string
  ## A runtime binding of the compile-time `GameVersion` const, populated on
  ## first use below. A `const` string literal has no stable runtime address
  ## to export a pointer to (emscripten build fails: "expression has no
  ## address"), so this copies it into module-global storage, exactly like
  ## `lastError`/`stageNote` above -- lazily, at CALL time, rather than as a
  ## top-level `let` (which measured empty at runtime: module-level
  ## initializers here do not reliably run before an exported proc can be
  ## invoked from JS, since nothing in this bundle's own control flow ever
  ## calls Nim's `main`/`NimMain` on this path -- only `ctf_load_replay` and
  ## its siblings are ever called).

proc ctfGameVersionPointer(): ptr uint8
    {.exportc: "ctf_game_version_ptr", cdecl.} =
  ## The GameVersion this wasm bundle was compiled with, so a CI check can
  ## load the COMMITTED static-replay-viewer/ctf_replay.wasm and compare it
  ## against src/ctf/sim_types.nim at HEAD -- the same drift class that let
  ## THE FLIP (GameVersion 48 -> 50) ship without a bundle rebuild:
  ## qa_module_eval.cjs's "served bundle is not stale" check only byte-diffs
  ## hand-written JS against source and has no way to see into a compiled
  ## wasm binary, so it stayed green while every GV50 replay failed to load
  ## in the browser. See tools/build_replay_viewer.sh for the remedy.
  if gameVersionCopy.len == 0:
    gameVersionCopy = GameVersion
  if gameVersionCopy.len == 0:
    nil
  else:
    cast[ptr uint8](gameVersionCopy[0].unsafeAddr)

proc ctfGameVersionLength(): cint
    {.exportc: "ctf_game_version_len", cdecl.} =
  if gameVersionCopy.len == 0:
    gameVersionCopy = GameVersion
  cint(gameVersionCopy.len)

var simSourcesStampCopy: string
  ## Runtime binding of build_stamp.nim's compile-time stamp — the same
  ## lazy copy-on-first-call pattern as gameVersionCopy above, for the same
  ## reason (module-level initializers do not reliably run on this bundle's
  ## call-in-only path, and a const has no stable address to export).

proc ctfSimSourcesStampPointer(): ptr uint8
    {.exportc: "ctf_sim_sources_stamp_ptr", cdecl.} =
  ## The content hash of the sim-relevant sources this bundle was BUILT
  ## from (tools/sim_sources_stamp.sh, injected as -d:ctfSimSourcesStamp by
  ## tools/build_replay_viewer.sh / Dockerfile.replay-viewer). The
  ## GameVersion export above only catches drift someone remembered to
  ## hand-bump; the 2026-09-01 engine train changed sim behavior under a
  ## constant GameVersion 50 and every fresh hosted replay re-simulated to
  ## a hash mismatch in the older committed bundle. CI
  ## (tools/qa_module_eval.cjs) recomputes the hash at HEAD and compares it
  ## to this export, so a bundle built from older sim sources fails the
  ## build instead of failing every viewer. Absent (nil/0) only in a bundle
  ## built without the define — which that same check treats as stale.
  if simSourcesStampCopy.len == 0:
    simSourcesStampCopy = ctfSimSourcesStamp
  if simSourcesStampCopy.len == 0:
    nil
  else:
    cast[ptr uint8](simSourcesStampCopy[0].unsafeAddr)

proc ctfSimSourcesStampLength(): cint
    {.exportc: "ctf_sim_sources_stamp_len", cdecl.} =
  if simSourcesStampCopy.len == 0:
    simSourcesStampCopy = ctfSimSourcesStamp
  cint(simSourcesStampCopy.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing ArenaObstacles, render caches, fonts — everything — while the wasm
  # module stays alive and JS keeps calling ctf_load_replay/ctf_frame. The
  # whole session then runs on freed globals: replay hashes get overwritten by
  # later allocations (spurious "REPLAY HASH MISMATCH — SHOWING RECORDED
  # INPUTS" + frozen-at-spawn playback) and seeks crash out of bounds.
  # Unwinding main through emscripten's live-runtime exit skips the destructor
  # epilogue entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
