## The baseline's Season 2 play-calling seat: everything needed to drive a
## `control: "play"` seat with the SAME deterministic, model-free logic a
## Sprite v1 baseline used to drive with button masks.
##
## This is a direct, deliberately small port of the gate-based "ladder
## maintenance" path in `policies/starters/common/starter_harness.py`
## (`gate_open`/`layer_ladder`/`gate_and_build`): a fixed wanted ladder --
## one always-on overlay, a couple of gated controllers, one always-on base
## controller -- re-gated against the live `PlayView` on every frame, with a
## `PlayCall` sent only when the gated ladder actually changes. The starters
## use this same path as their MODEL-FREE fallback; this baseline runs
## nothing else, because it has no model to consult and does not need one:
## the plays themselves (compiled from `play_sdk/reference/*.nim`) carry the
## actual movement/aim/combat logic, the same way the legacy Sprite v1 path's
## button masks used to.
##
## What ported cleanly from the legacy baseline.nim tactics, and what did
## not (see the design's task item 4 accounting, restated in the PR):
## - `target_law` (`prefer: ["weakened", "isolated"]`) stands in for the
##   legacy HpFocusBonus/ThiefFocusBonus target preference (favour a hurt or
##   alone enemy over a full-health, escorted one).
## - `supply_run`'s gate (heal when hurt and a medkit is in reach) stands in
##   for MedKitDetour/MedKitCriticalReach.
## - `loot`'s gate (grab nearby gear when no enemy is close) stands in for
##   NadePickupDetour/BarrierDetour/SpraypaintDetour.
## - `edge_ride` is the always-on base. It has no legacy analogue: the
##   classic baseline's whole navigation stack (nav grid, cover model, flag
##   roles) is built for the two-flag CTF board and simply does not apply to
##   a battle-royale shrinking zone, so the sensible default is the
##   reference zone-riding play itself, not a translation of anything.
## - NOT ported: `pact`, `bodyguard`, `crossfire`, `jackal` (duo/alliance
##   plays -- the legacy baseline has no negotiated-alliance or ward concept
##   to translate, and battle-royale-s2's certification fixture solo-seats
##   every slot, so `context.self.duo_partner` is absent and these plays'
##   gates would never open regardless).

import std/[json, math, options, os, strutils, times]
import whisky
import ./s2wire

const
  UploadDeadlineSeconds = 20.0
  CallDeadlineSeconds = 10.0

  MaxHpFallback = 6.0        ## a full seat's assumed hp, refined once a real
                             ## hp/hp_frac pair has been observed
  TrackFreshTicks = 240      ## a track older than this no longer counts as
                             ## "seen" (matches starter_harness.py)
  LootClearPx = 500.0        ## loot only with no fresh enemy closer than this
  SupplyRunDetourMax = 500.0
  LootDetourMax = 400.0
  SupplyRunWhenHpBelow = 3.0 ## ABSOLUTE hp units, matches supply_run's own
                             ## manifest default (policies/starters/common/
                             ## plays.py) so the client-side gate and the
                             ## play's own server-side default agree

  ReferencePlays* = ["edge_ride", "target_law", "supply_run", "loot"]
    ## The MVP playbook this baseline uploads and calls -- a subset of the
    ## nine reference plays under play_sdk/reference/ (see module doc for
    ## which four are missing and why).

# ── perception: read the same PlayView/PlayContext fields the starters do ──

type Vec2 = tuple[x, y: float]

proc asFloat(n: JsonNode): float =
  if n.isNil: return 0.0
  case n.kind
  of JFloat: n.fnum
  of JInt: float(n.num)
  else: 0.0

proc isPos(n: JsonNode): bool =
  not n.isNil and n.kind == JArray and n.len == 2 and
    n[0].kind in {JInt, JFloat} and n[1].kind in {JInt, JFloat}

proc posOf(n: JsonNode): Vec2 =
  (asFloat(n[0]), asFloat(n[1]))

proc vdist(a, b: Vec2): float =
  hypot(a.x - b.x, a.y - b.y)

proc maxHpOf(view: JsonNode): float =
  let me = view{"self"}
  let hp = me{"hp"}
  let frac = me{"hp_frac"}
  if not hp.isNil and hp.kind == JInt and not frac.isNil and
      frac.kind in {JFloat, JInt} and asFloat(frac) > 0.0:
    return max(1.0, float(hp.num) / asFloat(frac))
  MaxHpFallback

proc seatEq(a, b: JsonNode): bool =
  not a.isNil and not b.isNil and a.kind == JInt and b.kind == JInt and
    a.num == b.num

proc teamEq(a, b: JsonNode): bool =
  not a.isNil and not b.isNil and a.kind == JString and b.kind == JString and
    a.str == b.str

proc nearestEnemyDist(view, context: JsonNode): tuple[has: bool, d: float] =
  ## The closest fresh, non-self, non-teammate, non-partner track -- exactly
  ## `_view_facts`'s `nearest_enemy` in starter_harness.py.
  let me = view{"self"}
  if me.isNil or not isPos(me{"pos"}):
    return (false, 0.0)
  let pos = posOf(me{"pos"})
  let tick = view{"tick"}.getInt(0)
  let mySeat = context{"self"}{"seat"}
  let myTeam = context{"self"}{"team"}
  let partner = context{"self"}{"duo_partner"}
  let tracks = view{"tracks"}
  if tracks.isNil or tracks.kind != JArray:
    return (false, 0.0)
  var has = false
  var best = 0.0
  for t in tracks.elems:
    if t.isNil or not isPos(t{"pos"}):
      continue
    if seatEq(t{"seat"}, partner):
      continue
    if seatEq(t{"seat"}, mySeat) or teamEq(t{"team"}, myTeam):
      continue
    let freshTick = t{"fresh_tick"}
    let age = if freshTick.kind == JInt: tick - int(freshTick.num) else: 0
    if age > TrackFreshTicks:
      continue
    let d = vdist(pos, posOf(t{"pos"}))
    if not has or d < best:
      has = true
      best = d
  (has, best)

proc itemWithin(view: JsonNode, pos: Vec2, maxPx: float, wantKind = "",
    excludeKind = ""): bool =
  let items = view{"items"}
  if items.isNil or items.kind != JArray:
    return false
  for item in items.elems:
    if item.isNil or not item{"present"}.getBool(true):
      continue
    if not isPos(item{"pos"}):
      continue
    let kind = item{"kind"}.getStr("")
    if wantKind.len > 0 and kind != wantKind:
      continue
    if excludeKind.len > 0 and kind == excludeKind:
      continue
    if vdist(pos, posOf(item{"pos"})) <= maxPx:
      return true
  false

proc supplyRunGateOpen*(view, context: JsonNode): bool =
  ## Mirrors `gate_open`'s "supply_run" arm: wounded AND a medkit in reach.
  if view.isNil: return false
  let me = view{"self"}
  if me.isNil or not isPos(me{"pos"}):
    return false
  let hpFracNode = me{"hp_frac"}
  if hpFracNode.isNil or hpFracNode.kind notin {JFloat, JInt}:
    return false
  let wounded = asFloat(hpFracNode) * maxHpOf(view) < SupplyRunWhenHpBelow
  wounded and itemWithin(view, posOf(me{"pos"}), SupplyRunDetourMax,
    wantKind = "medkit")

proc lootGateOpen*(view, context: JsonNode): bool =
  ## Mirrors `gate_open`'s "loot" arm: distance-based clear (no fresh enemy
  ## within LootClearPx) AND a non-medkit item in reach.
  if view.isNil: return false
  let me = view{"self"}
  if me.isNil or not isPos(me{"pos"}):
    return false
  let (hasEnemy, d) = nearestEnemyDist(view, context)
  if hasEnemy and d <= LootClearPx:
    return false
  itemWithin(view, posOf(me{"pos"}), LootDetourMax, excludeKind = "medkit")

# ── the ladder: overlay, gated controllers, always-on base ─────────────────

type LadderEntry = object
  play, entryId: string
  preferTags: seq[string]

proc buildLadder*(view, context: JsonNode): seq[LadderEntry] =
  ## The ladder to actually send: the standing overlay first (it always
  ## folds), then whichever gated controllers are open right now, then the
  ## always-on base -- `layer_ladder`'s ordering in starter_harness.py.
  result.add(LadderEntry(play: "target_law", entryId: "prefer",
    preferTags: @["weakened", "isolated"]))
  if supplyRunGateOpen(view, context):
    result.add(LadderEntry(play: "supply_run", entryId: "heal"))
  if lootGateOpen(view, context):
    result.add(LadderEntry(play: "loot", entryId: "loot"))
  result.add(LadderEntry(play: "edge_ride", entryId: "base_edge_ride"))

proc encodeLadder*(entries: seq[LadderEntry]): string =
  var parts: seq[string]
  for e in entries:
    parts.add(canonicalEntry(e.play, e.entryId, e.preferTags))
  canonicalLadder(parts)

# ── the seat: upload/call/status bookkeeping over the wire codec ──────────

type
  S2Seat = object
    ws: WebSocket
    slot: int
    nextUploadId: uint64
    nextProposalId: uint64
    ackMark: uint64
    highestOrdinal: uint64
    context: JsonNode         ## parsed 0xB0 "context" payload
    controlContext: JsonNode  ## parsed 0xB0 "control" payload
    view: JsonNode            ## parsed latest non-empty 0xB1 "view" payload
    statuses: seq[JsonNode]
    # --- seat state (Coworld Checkpoints, PLAYER.md "Checkpoints") -------
    uploaded: bool            ## the playbook upload pass has run
    readyCount: int
    standingPayload: string   ## the last ladder the server accepted
    restores: int             ## how many times this seat resumed from state
    checkpoints: int          ## checkpoint prompts answered

proc jsonU64(n: JsonNode): uint64 =
  ## u64 identities (upload/proposal/status ordinals) ride the wire as
  ## decimal STRINGS under the canonical JSON rule, never bare numbers.
  if n.isNil: return 0
  case n.kind
  of JString:
    try: uint64(parseBiggestUInt(n.str))
    except ValueError: 0
  of JInt: uint64(n.num)
  else: 0

proc initS2Seat(ws: WebSocket, slot: int): S2Seat =
  S2Seat(ws: ws, slot: slot, nextUploadId: 1, nextProposalId: 1)

proc fileStatus(seat: var S2Seat, status: JsonNode) =
  seat.statuses.add(status)
  let ordinal = jsonU64(status{"ordinal"})
  if ordinal > seat.highestOrdinal:
    seat.highestOrdinal = ordinal

proc file(seat: var S2Seat, packet: S2Packet) =
  case packet.kind
  of spkPlayContext:
    seat.controlContext = parseJson(packet.control)
    seat.context = parseJson(packet.context)
  of spkPlayView:
    let control = parseJson(packet.viewControl)
    if packet.view.len > 0:
      seat.view = parseJson(packet.view)
    let statuses = control{"statuses"}
    if not statuses.isNil and statuses.kind == JArray:
      for s in statuses.elems:
        seat.fileStatus(s)
  of spkLobbyChat, spkIgnored:
    discard

proc pump(seat: var S2Seat) =
  ## Acknowledges every status consumed so far. Only a nondecreasing,
  ## already-delivered mark is legal (StatusAck out-of-range is refused).
  if seat.highestOrdinal > seat.ackMark:
    seat.ackMark = seat.highestOrdinal
    seat.ws.send(encodeStatusAck(seat.ackMark), BinaryMessage)

# ── seat state: Coworld Checkpoints (Metta spec 0157) ─────────────────────
#
# What a restarted process needs to carry on as if it had never died: the
# upload/proposal id floors (the server refuses an id at or below one it
# already admitted, so a fresh process restarting at 1 has its calls
# refused as stale), whether the playbook is already installed (a
# re-upload of identical bytes under an admitted id is silently idempotent,
# so a fresh process would wait out the upload deadline per module), and
# the standing ladder. Status ordinals are NOT saved: they are connection
# bookkeeping, and a new connection is redelivered whatever it has not
# acknowledged.

const SeatStateVersion = 1

proc stateJson(seat: S2Seat, tick: int): JsonNode =
  %*{
    "version": SeatStateVersion,
    "policy": "baseline/s2play",
    "slot": seat.slot,
    "tick": tick,
    "uploaded": seat.uploaded,
    "ready_count": seat.readyCount,
    "next_upload_id": $seat.nextUploadId,
    "next_proposal_id": $seat.nextProposalId,
    "standing_ladder": seat.standingPayload,
    "restores": seat.restores,
    "checkpoints": seat.checkpoints
  }

proc saveSeatState(seat: S2Seat, tick: int) =
  ## Writes COWORLD_PLAYER_STATE_OUT atomically (temp file + rename), so a
  ## SIGKILL never leaves a torn file. BASELINE_DISCARD_STATE=1 skips the
  ## write (acknowledging anyway) to demonstrate mid-episode amnesia.
  let path = getEnv("COWORLD_PLAYER_STATE_OUT")
  if path.len == 0 or getEnv("BASELINE_DISCARD_STATE") == "1":
    return
  let tmp = path & ".tmp"
  writeFile(tmp, $seat.stateJson(tick))
  moveFile(tmp, path)

proc loadSeatState(seat: var S2Seat) =
  ## Restores COWORLD_PLAYER_STATE_IN when it names a non-empty file.
  let path = getEnv("COWORLD_PLAYER_STATE_IN")
  if path.len == 0 or not fileExists(path) or getFileSize(path) == 0:
    return
  let node = parseJson(readFile(path))
  if node{"version"}.getInt(0) != SeatStateVersion:
    echo "s2 seat state: unknown version in ", path, ", starting fresh"
    return
  seat.uploaded = node{"uploaded"}.getBool(false)
  seat.readyCount = node{"ready_count"}.getInt(0)
  seat.nextUploadId = max(seat.nextUploadId, jsonU64(node{"next_upload_id"}))
  seat.nextProposalId = max(seat.nextProposalId,
    jsonU64(node{"next_proposal_id"}))
  seat.standingPayload = node{"standing_ladder"}.getStr("")
  seat.checkpoints = node{"checkpoints"}.getInt(0)
  seat.restores = node{"restores"}.getInt(0) + 1
  echo "s2 seat state restored from ", path, ": tick=",
    node{"tick"}.getInt(-1), " uploaded=", seat.uploaded,
    " next_upload_id=", seat.nextUploadId,
    " next_proposal_id=", seat.nextProposalId,
    " restores=", seat.restores

proc handleText(seat: var S2Seat, data: string) =
  ## TEXT frames carry the checkpoint handshake (the play-seat protocol
  ## itself is binary-only): save, then acknowledge within the 2 s budget.
  var node: JsonNode
  try:
    node = parseJson(data)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr("") != "checkpoint":
    return
  let tick = node{"tick"}.getInt(-1)
  inc seat.checkpoints
  seat.saveSeatState(tick)
  seat.ws.send($(%*{"type": "checkpoint_ack", "tick": tick}), TextMessage)
  echo "s2 checkpoint tick=", tick, " saved=",
    getEnv("COWORLD_PLAYER_STATE_OUT").len > 0 and
      getEnv("BASELINE_DISCARD_STATE") != "1"

proc drainOnce(seat: var S2Seat, timeoutMs: int) =
  ## Reads at most one websocket message. A Ping is answered with Pong (the
  ## one non-shell byte this client ever sends); anything that is not a
  ## shell packet (a stray legacy Sprite frame, per the codec's own
  ## `spkIgnored` note) is dropped.
  let msg = seat.ws.receiveMessage(timeoutMs)
  if msg.isNone:
    return
  case msg.get.kind
  of Ping:
    seat.ws.send(msg.get.data, Pong)
  of BinaryMessage:
    seat.file(decodeServerPacket(msg.get.data))
  of TextMessage:
    seat.handleText(msg.get.data)
  of Pong:
    discard

proc drain(seat: var S2Seat, seconds: float) =
  let deadline = epochTime() + seconds
  while true:
    let remaining = deadline - epochTime()
    if remaining <= 0:
      return
    seat.drainOnce(int(remaining * 1000.0))

proc awaitStatus(seat: var S2Seat,
    predicate: proc(s: JsonNode): bool {.closure.}, seconds: float): JsonNode =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    for s in seat.statuses:
      if predicate(s):
        return s
    seat.pump()
    seat.drain(0.4)
  nil

proc upload(seat: var S2Seat, name, blob: string): bool =
  let uploadId = seat.nextUploadId
  inc seat.nextUploadId
  let idStr = $uploadId
  seat.ws.send(encodeModuleUpload(uploadId, blob), BinaryMessage)
  let accepted = seat.awaitStatus(
    proc(s: JsonNode): bool =
      s{"upload_id"}.getStr("") == idStr and
        s{"kind"}.getStr("") in ["module_accepted", "module_rejected"],
    UploadDeadlineSeconds)
  if accepted.isNil:
    echo "s2 upload ", name, ": no admission status before timeout"
    return false
  if accepted{"kind"}.getStr("") == "module_rejected":
    echo "s2 upload ", name, " REJECTED: ", accepted{"reason"}.getStr("")
    return false
  let ready = seat.awaitStatus(
    proc(s: JsonNode): bool =
      s{"upload_id"}.getStr("") == idStr and
        s{"kind"}.getStr("") in ["module_ready", "module_rejected"],
    UploadDeadlineSeconds)
  if ready.isNil or ready{"kind"}.getStr("") != "module_ready":
    echo "s2 upload ", name, ": no module_ready"
    return false
  echo "s2 upload ", name, " READY"
  true

proc call(seat: var S2Seat, payload, label: string): bool =
  let proposalId = seat.nextProposalId
  inc seat.nextProposalId
  let idStr = $proposalId
  seat.ws.send(encodePlayCall(proposalId, payload), BinaryMessage)
  let outcome = seat.awaitStatus(
    proc(s: JsonNode): bool =
      s{"proposal_id"}.getStr("") == idStr and
        s{"kind"}.getStr("") in ["call_accepted", "call_rejected"],
    CallDeadlineSeconds)
  if outcome.isNil:
    echo "s2 ", label, ": no call status before timeout"
    return false
  if outcome{"kind"}.getStr("") == "call_rejected":
    echo "s2 ", label, " REJECTED: ", outcome{"reason"}.getStr("")
    return false
  true

# ── the playbook: read the pre-built reference plays off disk ─────────────

proc playbookDir(): string =
  getEnv("BASELINE_PLAYBOOK", "/playbook")

proc loadPlaybook(): seq[tuple[name, blob: string]] =
  let dir = playbookDir()
  for name in ReferencePlays:
    let path = dir / (name & ".wasm")
    if fileExists(path):
      result.add((name, readFile(path)))
    else:
      echo "s2 playbook: ", path, " not found, skipping ", name

# ── the session ─────────────────────────────────────────────────────────

proc runS2Session*(ws: WebSocket, slot: int, firstMessage: Message) =
  ## Drives one Season 2 play seat end to end: files the PlayContext the
  ## caller already peeked (protocol detection consumed it off the socket),
  ## uploads the reference playbook, sends an opening ladder call, then
  ## maintains the gated ladder against the live view for as long as the
  ## socket stays open.
  ##
  ## Returns only by raising: `WebSocket closed` when the server ends the
  ## match (every play socket is closed then, mirroring the legacy path's
  ## own `receiveMessage` behaviour), or a malformed-packet error. Either
  ## way the SAME outer connect/retry/quit-on-gameover handler in
  ## `baseline.nim`'s `runBot` covers both protocols.
  var seat = initS2Seat(ws, slot)
  seat.loadSeatState()
  seat.file(decodeServerPacket(firstMessage.data))
  if seat.context.isNil:
    raise newException(S2WireError, "PlayContext did not parse")
  echo "baseline slot=", slot, " season2Shell=true -> play seat"

  if seat.uploaded:
    # Restored: the server still holds (or, after a game restore, has
    # re-installed) this seat's playbook and standing ladder.
    echo "s2 playbook: restored, ", seat.readyCount,
      " modules already ready; skipping upload"
  else:
    let playbook = loadPlaybook()
    for (name, blob) in playbook:
      if seat.upload(name, blob):
        inc seat.readyCount
    seat.uploaded = true
    echo "s2 playbook: ", seat.readyCount, "/", playbook.len, " modules ready"

  if seat.standingPayload.len == 0:
    seat.standingPayload = encodeLadder(buildLadder(seat.view, seat.context))
    discard seat.call(seat.standingPayload, "opening call")

  while true:
    seat.pump()
    seat.drain(0.5)
    let payload = encodeLadder(buildLadder(seat.view, seat.context))
    if payload != seat.standingPayload:
      if seat.call(payload, "maintenance"):
        seat.standingPayload = payload
