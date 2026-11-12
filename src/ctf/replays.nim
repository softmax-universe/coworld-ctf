import
  std/[json, os, strutils, tables],
  flatty,
  zippy,
  bitworld/spriteprotocol,
  bitworld/replays as replayCodec,
  broadcast, build_stamp, sim, global, portable_flatty,
  replay_codec as ctfReplayCodec,
  ../shell/[replay_records, seats]

export ctfReplayCodec

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    lifecycleIndex*: int
    ## Player leaves shift overlay indices, so keyframes snapshot overlay state.
    overlaysBytes*: string
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    ## A seek restores the held direct-aim bearings too: they persist between
    ## records, so a keyframe that dropped them would resume a human's match
    ## with the turret back on its policy heading.
    directAim*: seq[int]
    hashValidationFailed*: bool
    hashMismatchTick*: int
    lifecyclePlayback*: LifecyclePlayback
    ballotIndex*: int
      ## MAP VOTE: cursor into ReplayPlayer.ballots at this keyframe, so a
      ## seek re-applies exactly the casts the walk had applied by then.
    portable*: bool
      ## True when `simBytes` / `overlaysBytes` are portable_flatty encoded
      ## (embedded keyframes written by the native server and read by the
      ## 32-bit wasm viewer); false for the viewer's own in-memory keyframes,
      ## which keep the faster native flatty encoding.

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    lifecycleIndex*: int
    lifecycle*: seq[LifecycleRecord]
    ballots*: seq[BallotRecord]
      ## The recorded `0x17` stream (shell.ballots), retained for playback:
      ## kind-0 casts are RE-APPLIED at their recorded tick
      ## (applyReplayEvents), so the sim's own resolveVote reproduces the
      ## live resolution — tally, early-exit tick, and the winner-map
      ## install — from the recorded truth. kind-1 (resolved) records are
      ## viewer chrome only; playback re-derives resolution and skips them.
    ballotIndex*: int
    playSeats*: seq[bool]
    lifecyclePlayback*: LifecyclePlayback
    overlays*: seq[DebugOverlay]
    masks*: seq[uint8]
    pressedMasks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    directAim*: seq[int]
      ## Per-cog direct-aim bearing in brads, -1 when the channel is off for
      ## that cog. Held between records: an aim record is written only when the
      ## bearing CHANGES, so playback must keep applying the last one every
      ## tick exactly as the live server does.
    playing*: bool
    looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    sameEngineBuild*: bool
      ## True only when BOTH this binary and the recording carry an engine
      ## build stamp (build_stamp.nim) and they are EQUAL — i.e. a hash
      ## mismatch here is a genuine same-build determinism break, not the
      ## expected drift of replaying a recording across engine builds. The
      ## viewer chrome keys its banner tier off this: loud red for a
      ## same-build break, a quiet chip for cross-build drift. Any absent
      ## stamp (old recordings, unstamped builds) reads as NOT same-build:
      ## nothing can be proven, and the loud banner's whole meaning is
      ## "this exact engine failed to reproduce its own recording".
    keyframes*: seq[ReplayKeyframe]
    embeddedKeyframes*: bool
      ## True when `keyframes` came from the replay file's embedded keyframe
      ## trailer (spec 0157): they cover the whole match from frame 1, so the
      ## precompute walk keeps them instead of rebuilding its own.
    startTick*: int
      ## First tick the match is actually being PLAYED (the Lobby "WAITING FOR
      ## PLAYERS" span before this is dead air a spectator should never have to
      ## watch). Playback auto-starts here, loops back here, and the scrubber /
      ## tick clock are offset by it so the shown timeline is 0 = first action.
    leadSeries*: seq[seq[int]]
      ## [tick, leadPerTeam…] change-points across the WHOLE match/episode
      ## (one value per team, in Team order): GLORY for classic games,
      ## CUMULATIVE HILL TICKS for KotH games (scanTeamLead). Both are
      ## cumulative and never negative, so the lane draws either as a climb.
      ## Precomputed on the deterministic keyframe walk so the momentum graph
      ## can draw its full-timeline shape all at once (not accumulate as it
      ## plays). Only points where some team's value CHANGES are stored
      ## (compact step series); the client holds each value to the next point
      ## and to maxTick.
    leadMetric*: string
      ## Which of those two `leadSeries` holds ("glory" / "hill"), so the lane
      ## can caption itself truthfully instead of hardcoding one of them.
    leadOutTicks*: seq[int]
      ## The tick each team was ELIMINATED on (no lives left and nobody up),
      ## in the same Team order as a leadSeries point; -1 for a team that
      ## survived. Both metrics are cumulative, so a dead team's curve does
      ## not fall — it goes FLAT and runs on to the right edge looking exactly
      ## like a live team that stopped scoring. The lane needs to know where
      ## each line stops being a competitor so it can say so.
    heatSeries*: seq[seq[int]]
      ## [tick, heatMultPerTeam…] change-points across the WHOLE match,
      ## PARALLEL to `leadSeries` (same shape, same Team order, same
      ## change-point compaction, same one-shot send) but never merged into
      ## it — `leadSeries` is the momentum lane's own metric (glory/hill)
      ## and must keep meaning only that. Each value is the team's HEAT
      ## MULTIPLIER (`heatMult` of `sim.heatEmbers[team]`, glory.nim — 1, 2,
      ## 4 or 8, matching `HeatLadder`), the same number `mintGlory` is
      ## already applying to every deed that team scores. Built by
      ## `scanTeamHeat` on the same deterministic keyframe walk as
      ## `scanTeamLead`, so a full-timeline heat graph is available the
      ## instant the lead chrome ships, not just live.
    endHoldFrames*: int
      ## Real-time frames left to HOLD on the final game-over frame before a
      ## looping replay restarts, so the end segment (winner, win condition,
      ## stats) is readable instead of flashing for one frame. 0 = not holding.
    pendingSeekTick*: int
      ## A seek still converging, or -1. A seek lands on the newest keyframe
      ## at or before its target and then RE-SIMULATES the gap, and while the
      ## precompute walk is still running the keyframes only cover its
      ## prefix — on a 4 405-tick hosted replay the 50 % scrub had ~2 000
      ## ticks of gap and re-simulated all of them inside ONE presentation
      ## frame, so the viewer showed nothing for seconds and the
      ## viewer-check's 50 % clock probe read identically to its 0 % probe.
      ## The gap is now walked SeekTicksPerFrame at a time (like the
      ## precompute scan), so the first frame after a click already moves and
      ## no frame stalls.
    skipLulls*: bool
      ## When on, playback fast-forwards through the lull spans below. ON for
      ## every replay `initReplayPlayer` builds: a spectator's default watch
      ## should not sit through the quiet stretches. 'f' turns it off.
    lullSpans*: seq[array[2, int]]
      ## Inclusive [firstTick, lastTick] spans where nothing beat-worthy
      ## happens (no kill/steal/return/capture/phase change within
      ## LullLeadTicks), precomputed on the same keyframe walk. Spans shorter
      ## than MinLullTicks are dropped: skipping a short breather is more
      ## jarring than watching it.
    beatEvents*: JsonNode
      ## Full-match flag-story beats (steal/return/capture) plus the terminal
      ## gameover verdict, exactly as `stepEvents` emits them, precomputed on
      ## the same keyframe walk. Shipped once to the HUD client so the
      ## scrubber can place its flag markers and winner cap up front instead
      ## of accumulating them as playback happens to pass each beat.
    achievementBadges*: JsonNode
      ## The final game's earned achievements with their focus cogs
      ## ([{"id", "s" (seat slot), "n" (address)}]), read off the scan sim
      ## after its walk crossed finishGame. Shipped once with the lead
      ## chrome so a viewer opened from a badge's watch link
      ## (?achievement=<id>) can select the receiving cog.
    scan: ReplayScan
      ## The in-flight whole-match precompute walk, nil when finished (and
      ## for players that never scan — the offline tools). The walk used to
      ## run synchronously before the first frame — seconds of black screen
      ## on a giant board — and now advances a bounded slice per
      ## presentation frame (advanceReplayScan) while playback is already on
      ## screen.
    scanDone: bool
      ## True once the precompute walk has finished; read via scanComplete.
      ## Private so no caller can flip it mid-walk — a premature true would
      ## freeze a half-scanned timeline into the HUD (the lead chrome ships
      ## exactly once per viewer).

  ReplayScan* = ref object
    ## Working state of the incremental precompute walk: a second sim +
    ## player stepped from tick 0 that derives keyframes, the glory momentum
    ## series, story beats and lull spans without touching the on-screen
    ## playback state.
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastLead: seq[int]
    lastHeat: seq[int]
    leadSeenAlive: seq[bool]
      ## Per team: has it ever had a life or a body on the field? Gates the
      ## elimination latch so the lobby's universal zero is not read as a
      ## sixteen-way wipe on tick 1.
    interval: int
    maxTick: int
    portable: bool
      ## Encode keyframes with portable_flatty (for embedding in a file).

# PlaybackSpeeds moved to sim_types.nim (the single source for every speed-coupled
# layer); re-exported here for the existing `import replays` consumers.
export PlaybackSpeeds

const
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
    ## How long a looping replay holds on its final game-over frame (real
    ## seconds) before restarting.
  LullLeadTicks* = 2 * ReplayFps
    ## Context kept before and after every beat event.
  MinLullTicks* = 6 * ReplayFps
    ## Shortest quiet stretch worth fast-forwarding.
  LullSpeedBoost* = 8
    ## Speed multiplier applied inside a lull span.
  MaxLullTicksPerFrame* = 64
    ## Per-frame cap on boosted stepping so the server stays responsive.
  SeekTicksPerFrame* = 240
    ## Per-frame cap on the re-simulation a SEEK may do (10 s of sim time).
    ## A seek past the keyframed prefix converges over this many ticks per
    ## presentation frame instead of blocking one frame for the whole gap.
  CtfReplayMagic* = "COWLDCTF"
  CtfReplayFormatVersion = 1'u16
  CtfReplaySpec* = ReplaySpec(
    magic: CtfReplayMagic,
    formatVersion: CtfReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

export replayCodec

proc tickTime*(tick: int): uint32 =
  ## Converts a simulation tick to replay milliseconds.
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(
  replayWriter: var CtfReplayWriter,
  time: uint32,
  playerIndex: int,
  mask: uint8
) =
  ## Writes one replay input event when a COG's applied mask changes.
  ##
  ## Lives here rather than in server.nim because the mask log IS the replay's
  ## action stream: the tests that prove the recorded masks re-simulate to the
  ## identical hash chain have to write it exactly the way the server does, and
  ## two copies of this would be two chances to drift.
  if playerIndex < 0 or playerIndex >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[playerIndex] == mask:
    return
  replayWriter.writeInput(ReplayInput(
    time: time,
    player: uint8(playerIndex),
    keys: mask
  ))
  replayWriter.lastMasks[playerIndex] = mask

const
  ReplayAimRecordFlag* = 0x80'u8
    ## Marks an input record as a DIRECT-AIM record rather than a button mask:
    ## `player` is (flag or cogIndex) and `keys` carries the absolute bearing
    ## in brads. The codec's record layout is untouched — only this one byte's
    ## high bits, which a cog index can never use (MaxPlayers is 32).
    ##
    ## Direct aim is a bearing the ENGINE writes on the cog, not a button the
    ## cog pressed, so it cannot ride the mask: a replay that dropped it would
    ## re-simulate a human's whole match with the turret pointing elsewhere and
    ## every shot missing. Only a config with `allowDirectAim` on ever writes
    ## one, which is why a league replay's byte stream is unchanged.
  ReplayAimClearFlag* = 0x40'u8
    ## On an aim record, marks the moment the channel goes OFF for that cog —
    ## the human left and the policy has the seat back. Without it, playback
    ## would keep pinning the last human bearing onto a policy-driven cog.
  ReplayAimPlayerMask* = 0x3f'u8

proc isDirectAimRecord*(input: ReplayInput): bool =
  ## True when an input record carries a bearing instead of a button mask.
  (input.player and ReplayAimRecordFlag) != 0

proc directAimRecordPlayer*(input: ReplayInput): int =
  ## The cog index an aim record addresses.
  int(input.player and ReplayAimPlayerMask)

proc directAimRecordBrads*(input: ReplayInput): int =
  ## The bearing an aim record carries; -1 when it turns the channel off.
  if (input.player and ReplayAimClearFlag) != 0:
    -1
  else:
    int(input.keys)

proc writeDirectAimChange*(
  replayWriter: var CtfReplayWriter,
  lastAim: var seq[int],
  time: uint32,
  playerIndex: int,
  brads: int
) =
  ## Writes one replay aim event when a COG's direct-aim bearing changes.
  ## `brads` is -1 when the channel is off for that cog (no human driving).
  ##
  ## Lives beside writeInputMaskChange and for the same reason: this stream IS
  ## the replay's action stream for a human seat, and the tests that prove a
  ## PLAY replay re-simulates to the identical hash chain must write it exactly
  ## the way the server does.
  if playerIndex < 0 or playerIndex > int(ReplayAimPlayerMask):
    return
  while lastAim.len <= playerIndex:
    lastAim.add(-1)
  if lastAim[playerIndex] == brads:
    return
  let player =
    if brads < 0:
      uint8(playerIndex) or ReplayAimRecordFlag or ReplayAimClearFlag
    else:
      uint8(playerIndex) or ReplayAimRecordFlag
  replayWriter.writeInput(ReplayInput(
    time: time,
    player: player,
    keys: (if brads < 0: 0'u8 else: uint8(brads and 0xff))
  ))
  lastAim[playerIndex] = brads

# ---------------------------------------------------------------------------
# The one-page-policy REFLASH record.
#
# Season 2 flashes a cog a JSON strategy page: once at episode start, and
# again at an arbitrary tick (BR re-strategizes mid-episode; its cogs have
# ONE life, so there is no spawn edge to hang it on) or on each respawn
# (CTF). That page swap is an out-of-band INPUT to the episode. Nothing in
# the recorded button masks witnesses it, so a replay that does not carry it
# re-simulates a match under a strategy it never played — silently. This
# record is what makes it carriable, and gameHash (sim_state.nim) is what
# makes losing it LOUD.
#
# WHY IT RIDES THE CHAT RECORD, and why the format version does NOT move.
# The codec's version check is strict equality (`bitworld/replays.nim`:
# "Unsupported replay format version"), so bumping CtfReplayFormatVersion
# would not "add a record type" — it would reject every replay ever
# archived, on the spot. The codec also raises on any record type it does
# not know, so a brand-new record byte is unreadable by anything not rebuilt
# in lockstep. Both roads end at "old replays stop loading", which is the
# one thing this change is not allowed to do.
#
# So the reflash rides an EXISTING record, exactly the way direct aim rides
# the input record (ReplayAimRecordFlag above, and for the same reasons):
# the chat record is already {time, player, string} — tick, seat, content —
# already parsed by every existing reader, and already the stream whose
# payload reaches the sim. Only the `player` byte's high bit is spent, which
# a cog index can never set (MaxPlayers is 32). Old replays contain no such
# record and load byte-for-byte as before; a new replay identifies itself
# through its header config (`allowPolicyReflash`, sim_config.nim), not
# through a version number.
# ---------------------------------------------------------------------------
const
  ReplayReflashRecordFlag* = 0x80'u8
    ## Marks a CHAT record as a policy-page FLASH rather than a shout:
    ## `player` is (flag or cogIndex) and `message` carries the page. Same
    ## bit, same argument, as ReplayAimRecordFlag on the input stream — and
    ## a different stream, so the two never meet.
  ReplayReflashPlayerMask* = 0x3f'u8
  ReplayReflashHashChars* = 16
    ## The page's content hash, zero-padded hex, at the head of the record.
  ReplayReflashSeparator* = ' '
    ## One byte between the hash and the page. A page is JSON, which cannot
    ## begin with a space, so the split point is unambiguous.

  # --- The HANDOFF DECLARATION record (S2 give-item, the play shell's
  # HANDOFF play). Same road as the reflash record above, for the same
  # reasons: declareHandoff is an out-of-band input — nothing in the mask
  # stream witnesses it, but the transfer its channel completes moves HASHED
  # state (hasGun/hasHopper/bandages) — so a replay that does not carry the
  # declaration re-simulates a match where the exchange never happened. It
  # rides the CHAT record under the second high bit of the player byte
  # (both set), which no cog index and no reflash record can produce, so
  # the three tenants of the stream never collide. No content hash: the
  # payload is a closed <=7-byte vocabulary and the membership check IS the
  # integrity check (a hash would be weaker than the vocabulary).
  ReplayHandoffRecordFlag* = 0xc0'u8
    ## Marks a CHAT record as a give-item handoff DECLARATION: `player` is
    ## (flag or cogIndex) and `message` is the declared item — "gun",
    ## "hopper", "bandage", or "" for an explicit clear.

  # --- The PACT DECLARATION record (ALLIANCE, engine registration
  # rewire, GameVersion 56, the `pact` WASM play's own registration seam).
  # Same road as the handoff record above, and for the same reason: like a
  # handoff declaration, this is an out-of-band input the WASM ladder
  # never re-runs on playback (initShellPlaybackEpisode keeps no
  # ladder, no SeatBody, no guest wasm — see that proc's own comment), so
  # an accepted declaration must be RECORDED and re-applied directly
  # rather than re-derived from replaying the call. It moves state
  # `pactMask` reads (though `pactDeclaredPartners` itself stays out of
  # `gameHash` — see that field's own comment), so a replay that dropped
  # this record would re-simulate a match where a (dis)pact never
  # happened. The player byte's two "record kind" bits (reflash 0x80 =
  # 10, handoff 0xc0 = 11, plain chat = 00) leave exactly one combination
  # unused — 0x40 = 01 — which this record claims, so all four tenants of
  # the stream (plain chat, reflash, handoff, pact declaration) coexist
  # without collision.
  ReplayPactDeclarationRecordFlag* = 0x40'u8
    ## Marks a CHAT record as a `pact` play partner declaration: `player`
    ## is (flag or cogIndex) and `message` is the declared partner TEAMS,
    ## comma-joined lowercase team names in enum order (e.g. "blue,green"),
    ## or "" for an explicit clear (no active `pact` entry this tick).

proc isPolicyPageRecord*(chat: ReplayChat): bool =
  ## True when a chat record carries a flashed policy page, not a shout.
  ## Checked on BOTH high bits: a handoff declaration record (0xc0) also
  ## carries the reflash bit and must never read as a page. Archived
  ## replays are untouched — no cog index can set either bit, and every
  ## recorded reflash byte is (0x80 or a six-bit index), never 0xc0.
  (chat.player and ReplayHandoffRecordFlag) == ReplayReflashRecordFlag

proc isHandoffDeclarationRecord*(chat: ReplayChat): bool =
  ## True when a chat record carries a give-item handoff declaration.
  (chat.player and ReplayHandoffRecordFlag) == ReplayHandoffRecordFlag

proc handoffRecordPlayer*(chat: ReplayChat): int =
  ## The cog index a handoff declaration record addresses.
  int(chat.player and ReplayReflashPlayerMask)

proc decodeHandoffDeclarationRecord*(chat: ReplayChat): string =
  ## The declared item a handoff record carries, checked against the consent
  ## seam's own closed vocabulary. Raises ReplayError on anything else:
  ## an unknown item would re-simulate to a refused declaration and let the
  ## hash chain report the divergence at a tick that explains nothing —
  ## failing HERE names the bad record instead.
  result = chat.message
  if result.len > 0 and result != "gun" and result != "hopper" and
      result != "bandage":
    raise newException(ReplayError, "Replay handoff record item is unknown")

proc isPactDeclarationRecord*(chat: ReplayChat): bool =
  ## True when a chat record carries a `pact` play partner declaration.
  (chat.player and ReplayHandoffRecordFlag) == ReplayPactDeclarationRecordFlag

proc pactDeclarationRecordPlayer*(chat: ReplayChat): int =
  ## The cog index a pact declaration record addresses.
  int(chat.player and ReplayReflashPlayerMask)

proc decodePactDeclarationRecord*(chat: ReplayChat): seq[Team] =
  ## The declared partner teams a pact record carries — a comma-joined
  ## lowercase team-name list, or "" for an explicit clear (empty result).
  ## Raises ReplayError on any name outside `teamText`'s closed vocabulary:
  ## an unknown team would re-simulate to a refused declaration and let the
  ## hash chain report the divergence at a tick that explains nothing —
  ## failing HERE names the bad record instead.
  if chat.message.len == 0:
    return
  for part in chat.message.split(','):
    var found = false
    for team in Team:
      if teamText(team) == part:
        result.add team
        found = true
        break
    if not found:
      raise newException(ReplayError,
        "Replay pact declaration record names an unknown team")

proc policyPageRecordPlayer*(chat: ReplayChat): int =
  ## The cog index a reflash record addresses.
  int(chat.player and ReplayReflashPlayerMask)

proc encodePolicyPageRecord*(page: string): string =
  ## The record body: the page's content hash, then the page itself.
  ##
  ## The hash is recorded ALONGSIDE the content rather than instead of it.
  ## Content-only would leave nothing to check the bytes against; hash-only
  ## would give a replay that can prove what strategy ran but cannot SHOW it
  ## — and showing it is most of why Season 2 wants the event at all (the
  ## broadcast and forum surfaces read the page off the replay). Carrying
  ## both costs one page per flash — kilobytes against a keyframe stream
  ## already measured in megabytes — and buys an integrity check that is
  ## independent of the transport.
  toHex(policyPageHash(page), ReplayReflashHashChars) &
    ReplayReflashSeparator & page

proc decodePolicyPageRecord*(chat: ReplayChat): string =
  ## The page a reflash record carries, verified against the content hash it
  ## was recorded with. Raises ReplayError on a malformed or tampered
  ## record: a page whose bytes no longer hash to what the recording claimed
  ## would re-simulate to a different gameHash anyway, and failing HERE says
  ## which record went bad instead of only which tick.
  if chat.message.len < ReplayReflashHashChars + 1 or
      chat.message[ReplayReflashHashChars] != ReplayReflashSeparator:
    raise newException(ReplayError, "Replay reflash record is malformed")
  var recorded: uint64
  try:
    recorded = fromHex[uint64](chat.message[0 ..< ReplayReflashHashChars])
  except ValueError:
    raise newException(ReplayError, "Replay reflash record hash is not hex")
  result = chat.message[ReplayReflashHashChars + 1 .. ^1]
  if policyPageHash(result) != recorded:
    raise newException(
      ReplayError,
      "Replay reflash page does not match its recorded content hash"
    )

proc writePolicyPageFlash*(
  replayWriter: var CtfReplayWriter,
  time: uint32,
  playerIndex: int,
  page: string
) =
  ## Writes one replay event for a policy page that was JUST flashed onto a
  ## cog.
  ##
  ## Lives here beside writeInputMaskChange/writeDirectAimChange and for the
  ## identical reason: this stream IS part of the replay's input stream, and
  ## the tests that prove a reflashed episode re-simulates to the same hash
  ## chain have to write it exactly the way the server does. Callers write
  ## only what `sim.applyPolicyPage` ACCEPTED, so the file never claims a
  ## flash the sim refused.
  ##
  ## A cog the record cannot address is a doAssert, deliberately, and NOT a
  ## silent return: the caller has already applied the page to the sim, so
  ## returning quietly here would leave an applied-but-unrecorded input —
  ## the exact failure this whole record exists to prevent, and one that
  ## shows up only as an unexplained hash mismatch much later. The invariant
  ## holds today by MaxPlayers (32) being well under the six-bit field; this
  ## fires the moment a wider board breaks it.
  doAssert playerIndex >= 0 and playerIndex <= int(ReplayReflashPlayerMask),
    "Cog index " & $playerIndex & " cannot be addressed by a reflash record"
  replayWriter.writeChat(
    time,
    int(uint8(playerIndex) or ReplayReflashRecordFlag),
    encodePolicyPageRecord(page)
  )

proc writeHandoffDeclaration*(
  replayWriter: var CtfReplayWriter,
  time: uint32,
  playerIndex: int,
  item: string
) =
  ## Writes one replay event for a give-item handoff declaration the sim
  ## JUST accepted (sim.declareHandoff returned true) — item "" is an
  ## accepted explicit clear. Same home and same discipline as
  ## writePolicyPageFlash above: callers record ONLY what the consent seam
  ## accepted, stamped with the tick it was accepted on, so the file can
  ## never claim a declaration the sim refused nor omit one it took. The
  ## unaddressable-cog doAssert carries writePolicyPageFlash's argument
  ## verbatim: the declaration is already applied, so returning quietly
  ## would leave an applied-but-unrecorded input.
  doAssert playerIndex >= 0 and playerIndex <= int(ReplayReflashPlayerMask),
    "Cog index " & $playerIndex & " cannot be addressed by a handoff record"
  doAssert item.len == 0 or item == "gun" or item == "hopper" or
    item == "bandage", "Handoff record item is outside the seam's vocabulary"
  replayWriter.writeChat(
    time,
    int(uint8(playerIndex) or ReplayHandoffRecordFlag),
    item
  )

proc writePactDeclaration*(
  replayWriter: var CtfReplayWriter,
  time: uint32,
  playerIndex: int,
  partners: openArray[Team]
) =
  ## Writes one replay event for a `pact` play partner declaration the sim
  ## JUST accepted (sim.declarePactPartners returned true) — an empty
  ## `partners` is an accepted explicit clear. Same home and same
  ## discipline as writeHandoffDeclaration above: callers record ONLY what
  ## the consent seam accepted, stamped with the tick it was accepted on,
  ## so the file can never claim a declaration the sim refused nor omit
  ## one it took. The unaddressable-cog doAssert carries
  ## writeHandoffDeclaration's argument verbatim: the declaration is
  ## already applied, so returning quietly here would leave an
  ## applied-but-unrecorded input.
  doAssert playerIndex >= 0 and playerIndex <= int(ReplayReflashPlayerMask),
    "Cog index " & $playerIndex & " cannot be addressed by a pact record"
  var names: seq[string]
  for team in partners:
    names.add teamText(team)
  replayWriter.writeChat(
    time,
    int(uint8(playerIndex) or ReplayPactDeclarationRecordFlag),
    names.join(",")
  )

proc openReplayWriter*(
  path: string,
  configJson: string,
  openedAtMs = 0'u64,
): CtfReplayWriter =
  ## Selects format 2 only for the conjunctive play-seat episode gate. Every
  ## other configuration delegates the complete file to bitworld format 1.
  var config = defaultGameConfig()
  config.update(configJson)
  let shellEpisode = config.isPlaySeatEpisode()
  ctfReplayCodec.openReplayWriter(
    path,
    configJson,
    CtfReplaySpec,
    shellEpisode = shellEpisode,
    shellSeatCount = (if shellEpisode: config.slots.len else: 0),
    openedAtMs = openedAtMs)

proc parseReplayBytes*(bytes: string): ReplayData =
  ## Parses one replay file buffer into memory.
  ctfReplayCodec.parseReplayBytes(
    bytes,
    CtfReplaySpec,
    ReplayCompatibleGameVersions
  )

proc parseCtfReplayBytesFull*(bytes: string): ctfReplayCodec.CtfReplayData =
  ## Same parse as `parseReplayBytes` above, but retains the verified format-2
  ## shell metadata (`.shell`: lobby transcript, ballots, ...) instead of
  ## discarding it. A host that wants to RENDER shell records (the replay
  ## viewer's huddle/vote panels) calls this instead of `parseReplayBytes`;
  ## every other consumer (native playback, which never reads `.shell`) is
  ## unaffected by this addition.
  ctfReplayCodec.parseCtfReplayBytes(
    bytes,
    CtfReplaySpec,
    ReplayCompatibleGameVersions
  )

proc loadReplay*(path: string): ReplayData =
  ## Loads a replay file into memory.
  ctfReplayCodec.loadReplay(
    path,
    CtfReplaySpec,
    ReplayCompatibleGameVersions
  )

proc loadCtfReplay*(path: string): CtfReplayData =
  ## Loads gameplay plus verified format-2 shell metadata.
  ctfReplayCodec.loadCtfReplay(
    path,
    CtfReplaySpec,
    ReplayCompatibleGameVersions
  )

type ReplayStaticBakes = object
  ## The per-map render/collision bakes inside SimServer that never change
  ## within an episode (pixels bake once at map load, masks derive from the
  ## immutable map).
  mapPixels, mapRgba, darkBgPixels: seq[uint8]
  walkMask, wallMask, windowMask, fovBlocked: seq[bool]

proc swapStaticBakes(sim: var SimServer, bakes: var ReplayStaticBakes) =
  swap(sim.mapPixels, bakes.mapPixels)
  swap(sim.mapRgba, bakes.mapRgba)
  swap(sim.darkBgPixels, bakes.darkBgPixels)
  swap(sim.walkMask, bakes.walkMask)
  swap(sim.wallMask, bakes.wallMask)
  swap(sim.windowMask, bakes.windowMask)
  swap(sim.fovBlocked, bakes.fovBlocked)

proc serializeReplaySim*(sim: var SimServer): string =
  ## Serializes one simulation state for replay keyframes — WITHOUT the
  ## static map bakes, which are set aside during the flatty pass and
  ## re-attached (`sim` reads back unchanged). The bakes are identical in
  ## every keyframe of an episode; on a giant generated map they are ~40 MB,
  ## and one keyframe per 100 ticks serialized them ~55x over — 2.4 GB of
  ## duplicates that the 32-bit wasm replay viewer cannot even address
  ## (every giant-map hosted replay died loading: "stuck warming up").
  var bakes: ReplayStaticBakes
  sim.swapStaticBakes(bakes)
  result = sim.toFlatty()
  sim.swapStaticBakes(bakes)

proc serializePortableReplaySim*(sim: var SimServer): string =
  ## serializeReplaySim with pointer-width-portable framing: the bytes a
  ## 64-bit server writes decode in the 32-bit wasm viewer. Used for
  ## keyframes embedded in a `.bitreplay` and for game checkpoints.
  var bakes: ReplayStaticBakes
  sim.swapStaticBakes(bakes)
  result = sim.toPortableFlatty()
  sim.swapStaticBakes(bakes)

proc attachDonorBakes(result: var SimServer, donor: var SimServer)

proc deserializeReplaySim*(bytes: string, donor: var SimServer): SimServer =
  ## Deserializes one simulation state from a replay keyframe, taking the
  ## static map bakes from `donor` — the same episode's outgoing sim, whose
  ## bakes are byte-identical to what serializeReplaySim stripped. MOVE
  ## semantics: `donor` gives its bakes to the returned sim (every caller
  ## replaces the donor with the result immediately after).
  result = bytes.fromFlatty(SimServer)
  result.attachDonorBakes(donor)

proc deserializePortableReplaySim*(
  bytes: string,
  donor: var SimServer
): SimServer =
  ## deserializeReplaySim for serializePortableReplaySim bytes.
  result = bytes.fromPortableFlatty(SimServer)
  result.attachDonorBakes(donor)

proc attachDonorBakes(result: var SimServer, donor: var SimServer) =
  ## MAP VOTE: "static for the whole episode" stopped being true the day a
  ## resolved map ballot could swap the episode map mid-lobby. The keyframe
  ## DOES serialize `gameMap` (only the derived bakes are stripped), so a
  ## restore that crosses the swap in either direction — donor post-swap,
  ## keyframe pre-swap, or the reverse — can detect the disagreement by
  ## name and rebuild the bakes from the restored map def instead of
  ## donating stale ones. Same-map restores (every episode without an
  ## armed vote, and every seek on one side of the swap) keep the cheap
  ## donation path, byte-identical to before.
  let crossMap = result.gameMap.name != donor.gameMap.name
  var bakes: ReplayStaticBakes
  donor.swapStaticBakes(bakes)
  result.swapStaticBakes(bakes)
  if crossMap:
    let darkBg = move(result.darkBgPixels)   # map-independent: keep donated.
    result.buildMapBakes()
    result.darkBgPixels = darkBg
    ## The restored fovCaches were computed against the keyframe's own
    ## masks, which buildMapBakes just reproduced — but restamp below
    ## needs the diamond-free base first, and a cross-map cache carries no
    ## guarantee the donor path's "valid by construction" argument relies
    ## on. Drop them; the next viewer read re-casts.
    for i in 0 ..< result.fovCaches.len:
      result.fovCaches[i].valid = false
  ## The donated walk/wall/fov masks are NOT fully static: the spinning
  ## diamonds stamp tick-dependent stone into them, and the donor's stamps
  ## are at ITS tick's spin frame — not the keyframe's. The restored
  ## diamondPatches may disagree silently (applyDiamondGeometry skips frames
  ## that "have not changed"), so restamp every diamond at its restored
  ## frame over the diamond-free base the keyframe carried.
  result.restampDiamondGeometry()

proc isSameEngineBuild*(recordedStamp, ownStamp: string): bool =
  ## The banner-tier decision (see ReplayPlayer.sameEngineBuild): a
  ## mismatch counts as same-build ONLY when both sides carry a stamp and
  ## they agree. Two empty stamps are NOT "the same build" — they are two
  ## unknowns, and the loud banner's claim ("this exact engine failed to
  ## reproduce its own recording") must never rest on an absence.
  ownStamp.len > 0 and recordedStamp == ownStamp

proc recordedEngineStamp*(configJson: string): string =
  ## The engine build stamp the RECORDING side wrote into the replay
  ## header's configJson (replay_codec.nim's stampedConfigJson), or "" for
  ## the many replays that predate stamping or came from unstamped builds.
  if configJson.len == 0:
    return ""
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("engineStamp"):
      result = node["engineStamp"].getStr("")
  except CatchableError:
    result = ""

type
  EmbeddedKeyframeSet* = object
    ## The decoded embedded-keyframe trailer of one `.bitreplay` (spec 0157).
    ## On the wire: zlib(toPortableFlatty(EmbeddedKeyframeSet)).
    version*: int
    interval*: int
      ## Ticks between keyframes; a seek re-simulates at most interval-1.
    gameVersion*: string
      ## GameVersion of the engine that walked the keyframes. A reader on a
      ## different GameVersion ignores them (the sim layout may differ) and
      ## falls back to its own precompute walk.
    simStamp*: string
      ## ctfSimSourcesStamp of the writer ("" for unstamped dev builds).
    keyframes*: seq[ReplayKeyframe]

const
  EmbeddedKeyframeVersion* = 1
  DefaultEmbeddedKeyframeTicks* = 200
    ## Below SeekTicksPerFrame, so any seek converges inside the frame it
    ## was clicked on.

proc encodeEmbeddedKeyframes*(set: EmbeddedKeyframeSet): string =
  compress(set.toPortableFlatty(), BestSpeed, dfZlib)

proc decodeEmbeddedKeyframes*(blob: string): EmbeddedKeyframeSet =
  ## Raises on a corrupt or foreign block; callers fall back to scanning.
  result = uncompress(blob, dfZlib).fromPortableFlatty(EmbeddedKeyframeSet)
  if result.version != EmbeddedKeyframeVersion:
    raise newException(ReplayError,
      "unsupported embedded keyframe version " & $result.version)
  for keyframe in result.keyframes:
    if not keyframe.portable:
      raise newException(ReplayError, "embedded keyframe is not portable")
  for i in 1 ..< result.keyframes.len:
    if result.keyframes[i].tick <= result.keyframes[i - 1].tick:
      raise newException(ReplayError, "embedded keyframes are not ascending")

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.pressedMasks = @[]
  result.lastAppliedMasks = @[]
  result.directAim = @[]
  result.overlays = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1
  result.sameEngineBuild = isSameEngineBuild(
    recordedEngineStamp(data.configJson), ctfSimSourcesStamp)

proc configuredPlaySeats(configJson: string): seq[bool] =
  var config = defaultGameConfig()
  config.update(configJson)
  result = newSeq[bool](config.slots.len)
  for seat in 0 ..< config.slots.len:
    result[seat] = config.isPlaySeat(seat)

proc initReplayPlayer*(data: CtfReplayData): ReplayPlayer =
  ## Builds playback with the verified lifecycle stream retained.
  result = initReplayPlayer(data.replay)
  result.lifecycle = data.shell.lifecycle
  result.ballots = data.shell.ballots
  result.playSeats = configuredPlaySeats(data.replay.configJson)
  result.lifecyclePlayback = initLifecyclePlayback(result.playSeats)
  if data.keyframeBlob.len > 0:
    # Spec 0157: a keyframed replay seeks anywhere on frame 1. A block this
    # build cannot use (other GameVersion, corrupt bytes, a value too wide
    # for wasm32) is dropped with a log line; the precompute walk then
    # derives keyframes exactly as for a legacy replay.
    try:
      let embedded = decodeEmbeddedKeyframes(data.keyframeBlob)
      if embedded.gameVersion != GameVersion or (
          embedded.simStamp.len > 0 and ctfSimSourcesStamp.len > 0 and
          embedded.simStamp != ctfSimSourcesStamp):
        echo "embedded replay keyframes ignored: walked by GameVersion ",
          embedded.gameVersion, " build ", embedded.simStamp,
          ", this engine is ", GameVersion, " build ", ctfSimSourcesStamp
      elif embedded.keyframes.len == 0 or embedded.keyframes[0].tick != 0:
        echo "embedded replay keyframes ignored: no tick-0 keyframe"
      else:
        result.keyframes = embedded.keyframes
        result.embeddedKeyframes = true
    except CatchableError as error:
      echo "embedded replay keyframes ignored: ", error.msg

proc replaySpeed*(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed.
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  ## Returns the final tick available in the replay.
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  ## Returns the first tick a spectator should watch: the moment the match
  ## leaves the lobby (never negative, never past the end).
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  ## Resets replay playback cursors.
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.debugSpriteIndex = 0
  replay.hashIndex = 0
  replay.lifecycleIndex = 0
  replay.ballotIndex = 0
  replay.lifecyclePlayback = initLifecyclePlayback(replay.playSeats)
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = @[]
  replay.pressedMasks = @[]
  replay.lastAppliedMasks = @[]
  replay.directAim = @[]
  replay.overlays = @[]

proc saveReplayKeyframe*(
  replay: ReplayPlayer,
  sim: var SimServer,
  portable = false
): ReplayKeyframe =
  ## Builds one replay keyframe from the current playback state. A
  ## `portable` keyframe is framed for embedding in a replay file.
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes:
      if portable: serializePortableReplaySim(sim)
      else: serializeReplaySim(sim),
    portable: portable,
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    debugSpriteIndex: replay.debugSpriteIndex,
    hashIndex: replay.hashIndex,
    lifecycleIndex: replay.lifecycleIndex,
    ballotIndex: replay.ballotIndex,
    overlaysBytes:
      if portable: replay.overlays.toPortableFlatty()
      else: replay.overlays.toFlatty(),
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    directAim: replay.directAim,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick,
    lifecyclePlayback: replay.lifecyclePlayback
  )

proc restoreReplayKeyframe*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  ## Restores playback state from one replay keyframe. The outgoing sim
  ## donates its static map bakes to the restored one (keyframes exclude
  ## them — see serializeReplaySim).
  let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  var restored =
    if keyframe.portable: deserializePortableReplaySim(keyframe.simBytes, sim)
    else: deserializeReplaySim(keyframe.simBytes, sim)
  restored.gameEventLoggingEnabled = gameEventLoggingEnabled
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.debugSpriteIndex = keyframe.debugSpriteIndex
  replay.hashIndex = keyframe.hashIndex
  replay.lifecycleIndex = keyframe.lifecycleIndex
  replay.ballotIndex = keyframe.ballotIndex
  replay.lifecyclePlayback = keyframe.lifecyclePlayback
  replay.overlays =
    if keyframe.portable:
      keyframe.overlaysBytes.fromPortableFlatty(seq[DebugOverlay])
    else:
      keyframe.overlaysBytes.fromFlatty(seq[DebugOverlay])
  replay.masks = keyframe.masks
  replay.pressedMasks = newSeq[uint8](replay.masks.len)
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.directAim = keyframe.directAim
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  ## Returns the newest keyframe at or before one tick.
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  ## Expands replay input tables for one player.
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.pressedMasks.add(0)
    replay.lastAppliedMasks.add(0)
    replay.overlays.add(DebugOverlay())

proc clearReplayPressedMasks(replay: var ReplayPlayer) =
  ## Clears per-step replay press events.
  for mask in replay.pressedMasks.mitems:
    mask = 0

proc clearReplayAbandon(sim: var SimServer, playerIndex: int) =
  ## Priority 1 restores playback presence without taking Priority 2's roster
  ## accounting API. Rebinding clears only the existing per-game flag.
  let accountIndex = sim.rewardAccountForPlayer(playerIndex)
  if accountIndex >= 0:
    sim.rewardAccounts[accountIndex].abandoned = false

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins and inputs for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    if sim.config.numAgents > 0:
      ## Paintball: a leave does NOT shift the mask arrays. The cogs are fixed
      ## for the whole episode and the recorded masks are indexed BY COG, so
      ## deleting a row would silently re-point every mask after it at the
      ## wrong cog for the rest of playback. The roster entry goes; the cog
      ## mask slots stay where they are. (Only the /global kick path writes a
      ## leave mid-episode — a dropped seat never does.)
      discard
    else:
      ## Classic: the mask rows are renumbered with the roster, exactly as
      ## every recorded classic replay expects.
      if int(leave.player) < replay.masks.len:
        replay.masks.delete(int(leave.player))
      if int(leave.player) < replay.pressedMasks.len:
        replay.pressedMasks.delete(int(leave.player))
      if int(leave.player) < replay.lastAppliedMasks.len:
        replay.lastAppliedMasks.delete(int(leave.player))
      if int(leave.player) < replay.overlays.len:
        replay.overlays.delete(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  # Lifecycle is the no-compaction equivalent of a legacy leave. Both legacy
  # leaves and joins are phase 0 in format 2, so apply lifecycle only after
  # both have completed at this timestamp and before input/chat (phase 2).
  while replay.lifecycleIndex < replay.lifecycle.len and
      replay.lifecycle[replay.lifecycleIndex].replayTimeMs <= time:
    let record = replay.lifecycle[replay.lifecycleIndex]
    replay.lifecyclePlayback.applyLifecycleRecord(record)
    let seat = int(record.seat)
    var playerIndex = -1
    for index, player in sim.players:
      if player.joinOrder == seat:
        playerIndex = index
        break
    if playerIndex < 0:
      raise newException(ReplayError,
        "Replay lifecycle seat has no retained player row")
    replay.ensureReplayPlayer(playerIndex)
    case record.kind
    of lrDisconnect, lrKick:
      sim.recordGameAbandon(playerIndex)
      replay.masks[playerIndex] = 0
      replay.pressedMasks[playerIndex] = 0
      replay.lastAppliedMasks[playerIndex] = 0
    of lrRebind:
      if sim.phase != Lobby:
        raise newException(ReplayError,
          "Replay input-seat rebind occurs outside the lobby")
      sim.clearReplayAbandon(playerIndex)
    inc replay.lifecycleIndex

  # MAP VOTE: re-apply recorded `0x17` kind-0 casts at their recorded tick,
  # BEFORE this tick's step — mirroring the live server, which drains
  # pending casts (stamped tickTime(sim.tickCount)) in the same pre-step
  # block that drains lobby chat. The record's `seat` field is the STABLE
  # configured slot (the voteSeats rekey key), so re-application lands on
  # the same seat regardless of any roster compaction since. kind-1
  # (resolved) records are skipped: resolveVote re-derives the identical
  # resolution (and winner-map install) from the re-applied casts + the
  # config seed, on the same tick — early resolution included.
  while replay.ballotIndex < replay.ballots.len and
      replay.ballots[replay.ballotIndex].replayTimeMs <= time:
    let record = replay.ballots[replay.ballotIndex]
    if record.kind == brkCast:
      sim.applyReplayBallotCast(
        int(record.seat), record.option, record.ordinal)
    inc replay.ballotIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    if input.isDirectAimRecord():
      # Intercepted BEFORE ensureReplayPlayer: the flagged byte is not a roster
      # index, and growing the mask arrays to 128 rows on it would be silent
      # corruption rather than a loud failure.
      let aimPlayer = input.directAimRecordPlayer()
      while replay.directAim.len <= aimPlayer:
        replay.directAim.add(-1)
      replay.directAim[aimPlayer] = input.directAimRecordBrads()
      inc replay.inputIndex
      continue
    replay.ensureReplayPlayer(int(input.player))
    replay.pressedMasks[int(input.player)] =
      replay.pressedMasks[int(input.player)] or
        (input.keys and not replay.masks[int(input.player)])
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    if chat.isHandoffDeclarationRecord():
      # THE SWAP, handoff edition, at the identical tick boundary the live
      # server made it: the server's shell hook declares (and records) in
      # the same pre-step block that hands the play seats' masks over, so
      # the declaration is live for exactly the same first channel tick on
      # both sides. Checked BEFORE isPolicyPageRecord: the handoff byte
      # carries both high bits, and the page predicate excludes it by the
      # second one.
      #
      # A refusal here is fatal on purpose, on writePolicyPageFlash's own
      # argument: declareHandoff's acceptance rule reads only the armed
      # gate, the phase, the seat's upright life and its duo partner — all
      # of which the recording already satisfied — so a `false` means the
      # replay and the build disagree about what the channel even is (a
      # declaration under a dark giveItem config, a seat with no partner
      # on this roster). Swallowing it would resume the match without the
      # consent record and let the hash chain report the divergence at the
      # transfer tick, a place that explains nothing.
      if not sim.declareHandoff(
          chat.handoffRecordPlayer(), chat.decodeHandoffDeclarationRecord()):
        raise newException(
          ReplayError,
          "Replay handoff declaration was refused at tick " & $sim.tickCount
        )
    elif chat.isPolicyPageRecord():
      # THE SWAP, on playback, at the identical tick boundary the live
      # server made it: the server drains its pending pages inside the same
      # pre-step block that drains chat (server.nim), stamping the record
      # with this same `tickTime(sim.tickCount)`, so the page is live for
      # exactly the same first tick on both sides.
      #
      # A refusal here is fatal on purpose. applyPolicyPage's acceptance
      # rule reads only the armed gate, the roster size and the page length,
      # all three of which the recording already satisfied — so a `false`
      # means the replay and the build disagree about what the channel even
      # is (a reflash record under a gate-off config, a seat that is not on
      # the roster). Swallowing that would resume the match on the WRONG
      # strategy and let the hash chain report the divergence a tick later,
      # at a place that explains nothing.
      let page = chat.decodePolicyPageRecord()
      if not sim.applyPolicyPage(chat.policyPageRecordPlayer(), page):
        raise newException(
          ReplayError,
          "Replay policy page flash was refused at tick " & $sim.tickCount
        )
    elif chat.isPactDeclarationRecord():
      # THE SWAP, pact-declaration edition, at the identical tick boundary
      # the live server made it: the server's shell hook declares (and
      # records) in the same pre-step block that hands the play seats'
      # masks over, so the declaration is live for exactly the same first
      # channel tick on both sides. Checked BEFORE the reflash/handoff
      # predicates would even matter here: a pact record carries neither
      # of their bit patterns, so ordering against them is not load-
      # bearing, only against the plain-shout fallthrough below.
      #
      # A refusal here is fatal on purpose, on writeHandoffDeclaration's
      # own argument: declarePactPartners's acceptance rule reads only the
      # phase and the seat's upright life — both of which the recording
      # already satisfied — so a `false` means the replay and the build
      # disagree about what the channel even is. Swallowing it would
      # resume the match without the declaration and let the hash chain
      # report the divergence at the mutuality tick, a place that explains
      # nothing.
      let partners = chat.decodePactDeclarationRecord()
      if not sim.declarePactPartners(chat.pactDeclarationRecordPlayer(),
          partners):
        raise newException(
          ReplayError,
          "Replay pact declaration was refused at tick " & $sim.tickCount
        )
    # Paintball CONTROL records (register / directive / fallback /
    # budget_guard / result) ride the chat stream as JSON objects and are
    # NOT shouts: the live server never applied them as shouts either, so
    # applying them here would move the hash chain. Everything else is a
    # cog's real in-game shout, hashed state both sides hear. Classic games
    # keep the unconditional apply: every recorded chat there IS a shout.
    # Checked AFTER isPolicyPageRecord: a reflash record is distinguished by
    # its `player` byte's high bit, not by message content, so the two gates
    # never collide.
    elif sim.config.numAgents > 0 and
        chat.message.len > 0 and chat.message[0] == '{':
      sim.pushFeedDirective(chat.message)
    else:
      sim.applyShout(int(chat.player), chat.message)
    inc replay.chatIndex

  # Leaves are consumed first, so equal-time debug records use shifted indices.
  while replay.debugSpriteIndex < replay.data.debugSprites.len and
      replay.data.debugSprites[replay.debugSpriteIndex].time <= time:
    let debugSprite = replay.data.debugSprites[replay.debugSpriteIndex]
    replay.ensureReplayPlayer(int(debugSprite.player))
    # Crafted replay records are skipped so one malformed packet is non-fatal.
    try:
      replay.overlays[int(debugSprite.player)].applyDebugSpritePacket(
        debugSprite.packet
      )
    except SpriteProtocolError:
      discard
    inc replay.debugSpriteIndex

proc replayPrevInputs(
  replay: var ReplayPlayer,
  playerCount: int
): seq[InputState] =
  ## Builds previous replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    let mask =
      replay.lastAppliedMasks[playerIndex] and
        not replay.pressedMasks[playerIndex]
    result[playerIndex] = decodeInputMask(mask)

proc replayInputs(
  replay: var ReplayPlayer,
  playerCount: int
): seq[InputState] =
  ## Builds replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    let mask = replay.masks[playerIndex] or replay.pressedMasks[playerIndex]
    result[playerIndex] = decodeInputMask(mask)
    replay.lastAppliedMasks[playerIndex] = mask

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message =
      "Replay hash mismatch at tick " & $sim.tickCount &
        "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc advanceReplayGame(sim: var SimServer) =
  ## The playback mirror of the server's regime switch (its named edit #4).
  ## `gameIndex`, `regime`, `gameHill` and `gameRegimes` are written only by
  ## the live loop, and none of them is in `gameHash` — so without this the
  ## readouts a spectator reads off a replay ("GAME 1/2 · RESIDENT") stay
  ## frozen on game 1 for the whole episode and the visitor half is never
  ## announced. Archiving here is also what lets the momentum series stay
  ## cumulative across the two games.
  if sim.config.numAgents <= 0 or sim.config.regimes.len == 0:
    return
  sim.gameHill.add(sim.hillTicks)
  sim.gameRegimes.add(sim.regime)
  sim.gameIndex = sim.gameHill.len
  sim.regime = sim.config.regimes[
    min(sim.gameIndex, sim.config.regimes.high)]

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick.
  replay.clearReplayPressedMasks()
  replay.applyReplayEvents(sim)
  let prevInputs = replay.replayPrevInputs(sim.players.len)
  let inputs = replay.replayInputs(sim.players.len)
  # The playback mirror of the live server's pre-tick aim write: bearing first,
  # then the tick that reads it. Same order on both sides, or a human's replay
  # would fire one tick behind its own turret.
  for cog in 0 ..< min(replay.directAim.len, sim.players.len):
    if replay.directAim[cog] >= 0:
      sim.applyDirectAim(cog, replay.directAim[cog])
  let phaseBefore = sim.phase
  sim.step(inputs, prevInputs)
  if phaseBefore != GameOver and sim.phase == GameOver:
    sim.advanceReplayGame()
  replay.clearReplayPressedMasks()
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int],
  startTick, maxTick: int
): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping LullLeadTicks of context on both sides and dropping spans shorter
  ## than MinLullTicks.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len:
        beatTicks[i]
      else:
        # The stretch after the final beat runs lead-free to the end: there is
        # no upcoming action that needs a lead-in.
        maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanLeadMetric*(sim: SimServer): string =
  ## What `scanTeamLead` is counting, so the lane can NAME itself instead of
  ## wearing a hardcoded caption. Both metrics are cumulative and never
  ## negative, so one renderer draws both — but they are not the same number
  ## and the band must not claim otherwise. (Before this existed the KotH lane
  ## plotted hill ticks under a caption reading "LIVES LEAD".)
  if sim.config.hill: "hill" else: "glory"

proc scanTeamOut(sim: SimServer): seq[bool] =
  ## Whether each team is out, in Team order: no lives banked and nobody
  ## still standing. `teamLivesRemaining` counts an alive player's current
  ## life, so zero here really is "cannot come back".
  ##
  ## NOT sufficient on its own: it is also 0 during the lobby, before anyone
  ## has spawned. Latching on it directly marked all sixteen teams eliminated
  ## at tick 1. The caller only latches for a team it has already seen alive.
  for team in sim.teams():
    result.add(sim.teamLivesRemaining(team) == 0)

proc scanTeamLead(sim: SimServer): seq[int] =
  ## One momentum value per team, in Team order — the metric the scrubber's
  ## lane plots. Cumulative in both modes: a climb, never a tug of war.
  ##
  ## Classic: the team's GLORY. Glory is the score, so glory is the momentum
  ## read. This used to be remaining lives, which is a resource the scorebug
  ## already prints in its own right — a lane of it answers "who still has an
  ## army", not "who is winning". `sim.teamGlory` accumulates across the games
  ## of an episode (roster.nim), so the curve spans the whole watch.
  ##
  ## KotH (hill on): the CUMULATIVE hill-tick count — the archived totals of
  ## the games already finished plus this game's running count. With
  ## `lives: 12` a paintball series of lives is near-flat and shows tag
  ## attrition, not hill momentum, and the hill-tick difference over the
  ## whole episode is the thing a KotH spectator is watching. Kept as-is:
  ## that is a deliberate mode ruling with its own fixture test
  ## (tests/test_pb_replay.nim), not a leftover of the lives era.
  if sim.config.hill:
    for team in sim.teams():
      var total = sim.hillTicks[team]
      for archived in sim.gameHill:
        total += archived[team]
      result.add(total)
  else:
    for team in sim.teams():
      result.add(gloryReportInt(sim.teamGlory[team]))

proc scanTeamHeat(sim: SimServer): seq[int] =
  ## One HEAT MULTIPLIER value per team, in Team order — PARALLEL to
  ## `scanTeamLead` (feeds `heatSeries`, never `leadSeries`; see that
  ## field's own doc comment). This is the exact `heatMult(embers)` value
  ## `mintGlory` (glory.nim) is already multiplying every deed by — 1, 2, 4
  ## or 8 — read straight off `sim.heatEmbers`, the same live state the
  ## scorebug's per-team "heat" key exposes (broadcast.nim's teamStateJson).
  for team in sim.teams():
    result.add(heatMult(sim.heatEmbers[team]))

proc scanSeriesPoint(tick: int, lead: seq[int]): seq[int] =
  ## One [tick, leadPerTeam…] change-point of the momentum series.
  result = @[tick]
  result.add(lead)

proc scanComplete*(replay: ReplayPlayer): bool =
  ## True once the precompute walk has finished: leadSeries, beatEvents and
  ## lullSpans hold the whole match and the lead chrome may ship. Until then
  ## keyframes only cover the walked prefix (seeks past it re-simulate
  ## forward, exactly like seeking between keyframes) and skip-lulls has no
  ## spans to boost through.
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks,
  portable = false
) =
  ## Starts the whole-match precompute walk: seek keyframes, the per-team
  ## lives change-point series (momentum graph), the flag-story beats, and
  ## the beat ticks the lull map derives from. The walk advances via
  ## advanceReplayScan — a bounded slice per presentation frame in the
  ## hosted viewer, or all at once via buildReplayKeyframes. When the replay
  ## file embedded its own keyframes (spec 0157) they already cover the whole
  ## match, so the walk keeps them and only derives the chrome series.
  if not replay.embeddedKeyframes:
    replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.heatSeries = @[]
  replay.leadOutTicks = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.achievementBadges = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1), portable: portable)
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.lifecycle = replay.lifecycle
  scan.builder.ballots = replay.ballots
  scan.builder.playSeats = replay.playSeats
  scan.builder.lifecyclePlayback = initLifecyclePlayback(replay.playSeats)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  if not replay.embeddedKeyframes:
    replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim, portable))
  scan.lastLead = scanTeamLead(scan.sim)
  replay.leadMetric = scanLeadMetric(scan.sim)
  scan.lastHeat = scanTeamHeat(scan.sim)
  # -1 until seen out; the lobby has everyone alive, so this starts all -1
  # even on a recording that opens mid-carnage.
  for _ in scan.sim.teams():
    replay.leadOutTicks.add(-1)
    scan.leadSeenAlive.add(false)
  replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  replay.heatSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastHeat))
  # Beat ticks for the lull map are derived by the SAME tracker the broadcast
  # channel uses, so "nothing happens here" agrees with the story the kill
  # feed and banners tell. Respawns are excluded: they trail kills on a fixed
  # timer and are not drama worth slowing down for.
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  # -1 until the match leaves the lobby: the first tick the game is Playing is
  # where a spectator's watch should begin (everything before is warmup).
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  # An empty recording has nothing to walk: finalize immediately instead of
  # spending a frame in a fictitious in-flight state.
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` simulation ticks; when
  ## the walk stops — at the recording's final hash, earlier if the
  ## builder's playback ends (the recorded match is over), or at a malformed
  ## record — it derives the lull spans from whatever prefix it covered and
  ## marks the lead chrome ready (scanComplete). No-op once finished.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      # A malformed record (bad join/leave, or a hash mismatch under
      # mismatchQuit) would otherwise re-raise from this same tick on EVERY
      # subsequent frame — the walk's cursor cannot advance past it. With
      # mismatchQuit the raise is the diagnostic mode's whole point, so it
      # propagates; otherwise finalize on the walked prefix and let the
      # DISPLAY path surface the same defect loudly when playback reaches
      # that tick.
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ",
        error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    # Record the per-team hill-tick change-points across the full episode so
    # the momentum graph draws its whole-timeline shape up front
    # (deterministic replay: a tick's hill counts are fixed). Only points
    # where some team's count changes are stored to keep the series compact.
    let lead = scanTeamLead(scan.sim)
    if lead != scan.lastLead:
      replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, lead))
      scan.lastLead = lead
    # HEAT ON THE WIRE: same change-point compaction, PARALLEL series (see
    # `heatSeries`'s own doc comment) -- never merged into `leadSeries`.
    let heat = scanTeamHeat(scan.sim)
    if heat != scan.lastHeat:
      replay.heatSeries.add(scanSeriesPoint(scan.sim.tickCount, heat))
      scan.lastHeat = heat
    # FIRST tick out, latched -- but only for a team that has actually been
    # alive. "No lives and nobody up" is equally true of the lobby, before
    # anyone spawns, so an ungated latch marks every team eliminated on tick 1
    # (measured: outTicks @[1, 1, 1, …] across all sixteen).
    for i, isOut in scanTeamOut(scan.sim):
      if i >= replay.leadOutTicks.len:
        continue
      if not isOut:
        scan.leadSeenAlive[i] = true
      elif scan.leadSeenAlive[i] and replay.leadOutTicks[i] < 0:
        replay.leadOutTicks[i] = scan.sim.tickCount
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      # The objective story + verdict for the scrubber's up-front timeline.
      # Kills stay out: dozens of same-looking ticks would bury the beats.
      # Classic replays keep the flag beats; KotH replays get the hill beats.
      let scrubberBeats =
        if scan.sim.config.hill:
          @["gamestart", "hillflip", "tagout", "gameover"]
        else:
          @["steal", "return", "capture", "gameover"]
      if event["k"].getStr() in scrubberBeats:
        replay.beatEvents.add(event)
    for event in stepBeats:
      if event["k"].getStr() != "respawn":
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if not replay.embeddedKeyframes and (
        scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick):
      replay.keyframes.add(
        scan.builder.saveReplayKeyframe(scan.sim, scan.portable))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return                              # more slices to come.
  # Anchor the final tick so the client can hold the last value to the end.
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(
      scanSeriesPoint(scan.sim.tickCount, scan.lastLead))
  if replay.heatSeries.len == 0 or
      replay.heatSeries[^1][0] != scan.sim.tickCount:
    replay.heatSeries.add(
      scanSeriesPoint(scan.sim.tickCount, scan.lastHeat))
  replay.lullSpans = buildLullSpans(
    scan.beatTicks,
    replay.replayStartTick(),
    scan.maxTick
  )
  # The walked sim has crossed the recorded match's end, so finishGame's
  # achievement evaluation (and its focus cogs) already ran on it; export the
  # pairs by SEAT SLOT (joinOrder — the id the viewer's pov select speaks).
  replay.achievementBadges = newJArray()
  for focus in scan.sim.achievementFocus:
    if focus.playerIndex < 0 or focus.playerIndex >= scan.sim.players.len:
      continue
    replay.achievementBadges.add %*{
      "id": focus.id,
      "s": scan.sim.players[focus.playerIndex].joinOrder,
      "n": scan.sim.players[focus.playerIndex].address
    }
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## Deterministic scan slice per presentation frame (frame-counted, no
  ## clock reads — machine speed must not change what any frame contains).
  ## Big boards OR big rosters step ~10x slower than the classic arena,
  ## so their slice is smaller to protect the frame budget; small boards
  ## finish their walk within a couple of seconds of playback.
  if sim.gameMap.width * sim.gameMap.height > 2_000_000 or
      sim.players.len > 16: 24
  else: 96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks,
  portable = false
) =
  ## Runs the whole precompute walk synchronously (tests and offline tools;
  ## the hosted viewer advances it a slice per frame instead — see
  ## advanceReplayScan).
  replay.initReplayScan(initialSim, interval, portable)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  ## Returns true when one tick sits inside a precomputed lull span.
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## Returns how many ticks playback may advance this frame from one tick:
  ## the chosen speed, boosted inside a lull while skip-lulls is on.
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)]
    )
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(
  replay: var ReplayPlayer,
  sim: var SimServer
): bool =
  ## Walks a pending seek up to SeekTicksPerFrame ticks closer to its target.
  ## Returns true when it moved the sim, so the caller can resync its
  ## broadcast tracker. Clears the pending seek once the target (or the end of
  ## the recording) is reached.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Starts a BOUNDED seek: land on the newest keyframe at or before `tick`
  ## (instant) and record the target. Convergence happens SeekTicksPerFrame
  ## at a time from advanceReplayPlayback — which every host calls in the same
  ## frame — so a seek inside the keyframed region still lands on this frame
  ## while a seek past the precompute walk's prefix costs one bounded slice
  ## per frame instead of stalling the viewer. The keyframe restore alone
  ## already moves the clock, which is what makes a scrubber click visible in
  ## the very next frame. Call convergeSeek in a loop for a synchronous seek.
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Seeks replay playback and pauses on the target tick. The seek itself is
  ## bounded per frame (beginSeek); playback stays paused while it converges.
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## Applies one live playback speed command.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, 0)
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '3':
    speedIndex = 2
  of '4':
    speedIndex = 3
  of '8':
    speedIndex = 4
  of '6':
    speedIndex = 5
  else:
    discard

proc applyReplayCommand*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  ## Applies one global viewer replay command.
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  ## Cancels the end-of-replay hold. Callers cancel after any manual
  ## seek/jump — a scrub off the final frame leaves the end segment.
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  ## Whole seconds left in the end-of-replay hold (0 when not holding), for
  ## the broadcast chrome's "replaying in N" countdown.
  if replay.endHoldFrames <= 0:
    0
  else:
    (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame (call once per TargetFps frame,
  ## after replay seeks/commands have been applied). Steps the sim
  ## `replaySpeed` ticks while playing; `onStep` runs after every sim tick
  ## (beat-event derivation), `onJump` after any playback jump (tracker
  ## resync). Shared by the native replay server and the static WASM viewer
  ## so both tell the same story at the end of a match: a LOOPING replay does
  ## NOT restart the moment playback stops — the final game-over frame (the
  ## end segment: winner, win condition, stats) holds for
  ## ReplayEndHoldSeconds of real time first. A play command during the hold
  ## skips the wait and loops immediately.
  # A seek the viewer asked for OWNS the frame. Converging it takes priority
  # over the background precompute walk (a scan slice plus a seek slice in one
  # frame is what made the hosted 50 % scrub read stale) and over playback:
  # the seek is paused by definition, and the next frame either converges
  # further or resumes.
  if replay.pendingSeekTick >= 0:
    if replay.convergeSeek(sim):
      onJump()
    return
  # Advance the background precompute walk a bounded slice per frame (no-op
  # once complete). Runs while paused too: a paused frame has budget to
  # spare, and finishing the walk is what unlocks the momentum graph, beat
  # markers and skip-lulls.
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    # Play pressed during the end hold: skip the wait and loop now.
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    # The step budget is re-read every tick: inside a lull it is boosted, and
    # the moment stepping crosses back into action it drops to the plain
    # speed, so a fast-forward never overshoots a beat's lead-in.
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      # Playback just reached the end: begin the end-segment hold.
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()


proc playbackSpeed*(speedIndex: int): int =
  ## Returns the live playback speed for an index.
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

proc walkEmbeddedKeyframes*(
  data: CtfReplayData,
  interval = DefaultEmbeddedKeyframeTicks
): EmbeddedKeyframeSet =
  ## Walks one recorded match from tick 0 and returns its portable keyframes.
  ## Assets resolve relative to the working directory (run from the repo
  ## root or the image's /workspace, like every replay host).
  var stripped = data
  stripped.keyframeBlob = ""
  var config = defaultGameConfig()
  config.update(stripped.replay.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(stripped)
  player.buildReplayKeyframes(sim, max(interval, 1), portable = true)
  EmbeddedKeyframeSet(
    version: EmbeddedKeyframeVersion,
    interval: max(interval, 1),
    gameVersion: GameVersion,
    simStamp: ctfSimSourcesStamp,
    keyframes: player.keyframes)

proc embedReplayKeyframes*(
  bytes: string,
  interval = DefaultEmbeddedKeyframeTicks
): string =
  ## Spec 0157: returns the replay (uncompressed) with a keyframe trailer
  ## built by walking it once from tick 0. The record stream is unchanged;
  ## an existing trailer is replaced. Because the keyframes come from the
  ## SAME deterministic walk the viewer would run, restoring one is
  ## gameHash-identical to walking there from tick 0.
  let body = replayRecordBytes(bytes, CtfReplaySpec)
  let data = parseCtfReplayBytesFull(body)
  appendKeyframeTrailer(
    body, encodeEmbeddedKeyframes(walkEmbeddedKeyframes(data, interval)))

proc embedReplayKeyframesFile*(
  path: string,
  interval = DefaultEmbeddedKeyframeTicks
) =
  ## Rewrites one replay file in place (via a temp file + rename) with
  ## embedded keyframes.
  let embedded = embedReplayKeyframes(readFile(path), interval)
  let tmp = path & ".keyframes.tmp"
  writeFile(tmp, embedded)
  moveFile(tmp, path)
