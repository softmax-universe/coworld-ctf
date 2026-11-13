## The shell's play-seat episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## The body layer supplies belief, navigation, and action
## execution. This module owns only the server-side lifecycle,
## default-order installation, mask handoff, annotations, and timing split.

import std/[json, math, monotimes, options, os, sequtils, strformat, strutils, times]
import bitworld/[profile, spriteprotocol]
import ../ctf/sim_types
import body_map
import body_nav
import reflexes
import replay_records
import types
import outbound
import standing_order
import body
# `view` needs no runtime (std, sim_types, body, body_map, canonical_fast,
# policy_encoding, types only) and server.nim imports it unconditionally; keeping
# it under the runtime guard once hid PlayContextRosterRow from the stub
# shape (CI run 33597295995).
import view

const ShellRuntimeAvailable* =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0

when ShellRuntimeAvailable:
  import binary_view, call_validation, canonical, compile_plane, emit_validator,
    guards, instance, ladder, runtime

type
  ShellInventory* = object
    wasmtime*: bool
    uploads*: bool
    calls*: bool
    stores*: bool
    ladder*: bool

  ShellSeatFrame* = object
    ## One coherent tick-boundary handoff. bodyInputs is the body's real
    ## belief surface; defaultFallbacks carries only the shell facts not yet
    ## exposed by body accessors.
    seat*: uint8
    playerIndex*: int
    present*: bool
    playing*: bool
    alive*: bool
    aliveTeams*: int
    motionScale*: int
    velocity*: int
    bodyInputs*: BodyTickInputs
    defaultFallbacks*: BrDefaultFallbacks

  ShellMask* = object
    seat*: uint8
    playerIndex*: int
    input*: InputState

  ShellInstall* = object
    tick*: uint32
    seat*: uint8
    rule*: string
    provenance*: string
    bytesHash*: string
    bytes*: string

  ShellModuleStatus* = object
    seat*: int
    uploadId*: uint64
    terminal*: string
    status*: StatusEntry
    statusBytes*: string

  ShellEntryIdentity* = object
    seat*: int
    entryId*: string
    play*: string

  ShellLadderStatus* = object
    seat*: int
    entryId*: string
    status*: StatusEntry
    statusBytes*: string

  ShellCallReplayIdentity* = object
    seat*: uint8
    callNumber*: uint64
    ladderBytes*: string
    entries*: seq[PlayCallEntryIdentity]
    contentSha256*: string
      ## Codec-derived identity hash with replayTimeMs=0. Lane B owns real
      ## replay time and must call toPlayCallRecord(identity, replayTimeMs)
      ## for the queued record's time-stamped content hash.

  ShellAdmissionResult* = object
    accepted*: bool
    reason*: string
    status*: StatusEntry
    statusBytes*: string

  ShellCallResult* = object
    accepted*: bool
    reason*: string
    path*: string
    callNumber*: uint64
    status*: StatusEntry
    statusBytes*: string
    pendingRetunes*: seq[ShellEntryIdentity]
    replayIdentity*: Option[ShellCallReplayIdentity]

  DemoPlayConfigResult* = object
    lines*: seq[string]
    callIdentities*: seq[ShellCallReplayIdentity]

  ShellNavSummary* = object
    ## Per-tick follower census over active, alive play seats; the server
    ## prints it as SHELL_NAV so plan-budget events can be joined by
    ## tick to what the followers were doing.
    pendingPlans*: int            ## seats whose cold plan is still computing
    stalePathSeats*: seq[uint8]   ## walking an older route while a plan computes
    noPathSeats*: seq[uint8]      ## navigate order, not arrived, no route loaded

  ShellCombatSummary* = object
    ## Per-tick weapon-path census over active, alive play seats; the server
    ## prints it as SHELL_COMBAT. The seat lists name the outcomes an
    ## operator most needs to chase: fresh tracks with nothing shootable and a
    ## held target not yet fired on.
    counts*: array[CombatOutcome, int]
    noneShootableSeats*: seq[uint8]
    aligningSeats*: seq[uint8]

  ShellHandoff* = object
    ## §4.1 amendment: one seat's STANDING give-item declaration this tick —
    ## the Intent's `handoff` field lifted off the installed standing order
    ## ("" = no declaration wanted). The episode never touches the sim: the
    ## server hook compares this against the sim's declared state and calls
    ## the sim.declareHandoff consent seam (recording exactly what the sim
    ## accepted), the same division of labor as the mask handoff above it.
    seat*: uint8
    playerIndex*: int
    item*: string

  ShellPactDeclaration* = object
    ## ALLIANCE (engine registration rewire, GameVersion 56): one seat's
    ## CURRENT `pact` play declaration this tick — the partner TEAMS its
    ## currently active `pact` overlay call names, empty when no `pact`
    ## entry is active for this seat this tick (an explicit clear). Lifted
    ## off the call's own static `partners` param
    ## (resolvePactPartnerTeams, emit_validator.nim) via the ladder's
    ## entrySnapshots, never off the emitted combat_policy — betrayal-
    ## driven noShoot/protect narrowing is the play's own body-level
    ## business and must not feed the registry (owner ruling: never
    ## enforced). Same division of labor as ShellHandoff above: the
    ## episode never touches the sim, the server hook compares this
    ## against the sim's own declared state and calls the
    ## sim.declarePactPartners consent seam.
    seat*: uint8
    playerIndex*: int
    partners*: seq[Team]

  ShellStage* = enum
    ssCompilePlane
    ssLifecycle
    ssDefault
    ssReflex
    ssContext
    ssView
    ssGuard
    ssLadder
    ssStanding
    ssBelief
    ssFollower
    ssWeapon
    ssDanger
    ssPlanning

  ShellTickResult* = object
    masks*: seq[ShellMask]
    handoffs*: seq[ShellHandoff]
    pactDeclarations*: seq[ShellPactDeclaration]
    annotations*: seq[ShellAnnotation]
    installs*: seq[ShellInstall]
    moduleStatuses*: seq[ShellModuleStatus]
    ladderStatuses*: seq[ShellLadderStatus]
    playLogLines*: seq[string]
    retuned*: seq[ShellEntryIdentity]
    planBudget*: seq[PlanBudgetEvent]
    nav*: ShellNavSummary
    combat*: ShellCombatSummary
    bodyNanoseconds*: int64
    runtimeNanoseconds*: int64
    stageNanoseconds*: array[ShellStage, int64]

  ViewSource* = proc(seatIndex: int; tick: uint32): string {.closure.}

  DemoPlayConfig* = object
    modulePath*: string
    playName*: string
    paramsBytes*: string
    seats*: seq[int]
    uploadIdBase*: uint64
    proposalIdBase*: uint64
    originGeneration*: uint64

  ShellViewFrameSlot = object
    present: bool
    frame: ShellSeatFrame

  PlayLogWindowState = object
    window: uint32
    admitted: int
    dropped: int

  ShellRuntimeState = ref object
    frames: seq[ShellViewFrameSlot]
    selfPositions: seq[BodyPoint]
    reflexStates: seq[ReflexSeatState]
    playLogWindows: seq[PlayLogWindowState]
    lastCompileTick: Option[uint32]

  ShellSeatState* = object
    seat*: uint8
    active*: bool
    eliminated*: bool
    everActivated*: bool
    body*: SeatBody
    standing*: StandingOrderState

  ShellEpisode* = object
    enabled*: bool
    brMode*: bool
    rosterSize*: int
    map*: BodyMap
    nav*: BodyNavSystem
    seats*: seq[ShellSeatState]
    bodyActivations: int
    viewSource*: ViewSource
    when ShellRuntimeAvailable:
      mapName: string
      gunRange: int
      viewInterval: int
      contextRoster: seq[PlayContextRosterRow]
      runtimeState: ShellRuntimeState
      engine: RuntimeEngine
      compilePlane: CompilePlane
      ladder: LadderDriver
      bindings: seq[LadderBinding]

proc shellInventory*(): ShellInventory =
  ## Runtime inventory is compile-time visible so ordinary server builds that
  ## lack the Wasmtime C API remain on the zero-guest shell path.
  when ShellRuntimeAvailable:
    ShellInventory(wasmtime: true, uploads: true, calls: true,
      stores: true, ladder: true)
  else:
    ShellInventory()

proc bodyActivationCount*(episode: ShellEpisode): int =
  ## Test/readback surface for the server invariant that playback consumes
  ## recorded masks and never constructs SeatBody instances.
  episode.bodyActivations

proc frameForSeat(episode: ShellEpisode; seatIndex: int):
    Option[ShellSeatFrame] =
  when ShellRuntimeAvailable:
    if episode.runtimeState != nil and seatIndex >= 0 and
        seatIndex < episode.runtimeState.frames.len and
        episode.runtimeState.frames[seatIndex].present:
      return some(episode.runtimeState.frames[seatIndex].frame)
  none(ShellSeatFrame)

const MaxPlayZoneTicksToShrink = high(int32).int

proc playZoneTicksToShrink(value: int): int =
  ## The sim uses high(int) div 4 as the "no more zone phases" sentinel, but
  ## the play view is an int32 ABI. Preserve the sentinel's meaning by
  ## saturating it to the largest representable future tick count; plays testing
  ## "ticks_to_shrink <= enterLead" still do not trigger at the final phase.
  if value < 0:
    0
  elif value > MaxPlayZoneTicksToShrink:
    MaxPlayZoneTicksToShrink
  else:
    value

when ShellRuntimeAvailable:
  proc shellPlayViewSource(episode: ShellEpisode; seatIndex: int;
                                tick: uint32): Option[PlayViewSource] =
    ## The one fogged per-seat view source. Both encoders below MUST feed
    ## from here so the guest and the socket can never observe different
    ## worlds for one seat at one tick.
    let frame = episode.frameForSeat(seatIndex)
    if frame.isNone:
      return none(PlayViewSource)
    for state in episode.seats:
      if state.active and state.seat.int == seatIndex:
        let fallbacks = frame.get.defaultFallbacks
        return some(playViewSourceFromBody(
          state.body,
          tick,
          if episode.brMode: gmBr else: gmCtf,
          frame.get.aliveTeams,
          some(PlayZone(
            phase: fallbacks.zonePhase,
            current: PlayRect(x: fallbacks.currentZone.x,
              y: fallbacks.currentZone.y, w: fallbacks.currentZone.w,
              h: fallbacks.currentZone.h),
            next: some(PlayRect(x: fallbacks.nextZone.x,
              y: fallbacks.nextZone.y, w: fallbacks.nextZone.w,
              h: fallbacks.nextZone.h)),
            ticksToShrink:
              playZoneTicksToShrink(fallbacks.ticksToNextShrink),
            dps: fallbacks.zoneDps))))
    none(PlayViewSource)

proc shellViewBytes*(episode: ShellEpisode; seatIndex: int;
                          tick: uint32): string =
  ## The GUEST's copy: the fixed-layout PV1 binary frame (the 2026-08-31
  ## lane-C ruling — a wasm play reads fields as aligned loads, not JSON).
  when ShellRuntimeAvailable:
    let source = episode.shellPlayViewSource(seatIndex, tick)
    if source.isNone:
      return "{}"
    buildBinaryPlayView(source.get)
  else:
    discard episode
    discard seatIndex
    discard tick
    "{}"

proc shellSocketViewBytes*(episode: ShellEpisode; seatIndex: int;
                                tick: uint32): string =
  ## The SOCKET's copy of the same view: JSON, per the ratified 0xB1 wire
  ## contract ("u8[viewLen] view JSON" — play-calling shell design §3.2 wire
  ## table; play_view.schema.json: "the encoded payload is always valid
  ## JSON") and the binary-frame ruling's own boundary ("the play's copy
  ## ... becomes a fixed-layout binary frame; JSON stays for the socket and
  ## replay copies"). Wiring the PV1 binary frame here instead is what every
  ## conforming policy client (starter_harness/wire.py: json.loads on the
  ## view payload) crashes on at the round's first live view.
  when ShellRuntimeAvailable:
    let source = episode.shellPlayViewSource(seatIndex, tick)
    if source.isNone:
      return "{}"
    buildPlayView(source.get)
  else:
    discard episode
    discard seatIndex
    discard tick
    "{}"

proc initShellEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange,
    teams: openArray[Team] = [],
    mapName = "",
    viewInterval = ViewIntervalTicksDefault,
    names: openArray[string] = []): ShellEpisode =
  ## `names` are the seats' display names in seat order (the closed
  ## roster's players[].name); empty means the context carries none.
  if teams.len > 0 and teams.len != controls.len:
    raise newException(ValueError,
      "shell team/control facts must have the same length")
  result.brMode = brMode
  result.rosterSize = controls.len
  result.map = map
  if not season2Shell:
    return
  if map == nil:
    raise newException(ValueError, "the shell episode requires a BodyMap")
  result.nav = newBodyNavSystem(map, controls.len, liveGunRangePx)
  when ShellRuntimeAvailable:
    result.mapName = mapName
    result.gunRange = liveGunRangePx
    result.viewInterval = viewInterval
    if teams.len > 0:
      result.contextRoster = playContextRosterRows(controls, teams, names)
    result.runtimeState = ShellRuntimeState(
      frames: newSeq[ShellViewFrameSlot](controls.len),
      selfPositions: newSeq[BodyPoint](controls.len),
      reflexStates: newSeq[ReflexSeatState](controls.len),
      playLogWindows: newSeq[PlayLogWindowState](controls.len))
  for index, control in controls:
    if control == scPlay:
      result.enabled = true
      result.seats.add(ShellSeatState(seat: uint8(index)))

proc playContextRoster*(episode: ShellEpisode): seq[PlayContextRosterRow] =
  ## The roster every seat's PlayContext carries (seat order), for tests and
  ## diagnostics; empty in the stub shape and until a Season 2 episode with
  ## team facts exists.
  when ShellRuntimeAvailable:
    episode.contextRoster
  else:
    @[]

proc initShellPlaybackEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange): ShellEpisode =
  ## Playback consumes recorded InputState masks; the body path is a live-server
  ## producer only. Even for a shell-on recording, this owner keeps no nav,
  ## seats, or SeatBody instances.
  discard season2Shell
  discard controls
  discard liveGunRangePx
  result.brMode = brMode
  result.rosterSize = controls.len
  result.map = map

proc closeShellEpisode*(episode: var ShellEpisode) =
  ## Drops per-episode runtime ownership. The shell body/nav state is
  ## owned by ordinary object replacement; runtime handles need explicit close.
  when ShellRuntimeAvailable:
    if episode.ladder != nil:
      episode.ladder.close()
      episode.ladder = nil
    if episode.compilePlane != nil:
      episode.compilePlane.close()
      episode.compilePlane = nil
    if episode.engine != nil:
      episode.engine.close()
      episode.engine = nil
    episode.bindings.setLen(0)
    episode.runtimeState = nil

proc resetShellEpisode*(episode: var ShellEpisode,
    season2Shell, brMode: bool, controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange,
    teams: openArray[Team] = [],
    mapName = "",
    viewInterval = ViewIntervalTicksDefault,
    names: openArray[string] = []) =
  ## Full episode replacement boundary for any server-side sim/config
  ## replacement. Fresh bodies re-run the activation safe install instead of
  ## carrying standing orders, nav state, or map-owned goals across matches.
  episode.closeShellEpisode()
  episode = initShellEpisode(season2Shell, brMode, controls, map,
    liveGunRangePx, teams, mapName, viewInterval, names)

proc safeIntent(reason: string): Intent =
  Intent(
    kind: ikHold,
    arriveRadius: 0.0,
    reason: "shell:safe_" & reason)

proc provenanceText(provenance: Provenance): string =
  case provenance.base.kind
  of pbEntry: "entry:" & provenance.base.entryId
  of pbDefault: "default"
  of pbReflex:
    if provenance.base.reflexName.startsWith(ReflexNamePrefix):
      "reflex:" & provenance.base.reflexName[ReflexNamePrefix.len .. ^1]
    else:
      "reflex:" & provenance.base.reflexName

proc bytesHash(bytes: string): string =
  var hash = 14_695_981_039_346_656_037'u64
  for value in bytes:
    hash = (hash xor uint64(value.uint8)) * 1_099_511_628_211'u64
  hash.toHex(16).toLowerAscii

proc installRecord(annotation: ShellAnnotation,
    rule, provenance, bytes: string): ShellInstall =
  ShellInstall(
    tick: annotation.tick,
    seat: annotation.seat,
    rule: rule,
    provenance: provenance,
    bytesHash: bytes.bytesHash,
    bytes: bytes)

proc rawBytes(bytes: string): seq[byte] =
  result = newSeq[byte](bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc canonicalParams(node: JsonNode): string =
  if node == nil:
    return "{}"
  when ShellRuntimeAvailable:
    canonicalJson(node)
  else:
    $node

proc playConfigFromNode(node: JsonNode; repoRoot: string):
    DemoPlayConfig =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "demoPlay must be an object")
  result.modulePath = node{"modulePath"}.getStr("")
  if result.modulePath.len == 0:
    raise newException(ValueError, "demoPlay.modulePath is required")
  if not result.modulePath.isAbsolute:
    result.modulePath = repoRoot / result.modulePath
  result.playName = node{"playName"}.getStr(node{"play"}.getStr(""))
  if result.playName.len == 0:
    raise newException(ValueError, "demoPlay.playName is required")
  result.paramsBytes = canonicalParams(node{"params"})
  result.uploadIdBase = uint64(node{"uploadIdBase"}.getInt(10_000))
  result.proposalIdBase = uint64(node{"proposalIdBase"}.getInt(20_000))
  result.originGeneration = uint64(node{"originGeneration"}.getInt(1))
  let seats = node{"seats"}
  if seats == nil or seats.kind != JArray:
    raise newException(ValueError, "demoPlay.seats must be an array")
  for item in seats:
    if item.kind != JInt:
      raise newException(ValueError, "demoPlay.seats entries must be integers")
    let seat = item.getInt()
    if seat < 0 or seat >= MaxPlayers:
      raise newException(ValueError, "demoPlay.seats entry out of range")
    if seat in result.seats:
      raise newException(ValueError, "demoPlay.seats entry duplicated")
    result.seats.add seat

proc demoPlayNode(configJson: string): JsonNode =
  if configJson.len == 0:
    return nil
  let root = parseJson(configJson)
  root{"demoPlay"}

proc demoPlayConfigRefusal(episode: ShellEpisode;
    config: DemoPlayConfig): Option[string] =
  ## Config validity is independent of whether the Wasmtime runtime was linked.
  ## The compile-time runtime gate decides only whether a valid play can run.
  if not episode.enabled:
    return some("SHELL_PLAY configured=false reason=episode_disabled")
  if config.seats.len == 0:
    return some("SHELL_PLAY configured=false reason=no_seats")
  for seat in config.seats:
    if seat < 0 or seat >= episode.rosterSize:
      raise newException(ValueError,
        "demoPlay.seats entry outside roster")
  none(string)

proc toPlayCallRecord*(identity: ShellCallReplayIdentity;
    replayTimeMs: uint32): PlayCallRecord =
  ## Builds the landed replay record shape from the lane-C accepted-call
  ## identity. The decoder owns `contentSha256`; keep this helper on the codec
  ## path instead of maintaining a parallel hash definition.
  let bytes = PlayCallRecord(
    replayTimeMs: replayTimeMs,
    seat: identity.seat,
    callNumber: identity.callNumber,
    ladderBytes: identity.ladderBytes,
    entries: identity.entries).encodePlayCallRecord()
  bytes.decodePlayCallRecord()

proc withContentSha(identity: ShellCallReplayIdentity):
    ShellCallReplayIdentity =
  result = identity
  result.contentSha256 = identity.toPlayCallRecord(0).contentSha256

when ShellRuntimeAvailable:
  const NativeReflexSubscriptions = [
    ReflexSubscription(kind: rkClearGrenade, callNumber: 0),
    ReflexSubscription(kind: rkClearSpray, callNumber: 0),
    ReflexSubscription(kind: rkZoneEscape, callNumber: 0)]

  proc noGuardContext(): IntentContext =
    ## For seats with no body this tick (absent, dead, not playing). Every
    ## path reads 0.0 / false; a live seat gets playGuardContext instead.
    IntentContext(
      resolveNumber: proc(path: string): float =
        discard path
        0.0,
      resolveBool: proc(path: string): bool =
        discard path
        false)

  proc pointDistancePx(a, b: BodyPoint): float =
    let dx = float(a.x - b.x)
    let dy = float(a.y - b.y)
    sqrt(dx * dx + dy * dy)

  proc rectEdgeDistancePx(point: BodyPoint, rect: MapRect): float =
    ## 0 inside the rect; otherwise the straight-line distance to it.
    let dx = max(max(rect.x - point.x, 0), point.x - (rect.x + rect.w - 1))
    let dy = max(max(rect.y - point.y, 0), point.y - (rect.y + rect.h - 1))
    sqrt(float(dx * dx + dy * dy))

  proc playGuardContext*(body: SeatBody, facts: BrDefaultFacts;
                         brMode, hasZoneSchedule: bool): IntentContext =
    ## The registered guard paths (guards.nim ShellPathRegistry)
    ## resolved from this seat's own fogged body state -- the same facts the
    ## plays read -- so a call's `when` guard evaluates over the live view as
    ## the design promises. Before this, every play seat got noGuardContext()
    ## and a guard like `self.hp_frac < 0.8` was always true.
    ##
    ## Sentinels follow the registry's contract: -1 where "never observed"
    ## (partner.dist, nearest_enemy_dist, weakest_enemy_hp, medkit_dist,
    ## item_dist), 0 for zone_dist when inside. The `intent.*` paths describe
    ## a candidate intent being scored and have no meaning for a ladder
    ## guard; they resolve to 0 / false.
    let selfPos = body.selfState.pos
    var enemyCount = 0
    var nearestEnemy = -1.0
    var weakestEnemy = -1.0
    var partnerInCombat = false
    let partner = facts.partner
    for track in body.tracks:
      if track.isNone:
        continue
      inc enemyCount
      let d = pointDistancePx(selfPos, track.get.pos)
      if nearestEnemy < 0 or d < nearestEnemy:
        nearestEnemy = d
      if track.get.hpKnown.isSome:
        let hp = float(track.get.hpKnown.get)
        if weakestEnemy < 0 or hp < weakestEnemy:
          weakestEnemy = hp
      if partner.isSome and partner.get.alive and
          pointDistancePx(partner.get.pos, track.get.pos) <= 200.0:
        partnerInCombat = true
    var medkitDist = -1.0
    var itemDist = -1.0
    for item in body.items:
      if not item.present:
        continue
      let d = pointDistancePx(selfPos, item.pos)
      if item.kind == bikMedkit:
        if medkitDist < 0 or d < medkitDist:
          medkitDist = d
      elif itemDist < 0 or d < itemDist:
        itemDist = d
    let hasZone = facts.currentZone.w > 0 and facts.currentZone.h > 0
    let zoneDist = if hasZone: rectEdgeDistancePx(selfPos, facts.currentZone)
      else: 0.0
    let inZone = (not hasZone) or zoneDist <= 0.0
    var grenadeTicks = -1
    for hazard in body.hazards.grenades:
      if hazard.coversSelf and hazard.ticksToBlast >= 0:
        if grenadeTicks < 0 or hazard.ticksToBlast < grenadeTicks:
          grenadeTicks = hazard.ticksToBlast
    # Mirror reflexes.nim triggeringSpray / activeImpactCount using the
    # normalized body hazards, including the inclusive impact window.
    var sprayCone = false
    var sprayImpacts = 0
    for hazard in body.hazards.sprays:
      case hazard.kind
      of bshVisibleCone:
        sprayCone = sprayCone or hazard.coversSelf
      of bshAnonymousImpact:
        if facts.tick >= hazard.tick and
            facts.tick - hazard.tick <= ReflexSprayImpactWindowTicks.uint32:
          inc sprayImpacts
    # Mirror reflexes.nim zoneActive's mode gate and episode.nim
    # zoneTicksUntilOutside's half-open rect and saturated shrink delta.
    # Absent schedule/CTF is -1 [SENTINEL], not an imminent escape.
    let zoneTicks = if not brMode or not hasZoneSchedule: -1
      elif selfPos.x < facts.currentZone.x or selfPos.y < facts.currentZone.y or
          selfPos.x >= facts.currentZone.x + facts.currentZone.w or
          selfPos.y >= facts.currentZone.y + facts.currentZone.h: 0
      else: playZoneTicksToShrink(facts.ticksToNextShrink)
    let hpFrac = body.selfState.hpFrac
    let partnerAlive = partner.isSome and partner.get.alive
    let partnerDist = if partner.isSome: pointDistancePx(selfPos, partner.get.pos)
      else: -1.0
    IntentContext(
      resolveNumber: proc(path: string): float =
        case path
        of "self.hp_frac": hpFrac
        of "partner.dist": partnerDist
        of "world.enemy_count": float(enemyCount)
        of "world.nearest_enemy_dist": nearestEnemy
        of "world.weakest_enemy_hp": weakestEnemy
        of "world.zone_dist": zoneDist
        of "world.medkit_dist": medkitDist
        of "world.item_dist": itemDist
        of "world.grenade_ticks_to_blast": float(grenadeTicks)
        of "world.spray_impact_count": float(sprayImpacts)
        of "world.zone_ticks_until_outside": float(zoneTicks)
        of "intent.target_hp", "intent.target_dist": -1.0
        else: 0.0,
      resolveBool: proc(path: string): bool =
        case path
        of "partner.alive": partnerAlive
        of "partner.in_combat": partnerInCombat
        of "world.in_zone": inZone
        of "world.grenade_threat": grenadeTicks >= 0
        of "world.spray_threat": sprayCone or sprayImpacts >= 2
        else: false)

  proc shellContextBytes(episode: ShellEpisode; seatIndex: int;
                              frame: ShellSeatFrame): string =
    if seatIndex < 0 or seatIndex >= episode.contextRoster.len:
      return "{}"
    # binary_view.validateContextSource enforces the binary play_context
    # roster floor of 2..32 rows. One-seat harness episodes cannot encode
    # that context legally, so give guests the empty context instead.
    if episode.contextRoster.len < 2:
      return "{}"
    # 2026-09-05 solo-BR (16x1) support: BR no longer requires a duo partner
    # to exist (the play_context invariant in view.nim/binary_view.nim was
    # relaxed the same day). Solo BR seats now get a real play context with
    # duo_partner omitted, matching what buildPlayContext already tolerates.
    # Duo behavior (partner present) is unchanged. The old bail here
    # unconditionally returned "{}" for any partnerless BR seat -- duo-era
    # code that predates one-seat BR teams.
    var source = PlayContextSource(
      mode: if episode.brMode: gmBr else: gmCtf,
      mapName: episode.mapName,
      mapWidth: if episode.map == nil: 0 else: episode.map.width,
      mapHeight: if episode.map == nil: 0 else: episode.map.height,
      selfSeat: seatIndex,
      selfTeam: episode.contextRoster[seatIndex].team,
      duoPartner:
        if episode.brMode and frame.bodyInputs.partner.isSome:
          some(frame.bodyInputs.partner.get.seat.int)
        else:
          none(int),
      gunRange: episode.gunRange,
      viewInterval: episode.viewInterval)
    source.roster = episode.contextRoster
    buildBinaryPlayContext(source)

  proc ensureLadder(episode: var ShellEpisode) =
    if episode.ladder == nil:
      episode.ladder = newLadderDriver(episode.runtimeState.frames.len,
        ShellPathRegistry, if episode.brMode: gmBr else: gmCtf,
        episode.map)

  proc ensureRuntime(episode: var ShellEpisode) =
    if episode.engine == nil:
      episode.engine = newRuntimeEngine()
    if episode.compilePlane == nil:
      episode.compilePlane = newCompilePlane(episode.engine,
        episode.runtimeState.frames.len)
    episode.ensureLadder()

  proc addBindingFor(episode: var ShellEpisode; bound: BoundModule) =
    for binding in episode.bindings.mitems:
      if binding.manifest.name == bound.manifest.name and
          binding.hash == bound.hash:
        return
    let runtimeState = episode.runtimeState
    let map = episode.map
    let mode = if episode.brMode: gmBr else: gmCtf
    let module = bound.module
    episode.bindings.add LadderBinding(
      manifest: bound.manifest,
      hash: bound.hash,
      ready: true,
      makeGuest: proc(seatIndex: int; entry: ValidatedCallEntry,
                      emitClass: EmitClass): LadderGuest =
        discard entry
        var selfPos: BodyPoint
        if runtimeState != nil and seatIndex >= 0 and
            seatIndex < runtimeState.selfPositions.len:
          selfPos = runtimeState.selfPositions[seatIndex]
        try:
          shellGuest(newShellInstance(module, map, selfPos, emitClass, mode),
            emitClass)
        except ShellRuntimeError:
          nil)

  proc seatIsConfiguredPlay(episode: ShellEpisode; seatIndex: int): bool =
    for state in episode.seats:
      if state.seat.int == seatIndex:
        return true

  proc moduleStatus(commit: CompileCommit): ShellModuleStatus =
    ShellModuleStatus(seat: commit.seat, uploadId: commit.uploadId,
      terminal: $commit.terminal, status: commit.status,
      statusBytes: commit.statusBytes)

  proc entryIdentity(seat: int; identity: LadderEntryIdentity):
      ShellEntryIdentity =
    ShellEntryIdentity(seat: seat, entryId: identity.entryId,
      play: identity.play)

  proc ladderStatus(status: LadderStatus): ShellLadderStatus =
    ShellLadderStatus(seat: status.seat, entryId: status.entryId,
      status: status.status, statusBytes: status.statusBytes)

  proc callReplayIdentity(seatIndex: int; accepted: LadderCallResult):
      ShellCallReplayIdentity =
    ShellCallReplayIdentity(
      seat: uint8(seatIndex),
      callNumber: accepted.callNumber,
      ladderBytes: accepted.ladderBytes,
      entries: accepted.entries).withContentSha()

  proc commitReadyModules(episode: var ShellEpisode;
      maxCommits = MaxCompileCommitsPerTick): seq[ShellModuleStatus] =
    if episode.compilePlane == nil:
      return
    for commit in episode.compilePlane.commitCompileResults(maxCommits):
      if commit.terminal == tkReady:
        let bound = episode.compilePlane.boundModule(commit.seat, commit.status.name)
        if bound.isSome:
          episode.addBindingFor(bound.get)
      result.add commit.moduleStatus

  proc progressCompilePlane(episode: var ShellEpisode):
      seq[ShellModuleStatus] =
    if episode.compilePlane == nil:
      return
    for commit in episode.compilePlane.progressCompileWorkers():
      if commit.terminal == tkReady:
        let bound = episode.compilePlane.boundModule(commit.seat, commit.status.name)
        if bound.isSome:
          episode.addBindingFor(bound.get)
      result.add commit.moduleStatus

  proc beginCompileTick(episode: var ShellEpisode; tick: uint32) =
    if episode.compilePlane == nil or episode.runtimeState == nil:
      return
    if episode.runtimeState.lastCompileTick.isSome and
        episode.runtimeState.lastCompileTick.get == tick:
      return
    episode.compilePlane.beginTick()
    episode.runtimeState.lastCompileTick = some(tick)

  proc seatBindings(episode: var ShellEpisode;
      seatIndex: int): seq[LadderBinding] =
    if episode.compilePlane == nil:
      return
    for bound in episode.compilePlane.boundModules(seatIndex):
      episode.addBindingFor(bound)
      for binding in episode.bindings:
        if binding.manifest.name == bound.manifest.name and
            binding.hash == bound.hash:
          result.add binding
          break

  proc admitPlayModule*(episode: var ShellEpisode; seatIndex: int;
      uploadId, originGeneration: uint64; bytes: openArray[byte]):
      ShellAdmissionResult =
    if not episode.enabled:
      result.reason = "episodeDisabled"
      return
    if seatIndex < 0 or seatIndex >= episode.rosterSize:
      result.reason = "badSeat"
      return
    if not episode.seatIsConfiguredPlay(seatIndex):
      result.reason = "seatNotPlay"
      return
    episode.ensureRuntime()
    let admitted = episode.compilePlane.admitModule(seatIndex, uploadId,
      originGeneration, bytes)
    result.accepted = admitted.accepted
    result.status = admitted.status
    result.statusBytes = admitted.statusBytes
    if admitted.accepted:
      result.reason = ""
    else:
      result.reason = admitted.refusal.refusalReason

  proc acceptPlayCall*(episode: var ShellEpisode; seatIndex: int;
      proposalId, originGeneration: uint64; tick: uint32; callBytes: string):
      ShellCallResult =
    if not episode.enabled:
      result.reason = "episodeDisabled"
      result.path = "episode"
      return
    if seatIndex < 0 or seatIndex >= episode.rosterSize:
      result.reason = "badSeat"
      result.path = "seat"
      return
    if not episode.seatIsConfiguredPlay(seatIndex):
      result.reason = "seatNotPlay"
      result.path = "seat"
      return
    episode.ensureRuntime()
    let accepted = episode.ladder.acceptCall(seatIndex, proposalId,
      originGeneration, tick, callBytes, episode.seatBindings(seatIndex),
      noGuardContext())
    result.accepted = accepted.accepted
    result.reason = accepted.reason
    result.path = accepted.path
    result.callNumber = accepted.callNumber
    result.status = accepted.status
    result.statusBytes = accepted.statusBytes
    for identity in accepted.pendingRetunes:
      result.pendingRetunes.add entryIdentity(seatIndex, identity)
    if accepted.accepted:
      result.replayIdentity = some(callReplayIdentity(seatIndex, accepted))

  proc shellRecovery*(episode: ShellEpisode; seatIndex: int):
      tuple[callNumber: uint64, call: Option[PlayContextAcceptedCall],
            playbook: seq[PlayContextReadyModule]] =
    if episode.ladder != nil:
      let call = episode.ladder.callSnapshot(seatIndex)
      if call.isSome:
        let current = call.get
        result.callNumber = current.callNumber
        result.call = some(PlayContextAcceptedCall(
          proposalId: current.proposalId, bytes: current.bytes))
    if episode.compilePlane != nil:
      for bound in episode.compilePlane.boundModules(seatIndex):
        result.playbook.add PlayContextReadyModule(
          name: bound.name, sha256: bound.hash)

  proc callBytes(config: DemoPlayConfig): string =
    canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"" &
      config.playName & "\",\"params\":" & config.paramsBytes &
      ",\"play\":\"" & config.playName & "\"}]}"))

  proc configureDemoPlayWithReplayIdentities*(
      episode: var ShellEpisode;
      config: DemoPlayConfig): DemoPlayConfigResult =
    ## Binds a configured demo play through the production admission,
    ## compile, cache, instance, and call-validation seams.
    let refusal = episode.demoPlayConfigRefusal(config)
    if refusal.isSome:
      result.lines.add refusal.get
      return
    if not fileExists(config.modulePath):
      result.lines.add "SHELL_PLAY configured=false reason=module_missing path=" &
        config.modulePath
      return

    episode.ensureRuntime()
    let moduleBytes = readFile(config.modulePath)
    for index, seat in config.seats:
      let uploadId = config.uploadIdBase + uint64(index)
      let admitted = episode.admitPlayModule(seat, uploadId,
        config.originGeneration, moduleBytes.rawBytes)
      result.lines.add(&"SHELL_PLAY_UPLOAD seat={seat} upload_id={uploadId} " &
        &"accepted={admitted.accepted} status={admitted.statusBytes}")
    if not episode.compilePlane.drainCompileWorkers():
      result.lines.add("SHELL_PLAY_COMPILE drained=false")
      return
    var commits = 0
    while commits < config.seats.len:
      let batch = episode.commitReadyModules()
      if batch.len == 0:
        break
      for commit in batch:
        inc commits
        result.lines.add(&"SHELL_PLAY_COMMIT seat={commit.seat} " &
          &"upload_id={commit.uploadId} terminal={commit.terminal} " &
          &"status={commit.statusBytes}")

    for seat in config.seats:
      let accepted = episode.acceptPlayCall(seat,
        config.proposalIdBase + uint64(seat), config.originGeneration, 0,
        config.callBytes)
      result.lines.add(&"SHELL_PLAY_CALL seat={seat} accepted={accepted.accepted} " &
        &"call_number={accepted.callNumber} reason={accepted.reason} " &
        &"status={accepted.statusBytes}")
      if accepted.replayIdentity.isSome:
        result.callIdentities.add accepted.replayIdentity.get

  proc configureDemoPlay*(episode: var ShellEpisode;
      config: DemoPlayConfig): seq[string] =
    episode.configureDemoPlayWithReplayIdentities(config).lines

  proc restorePlaySeat*(episode: var ShellEpisode; seat: int;
      uploads: openArray[tuple[uploadId: uint64, wasm: string]];
      callNumber, callProposalId: uint64; callBytes: string;
      tick: uint32): seq[string] =
    ## Spec 0157 checkpoint restore of one play seat: re-admits every module
    ## the seat had admitted (same upload ids, same bytes), compiles them
    ## synchronously, and re-accepts the standing call under its original
    ## call number. Runs at boot, before tick T + 1 steps; nothing here is
    ## recorded into the replay (the restored prefix already holds it).
    if not episode.enabled:
      result.add "SHELL_RESTORE seat=" & $seat & " skipped=episode_disabled"
      return
    episode.ensureRuntime()
    for upload in uploads:
      # One upload per compile tick, as live admission spaces them.
      episode.compilePlane.beginTick()
      let admitted = episode.admitPlayModule(seat, upload.uploadId, 0,
        upload.wasm.rawBytes)
      result.add(&"SHELL_RESTORE_UPLOAD seat={seat} upload_id={upload.uploadId} " &
        &"accepted={admitted.accepted} reason={admitted.reason}")
    if uploads.len > 0 and not episode.compilePlane.drainCompileWorkers():
      result.add(&"SHELL_RESTORE_COMPILE seat={seat} drained=false")
    while true:
      let batch = episode.commitReadyModules()
      if batch.len == 0:
        break
      for commit in batch:
        result.add(&"SHELL_RESTORE_COMMIT seat={commit.seat} " &
          &"upload_id={commit.uploadId} terminal={commit.terminal}")
    if callBytes.len > 0 and callNumber > 0:
      episode.ladder.primeCallNumber(seat, callNumber - 1)
      let accepted = episode.acceptPlayCall(seat, callProposalId, 0, tick,
        callBytes)
      result.add(&"SHELL_RESTORE_CALL seat={seat} accepted={accepted.accepted} " &
        &"call_number={accepted.callNumber} reason={accepted.reason}")
else:
  proc shellRecovery*(episode: ShellEpisode; seatIndex: int):
      tuple[callNumber: uint64, call: Option[PlayContextAcceptedCall],
            playbook: seq[PlayContextReadyModule]] =
    discard episode
    discard seatIndex

  proc admitPlayModule*(episode: var ShellEpisode; seatIndex: int;
      uploadId, originGeneration: uint64; bytes: openArray[byte]):
      ShellAdmissionResult =
    discard seatIndex
    discard uploadId
    discard originGeneration
    discard bytes
    if not episode.enabled:
      result.reason = "episodeDisabled"
    else:
      result.reason = "runtimeUnavailable"

  proc acceptPlayCall*(episode: var ShellEpisode; seatIndex: int;
      proposalId, originGeneration: uint64; tick: uint32; callBytes: string):
      ShellCallResult =
    discard seatIndex
    discard proposalId
    discard originGeneration
    discard tick
    discard callBytes
    if not episode.enabled:
      result.reason = "episodeDisabled"
      result.path = "episode"
    else:
      result.reason = "runtimeUnavailable"
      result.path = "runtime"

  proc configureDemoPlay*(episode: var ShellEpisode;
      config: DemoPlayConfig): seq[string] =
    let refusal = episode.demoPlayConfigRefusal(config)
    if refusal.isSome:
      return @[refusal.get]
    @["SHELL_PLAY configured=false reason=runtime_unavailable " &
      "hint=compile with --threads:on and WASMTIME_C_API"]

  proc configureDemoPlayWithReplayIdentities*(
      episode: var ShellEpisode;
      config: DemoPlayConfig): DemoPlayConfigResult =
    result.lines = episode.configureDemoPlay(config)

  proc restorePlaySeat*(episode: var ShellEpisode; seat: int;
      uploads: openArray[tuple[uploadId: uint64, wasm: string]];
      callNumber, callProposalId: uint64; callBytes: string;
      tick: uint32): seq[string] =
    discard uploads
    discard callNumber
    discard callProposalId
    discard callBytes
    discard tick
    @["SHELL_RESTORE seat=" & $seat & " skipped=runtime_unavailable"]

proc configureDemoPlayFromJsonWithReplayIdentities*(
    episode: var ShellEpisode; configJson: string;
    repoRoot = getCurrentDir()): DemoPlayConfigResult =
  let node = demoPlayNode(configJson)
  if node == nil:
    return
  try:
    result = episode.configureDemoPlayWithReplayIdentities(
      node.playConfigFromNode(repoRoot))
  except CatchableError as error:
    result.lines = @["SHELL_PLAY configured=false reason=parse_error detail=" &
      error.msg]

proc configureDemoPlayFromJson*(episode: var ShellEpisode;
    configJson: string; repoRoot = getCurrentDir()): seq[string] =
  episode.configureDemoPlayFromJsonWithReplayIdentities(
    configJson, repoRoot).lines

when ShellRuntimeAvailable:
  proc eventIdInt(value: uint64): int =
    if value <= uint64(high(int)): value.int else: high(int)

  proc zoneTicksUntilOutside(fallback: BrDefaultFallbacks):
      ZoneTicksUntilOutside =
    let
      current = fallback.currentZone
      ticksToShrink =
        int64(playZoneTicksToShrink(fallback.ticksToNextShrink))
    result = proc(point: BodyPoint): int64 =
      if point.x < current.x or point.y < current.y or
          point.x >= current.x + current.w or
          point.y >= current.y + current.h:
        0
      else:
        ticksToShrink

  proc reflexInput(state: ShellSeatState; frame: ShellSeatFrame;
                   tick: uint32; mode: GameMode): ReflexTickInput =
    result = ReflexTickInput(
      tick: tick,
      mode: mode,
      map: state.body.map,
      selfPos: frame.bodyInputs.self.pos,
      alive: frame.alive,
      motionScale: if frame.motionScale > 0: frame.motionScale else:
        MotionScale,
      velocity: if frame.velocity > 0: frame.velocity else: MaxSpeed,
      zoneTicksUntilOutside:
        zoneTicksUntilOutside(frame.defaultFallbacks),
      nextZone: frame.defaultFallbacks.nextZone)
    for hazard in state.body.hazards.grenades:
      result.visibleGrenades.add VisibleGrenade(
        predictedBlastPos: hazard.predictedBlastPos,
        ticksToBlast: hazard.ticksToBlast,
        blastRadius: GrenadeBlastRadius,
        eventId: hazard.eventId.eventIdInt)
    for cue in state.body.hazards.blastCues:
      result.blastCues.add BlastCue(
        pos: cue.pos,
        tick: cue.tick,
        eventId: cue.eventId.eventIdInt)
    for hazard in state.body.hazards.sprays:
      case hazard.kind
      of bshVisibleCone:
        result.sprayCones.add VisibleSprayCone(
          origin: hazard.origin,
          aimBrads: hazard.aimBrads,
          coversSelf: hazard.coversSelf,
          tick: hazard.tick,
          eventId: hazard.eventId.eventIdInt)
      of bshAnonymousImpact:
        result.sprayImpacts.add AnonymousSprayImpact(
          impactPos: hazard.impactPos,
          incomingDir: hazard.incomingDirBrads,
          tick: hazard.tick,
          eventId: hazard.eventId.eventIdInt)

  proc nativeBase(decision: ReflexDecision): Option[LadderNativeBase] =
    if not decision.selected:
      return none(LadderNativeBase)
    some(LadderNativeBase(
      intent: decision.order.intent,
      goal: decision.order.goal,
      provenance: decision.order.provenance,
      contributingCallNumber: decision.order.contributingCallNumber))

proc resetAfterDeath(state: var ShellSeatState, tick: uint32,
    nav: BodyNavSystem, annotations: var seq[ShellAnnotation]) =
  annotations.add(ShellAnnotation(
    tick: tick,
    seat: state.seat,
    kind: akClearOnDeath,
    clearGeneration: 0))
  state.active = false
  state.standing = StandingOrderState()
  state.body = nil
  nav.setSeatActive(state.seat.int, false)

proc activate(state: var ShellSeatState, tick: uint32, reason: string,
    nav: BodyNavSystem,
    output: var ShellTickResult) =
  state.body = activateSeatBody(nav, state.seat.int)
  nav.setSeatActive(state.seat.int, true)
  let
    safe = safeIntent(reason)
    provenance = Provenance(base: ProvenanceBase(kind: pbDefault))
    safeBytes = canonicalIntent(safe)
  setStandingIntent(state.body, safe, none(ValidatedGoal), 0)
  state.standing = StandingOrderState(
    hasStanding: true,
    intent: safe,
    intentBytes: safeBytes,
    provenance: provenance,
    effectiveCallNumber: 0,
    installedEffectiveCallNumber: 0,
    lastDefaultRule: brHold)
  let annotation = ShellAnnotation(
    tick: tick,
    seat: state.seat,
    kind: akInstallSafeIntent,
    installGeneration: 0,
    installReason: reason,
    safeBytes: safeBytes)
  output.annotations.add(annotation)
  output.installs.add(annotation.installRecord(
    "safe_hold", "default", safeBytes))
  state.active = true
  state.everActivated = true

proc appendStandingChanges(state: var ShellSeatState,
    output: var ShellTickResult) =
  for annotation in state.standing.annotations:
    output.annotations.add(annotation)
    if annotation.kind == akAcceptedIntentChange:
      let rule =
        case annotation.provenance.base.kind
        of pbEntry: annotation.provenance.base.entryId
        of pbDefault: $state.standing.lastDefaultRule
        of pbReflex: annotation.provenance.base.reflexName
      output.installs.add(annotation.installRecord(
        rule,
        annotation.provenance.provenanceText,
        annotation.intentBytes))
  state.standing.annotations.setLen(0)

proc acceptDangerTrack(track: BodyTrack): bool =
  discard track
  true

proc dangerInputs(episode: ShellEpisode,
                  tick: uint32): seq[DangerInput] =
  result = newSeq[DangerInput](episode.nav.seats.len)
  for state in episode.seats:
    if state.active and state.body != nil:
      result[state.seat.int] =
        state.body.dangerInputFromTracks(tick, acceptDangerTrack)

proc summarizeSeatTick(body: SeatBody, result: var ShellTickResult) =
  ## Folds one seat's follower and weapon-path outcomes into the tick census.
  let seat = uint8(body.seatIndex)
  case body.navState
  of bnsStalePath: result.nav.stalePathSeats.add seat
  of bnsNoPath: result.nav.noPathSeats.add seat
  of bnsIdle, bnsFollowing: discard
  inc result.combat.counts[body.combatOutcome]
  case body.combatOutcome
  of coNoneShootable: result.combat.noneShootableSeats.add seat
  of coAligning: result.combat.aligningSeats.add seat
  of coNoEnemy, coVetoed, coFired: discard

when ShellRuntimeAvailable:
  const
    PlayLogLinesPerWindow = 4
    PlayLogWindowTicks = 24'u32

  proc playLogPhase(kind: InvocationKind): string =
    case kind
    of ivManifest: "manifest"
    of ivInit: "init"
    of ivStep: "step"
    of ivRetune: "retune"

  proc formatPlayLog(tick: uint32; log: LadderLogRecord;
                     droppedPrevious: int): string =
    result = &"SHELL_PLAY_LOG tick={tick} seat={log.seat} " &
      &"entry={log.entryId} phase={log.phase.playLogPhase} " &
      &"level={log.level} message={log.bytes.escape}"
    if droppedPrevious > 0:
      result.add &" dropped_previous={droppedPrevious}"

  proc appendPlayLogs(episode: var ShellEpisode; tick: uint32;
                      logs: openArray[LadderLogRecord];
                      lines: var seq[string]) =
    let window = (tick - 1) div PlayLogWindowTicks
    for log in logs:
      var state = addr episode.runtimeState.playLogWindows[log.seat]
      var droppedPrevious = 0
      if state[].window != window:
        droppedPrevious = state[].dropped
        state[].window = window
        state[].admitted = 0
        state[].dropped = 0
      if state[].admitted < PlayLogLinesPerWindow:
        lines.add formatPlayLog(tick, log, droppedPrevious)
        inc state[].admitted
      else:
        inc state[].dropped

template stageBlock(sums: var array[ShellStage, int64], stage: ShellStage,
                    name: string, body: untyped) =
  block:
    let stageStarted = getMonoTime()
    profileBlock(name):
      try:
        body
      finally:
        sums[stage] += (getMonoTime() - stageStarted).inNanoseconds

proc step*(episode: var ShellEpisode,
    frames: openArray[ShellSeatFrame], tick: uint32): ShellTickResult =
  ## Runs configured play seats in configured-seat order. Disabled episodes
  ## return an empty result, so the server hook cannot touch legacy inputs or
  ## replay bytes on gate-off or gate-on/all-input configurations.
  if not episode.enabled:
    return

  when ShellRuntimeAvailable:
    if episode.runtimeState != nil:
      for slot in episode.runtimeState.frames.mitems:
        slot.present = false
      for frame in frames:
        let seat = frame.seat.int
        if seat >= 0 and seat < episode.runtimeState.frames.len:
          episode.runtimeState.frames[seat] =
            ShellViewFrameSlot(present: frame.present, frame: frame)
          episode.runtimeState.selfPositions[seat] = frame.bodyInputs.self.pos
    stageBlock(result.stageNanoseconds, ssCompilePlane, "shell.compile"):
      episode.beginCompileTick(tick)
      result.moduleStatuses = episode.progressCompilePlane()

  for state in episode.seats.mitems:
    var frameIndex = -1
    for index, frame in frames:
      if frame.seat == state.seat:
        frameIndex = index
        break
    if frameIndex < 0 or not frames[frameIndex].present:
      continue
    let frame = frames[frameIndex]

    let runtimeStarted = getMonoTime()
    stageBlock(result.stageNanoseconds, ssLifecycle, "shell.lifecycle"):
      if state.active and not frame.alive:
        state.resetAfterDeath(tick, episode.nav, result.annotations)
        if episode.brMode:
          state.eliminated = true
      if frame.playing and frame.alive and not state.active and
          not state.eliminated:
        state.activate(tick,
          if state.everActivated: "respawn" else: "activation",
          episode.nav, result)
        inc episode.bodyActivations
      if state.active and frame.playing and frame.alive:
        stageBlock(result.stageNanoseconds, ssBelief, "body.belief"):
          state.body.updateBelief(frame.bodyInputs, tick)
    when not ShellRuntimeAvailable:
      if state.active and frame.playing and frame.alive:
        stageBlock(result.stageNanoseconds, ssDefault, "shell.default"):
          state.standing.stepShellDefault(state.body, tick,
            frame.defaultFallbacks)
          state.appendStandingChanges(result)
    result.runtimeNanoseconds += (getMonoTime() - runtimeStarted).inNanoseconds

  when ShellRuntimeAvailable:
    if episode.runtimeState != nil:
      episode.ensureLadder()
    if episode.ladder != nil:
      let runtimeStarted = getMonoTime()
      let episodePtr = addr episode
      let stageSumsPtr = addr result.stageNanoseconds
      let viewSource: LadderViewSource =
        if episode.viewSource == nil:
          proc(seatIndex: int; viewTick: uint32): string =
            stageBlock(stageSumsPtr[], ssView, "shell.view"):
              result = episodePtr[].shellViewBytes(seatIndex, viewTick)
        else:
          let customSource = episode.viewSource
          proc(seatIndex: int; viewTick: uint32): string =
            stageBlock(stageSumsPtr[], ssView, "shell.view"):
              result = customSource(seatIndex, viewTick)
      proc defaultSource(state: ptr ShellSeatState;
                         facts: sink BrDefaultFacts): LadderDefaultSource =
        # Bind each seat independently; the synchronous ladder call below
        # finishes before these state/timing pointers can go out of scope.
        result = proc(seatIndex: int; defaultTick: uint32):
            tuple[intent: Intent, goal: Option[ValidatedGoal]] =
          stageBlock(stageSumsPtr[], ssDefault, "shell.default"):
            let decision = state[].body.computeBodyDefault(facts)
            state[].standing.lastDefaultRule = decision.rule
            result = (decision.intent, decision.goal)
      var inputs = newSeq[LadderSeatInput](episode.runtimeState.frames.len)
      for seat in 0 ..< inputs.len:
        inputs[seat] = LadderSeatInput(
          alive: false,
          contextBytes: "{}",
          guardContext: noGuardContext())

      for state in episode.seats.mitems:
        let seat = state.seat.int
        if seat < 0 or seat >= episode.runtimeState.frames.len:
          continue
        let slot = episode.runtimeState.frames[seat]
        if not slot.present or not state.active or not slot.frame.playing or
            not slot.frame.alive:
          continue
        var
          facts: BrDefaultFacts
          reflexDecision: ReflexDecision
          contextBytes: string
          guardContext: IntentContext
        stageBlock(result.stageNanoseconds, ssDefault, "shell.default"):
          facts = brDefaultFacts(state.body, tick, slot.frame.defaultFallbacks)
        stageBlock(result.stageNanoseconds, ssReflex, "shell.reflex"):
          reflexDecision =
            episode.runtimeState.reflexStates[seat].selectReflex(
              state.reflexInput(slot.frame, tick,
                if episode.brMode: gmBr else: gmCtf),
              NativeReflexSubscriptions)
        stageBlock(result.stageNanoseconds, ssContext, "shell.context"):
          contextBytes = episode.shellContextBytes(seat, slot.frame)
        stageBlock(result.stageNanoseconds, ssGuard, "shell.guard"):
          guardContext = playGuardContext(state.body, facts,
            episode.brMode, slot.frame.defaultFallbacks.zonePhase > 0)
        inputs[seat] = LadderSeatInput(
          alive: true,
          selfPos: slot.frame.bodyInputs.self.pos,
          contextBytes: contextBytes,
          viewSource: viewSource,
          guardContext: guardContext,
          defaultSource: defaultSource(addr state, move(facts)),
          nativeBase: reflexDecision.nativeBase)

      var ladderOutput: LadderTickResult
      let defaultBeforeLadder = result.stageNanoseconds[ssDefault]
      stageBlock(result.stageNanoseconds, ssLadder, "shell.ladder"):
        ladderOutput = episode.ladder.tick(inputs, tick, episode.bindings)
      # Default work now runs inside ladder selection, but keeps its own row.
      result.stageNanoseconds[ssLadder] -=
        result.stageNanoseconds[ssDefault] - defaultBeforeLadder
      for row in ladderOutput.seats:
        episode.appendPlayLogs(tick, row.logs, result.playLogLines)
        for status in row.statuses:
          result.ladderStatuses.add status.ladderStatus
          if status.status.kind == skPlayFaulted:
            # The fault is minted into the annotation stream so the replay
            # and the server log both say WHY the provenance switched on this
            # tick; the standing-order annotation that follows says to what.
            result.annotations.add(ShellAnnotation(
              tick: tick,
              seat: uint8(row.seat),
              kind: akPlayFault,
              faultAtCallNumber: status.status.faultCallNumber,
              faultEntryId: status.entryId,
              faultCode: status.status.faultCode,
              annotationFaultReason: status.status.faultReason))
        for identity in row.retuned:
          result.retuned.add entryIdentity(row.seat, identity)
      stageBlock(result.stageNanoseconds, ssStanding, "shell.standing"):
        for state in episode.seats.mitems:
          let seat = state.seat.int
          if seat < 0 or seat >= ladderOutput.seats.len or
              seat >= episode.runtimeState.frames.len:
            continue
          let slot = episode.runtimeState.frames[seat]
          if not slot.present or not state.active or not slot.frame.playing or
              not slot.frame.alive:
            continue
          let row = ladderOutput.seats[seat]
          state.standing.stepResolvedOrder(state.body, tick,
            ResolvedStandingOrder(
              intent: row.intent,
              goal: row.goal,
              provenance: row.provenance,
              contributingCallNumber: row.contributingCallNumber))
          state.appendStandingChanges(result)
      result.runtimeNanoseconds +=
        (getMonoTime() - runtimeStarted).inNanoseconds

  var seatTeams: seq[Team]
  when ShellRuntimeAvailable:
    # ALLIANCE (engine registration rewire, GameVersion 56): the roster's
    # seat -> Team table, built once per tick for resolvePactPartnerTeams
    # below — the same seat_or_duo_ref resolution `body.nim`/emit_validator
    # already use, reused rather than reinvented (16-solo: seat N is Team
    # N; duo: two seats share one Team, per contextRoster's own rows).
    if episode.ladder != nil:
      seatTeams = newSeq[Team](episode.contextRoster.len)
      for row in episode.contextRoster:
        if row.seat >= 0 and row.seat < seatTeams.len:
          seatTeams[row.seat] = row.team

  for state in episode.seats.mitems:
    var frameIndex = -1
    for index, frame in frames:
      if frame.seat == state.seat:
        frameIndex = index
        break
    if frameIndex < 0 or not frames[frameIndex].present:
      continue
    let frame = frames[frameIndex]
    # Every present play seat hands one mask to the caller each tick. Lane A's
    # action phase is the sole movement/action executor for active seats.
    var input = InputState()
    if state.active and frame.playing and frame.alive:
      let bodyStarted = getMonoTime()
      input = actFromBelief(state.body, tick)
      result.bodyNanoseconds += (getMonoTime() - bodyStarted).inNanoseconds
      result.stageNanoseconds[ssFollower] += state.body.followerNanoseconds
      result.stageNanoseconds[ssWeapon] += state.body.weaponNanoseconds
      summarizeSeatTick(state.body, result)
      # §4.1 amendment: surface the standing order's give-item declaration
      # beside the mask it was resolved with. Upright seats only — a dead
      # seat's declaration dies sim-side with the life that made it, and
      # the consent seam refuses dead/downed seats anyway.
      if state.standing.hasStanding:
        result.handoffs.add(ShellHandoff(
          seat: state.seat,
          playerIndex: frame.playerIndex,
          item: state.standing.intent.handoff))
      # ALLIANCE (engine registration rewire, GameVersion 56): surface the
      # `pact` play's own CURRENT `partners` param beside the mask, same
      # division of labor as the handoff declaration just above — read
      # straight off the ladder's entry snapshot (the call's own static
      # params), NEVER off the emitted combat_policy (the play's own
      # betrayal-narrowed body behavior, out of scope for the registry).
      when ShellRuntimeAvailable:
        if episode.ladder != nil:
          var partners: seq[Team] = @[]
          for snap in episode.ladder.entrySnapshots(frame.seat.int):
            if snap.play == "pact":
              partners = resolvePactPartnerTeams(snap.paramsBytes, seatTeams)
              break
          result.pactDeclarations.add(ShellPactDeclaration(
            seat: state.seat, playerIndex: frame.playerIndex,
            partners: partners))
    result.masks.add(ShellMask(
      seat: state.seat, playerIndex: frame.playerIndex, input: input))
  stageBlock(result.stageNanoseconds, ssDanger, "shell.danger"):
    episode.nav.rebuildScheduledDanger(tick.int, episode.dangerInputs(tick))
  stageBlock(result.stageNanoseconds, ssPlanning, "shell.planning"):
    discard episode.nav.runPlanningTick(tick.int)
  result.planBudget = episode.nav.drainPlanBudgetEvents()
  result.nav.pendingPlans = episode.nav.pendingPlanCount()

proc observeDeaths*(episode: var ShellEpisode,
    frames: openArray[ShellSeatFrame], tick: uint32): seq[ShellAnnotation] =
  ## Post-sim lifecycle hook: clear a seat on the exact tick whose sim step
  ## killed it, without running a default, a body, or a mask handoff twice.
  if not episode.enabled:
    return
  for state in episode.seats.mitems:
    if not state.active:
          continue
    for frame in frames:
      if frame.seat == state.seat and frame.present and not frame.alive:
        state.resetAfterDeath(tick, episode.nav, result)
        if episode.brMode:
          state.eliminated = true
        break

proc formatInstall*(install: ShellInstall): string =
  &"SHELL_INSTALL tick={install.tick} seat={install.seat} " &
    &"rule={install.rule} provenance={install.provenance} " &
    &"bytes_fnv1a64={install.bytesHash} bytes={install.bytes}"

proc seatDisplayName*(episode: ShellEpisode, seat: int): string =
  ## The seat's roster display name, or "" when the episode has none.
  when ShellRuntimeAvailable:
    for row in episode.contextRoster:
      if row.seat == seat:
        return row.name
  ""

proc seatList(seats: seq[uint8]): string =
  "[" & seats.mapIt($it).join(",") & "]"

proc formatPlanBudgetEvent*(event: PlanBudgetEvent): string =
  let outcome =
    case event.outcome
    of pboSuspended: "suspended"
    of pboCompleted: "completed"
    of pboFailed: "failed"
  &"SHELL_PLAN_BUDGET tick={event.tick} seat={event.seat} " &
    &"revision={event.revision} visits={event.visits} units={event.units} " &
    &"outcome={outcome}"

proc formatNavSummary*(tick: uint32, nav: ShellNavSummary): string =
  &"SHELL_NAV tick={tick} pending_plans={nav.pendingPlans} " &
    &"stale_path={nav.stalePathSeats.seatList} " &
    &"no_path={nav.noPathSeats.seatList}"

proc formatCombatSummary*(tick: uint32,
                          combat: ShellCombatSummary): string =
  &"SHELL_COMBAT tick={tick} fired={combat.counts[coFired]} " &
    &"aligning={combat.counts[coAligning]} " &
    &"none_shootable={combat.counts[coNoneShootable]} " &
    &"vetoed={combat.counts[coVetoed]} no_enemy={combat.counts[coNoEnemy]} " &
    &"none_shootable_seats={combat.noneShootableSeats.seatList} " &
    &"aligning_seats={combat.aligningSeats.seatList}"

proc shellNanoseconds*(sums: array[ShellStage, int64]): int64 =
  ## Belief is contained by lifecycle, and the lazy view is contained by the
  ## ladder call. Every other row is an exclusive step segment.
  for stage in ShellStage:
    if stage notin {ssBelief, ssView}:
      result += sums[stage]

proc formatTimingSummary*(tick: uint32, seats, windowTicks: int,
                          sums: array[ShellStage, int64], maxTickNs,
                          simNs: int64): string =
  template micros(stage: ShellStage): int64 =
    sums[stage] div 1_000
  &"SHELL_TIMING tick={tick} seats={seats} window_ticks={windowTicks} " &
    &"shell_us={sums.shellNanoseconds div 1_000} " &
    &"max_tick_us={maxTickNs div 1_000} sim_us={simNs div 1_000} " &
    &"lifecycle_us={micros(ssLifecycle)} default_us={micros(ssDefault)} " &
    &"reflex_us={micros(ssReflex)} context_us={micros(ssContext)} " &
    &"view_us={micros(ssView)} guard_us={micros(ssGuard)} " &
    &"ladder_us={micros(ssLadder)} standing_us={micros(ssStanding)} " &
    &"belief_us={micros(ssBelief)} follower_us={micros(ssFollower)} " &
    &"weapon_us={micros(ssWeapon)} danger_us={micros(ssDanger)} " &
    &"planning_us={micros(ssPlanning)} compile_us={micros(ssCompilePlane)}"

proc formatLifecycleAnnotation*(annotation: ShellAnnotation,
                                player = ""): string =
  ## `player` is the seat's display name; it is printed only when known.
  let playerField = if player.len > 0: &" player={player.escape}" else: ""
  case annotation.kind
  of akClearOnDeath:
    &"SHELL_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=clear_on_death generation={annotation.clearGeneration}"
  of akInstallSafeIntent:
    &"SHELL_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=install_safe reason={annotation.installReason}"
  of akAcceptedIntentChange:
    &"SHELL_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=accepted_intent call_number={annotation.effectiveCallNumber}"
  of akPlayFault:
    &"SHELL_ANNOTATION tick={annotation.tick} seat={annotation.seat}" &
      &"{playerField} kind=play_fault call_number={annotation.faultAtCallNumber} " &
      &"entry={annotation.faultEntryId} code={annotation.faultCode} " &
      &"reason={annotation.annotationFaultReason.escape}"
