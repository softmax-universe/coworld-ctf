## Per-seat ladder driver for Season 2 plays.
##
## This module owns only tick-boundary ladder semantics. It starts from
## already-validated call bytes and already-bound compiled plays; it performs no
## packet decoding, hashing, validation, compilation, or module-cache work.

import std/options

import crunchy/[common, sha256]

import ../ctf/policy_page
import ../ctf/sim_types
import body_map, call_validation, emit_validator, guards, instance,
  manifest, module_cache, replacement, replay_records, types

type
  LadderEmission* = object
    intent*: Option[Intent]
    goal*: Option[ValidatedGoal]
    policy*: Option[CombatPolicy]
    canonicalBytes*: string
    acceptedTick*: uint32

  LadderInvocationResult* = object
    faulted*: bool
    refused*: bool
    reason*: string
    code*: FaultCode   ## the status `code`; test guests leave it fcUnknown
    emission*: LadderEmission
    logs*: seq[ShellLogRecord]

  LadderLogRecord* = object
    phase*: InvocationKind
    seat*: int
    entryId*: string
    level*: int32
    bytes*: string

  LadderGuest* = ref object
    runInit*: proc(paramsBytes, contextBytes: string): LadderInvocationResult {.closure.}
    runStep*: proc(viewBytes: string; tick: uint32;
      selfPos: BodyPoint): LadderInvocationResult {.closure.}
    runRetune*: proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult {.closure.}
    close*: proc() {.closure.}

  LadderGuestFactory* = proc(seatIndex: int; entry: ValidatedCallEntry,
    emitClass: EmitClass): LadderGuest {.closure.}

  LadderBinding* = object
    manifest*: PlayManifest
    hash*: string
    ready*: bool
    makeGuest*: LadderGuestFactory

  LadderNativeBase* = object
    ## Engine-native base selected above guest controllers: currently an
    ## Appendix R reflex. Ladder keeps this shape generic so it does not import
    ## reflex observer state or body execution code.
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingCallNumber*: uint64

  LadderViewSource* = proc(seatIndex: int; tick: uint32): string {.closure.}

  LadderDefaultSource* = proc(seatIndex: int; tick: uint32):
    tuple[intent: Intent, goal: Option[ValidatedGoal]] {.closure.}

  LadderSeatInput* = object
    alive*: bool
    selfPos*: BodyPoint
    contextBytes*: string
    viewSource*: LadderViewSource
    guardContext*: IntentContext
    defaultSource*: LadderDefaultSource
    nativeBase*: Option[LadderNativeBase]

  LadderStatus* = object
    seat*: int
    entryId*: string
    status*: StatusEntry
    statusBytes*: string

  LadderEntryIdentity* = object
    entryId*: string
    play*: string

  LadderSeatTick* = object
    seat*: int
    callNumber*: uint64
    initialized*: seq[string]
    retuned*: seq[LadderEntryIdentity]
    stepped*: seq[string]
    statuses*: seq[LadderStatus]
    logs*: seq[LadderLogRecord]
    selectedEntryId*: string
    usedDefault*: bool
    stepCount*: int
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingCallNumber*: uint64

  LadderTickResult* = object
    seats*: seq[LadderSeatTick]
    stepCount*: int
    initCount*: int

  LadderCallResult* = object
    accepted*: bool
    reason*: string
    path*: string
    callNumber*: uint64
    ladderBytes*: string
    entries*: seq[PlayCallEntryIdentity]
    status*: StatusEntry
    statusBytes*: string
    pendingRetunes*: seq[LadderEntryIdentity]

  LadderEntrySnapshot* = object
    entryId*: string
    play*: string
    hash*: string
    paramsBytes*: string
    oldParamsBytes*: string
    state*: PlayInstanceState
    originGeneration*: uint64
    hasGuest*: bool
    hasCachedIntent*: bool
    hasCachedPolicy*: bool

  LadderCallSnapshot* = object
    callNumber*: uint64
    proposalId*: uint64
    bytes*: string

  LadderEntry = object
    call: ValidatedCallEntry
    hash: string
    originGeneration: uint64
    guard: Option[CompiledGuard]
    state: PlayInstanceState
    guest: LadderGuest
    cachedIntent: Option[LadderEmission]
    cachedPolicy: Option[LadderEmission]
    oldParamsBytes: string
    callNumber: uint64

  LadderSeat = object
    entries: seq[LadderEntry]
    callNumber: uint64
    acceptedProposalId: uint64
    callBytes: string
    nextStatusOrdinal: uint64

  LadderDriver* = ref object
    seats: seq[LadderSeat]
    nextInitSeat: int
    registry: PathRegistry
    mode: GameMode
    map: BodyMap
    duoSeats: array[Team, DuoSeats]

proc toLadder(invocation: ShellInvocationResult,
              emitClass: EmitClass): LadderInvocationResult =
  result.faulted = invocation.faulted
  result.refused = invocation.refused
  result.reason = invocation.reason
  result.code = invocation.code
  result.logs = invocation.logs
  if invocation.lastAccepted.isSome:
    let accepted = invocation.lastAccepted.get
    result.emission.canonicalBytes = accepted.bytes
    case emitClass
    of ecController:
      result.emission.intent = some(accepted.intent)
      result.emission.goal = accepted.goal
    of ecOverlay:
      result.emission.policy = some(accepted.policy)

proc shellGuest*(instance: ShellInstance,
                 emitClass: EmitClass): LadderGuest =
  ## Adapter for production Wasmtime-backed instances. Tests usually provide a
  ## deterministic fake `LadderGuest` so ladder ordering can be pinned without
  ## tying those cases to guest code.
  new(result)
  result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
    instance.invokeInit(paramsBytes, contextBytes).toLadder(emitClass)
  result.runStep = proc(viewBytes: string; tick: uint32;
      selfPos: BodyPoint): LadderInvocationResult =
    instance.invokeStep(viewBytes, tick, selfPos).toLadder(emitClass)
  result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
    instance.invokeRetune(oldParamsBytes, newParamsBytes).toLadder(emitClass)
  result.close = proc() =
    instance.close()

proc newLadderDriver*(seatCount: int; registry: PathRegistry;
                      mode = gmBr; map: BodyMap = nil;
                      duoSeats: array[Team, DuoSeats] =
                        default(array[Team, DuoSeats])): LadderDriver =
  doAssert seatCount > 0
  new(result)
  result.seats = newSeq[LadderSeat](seatCount)
  result.registry = registry
  result.mode = mode
  result.map = map
  result.duoSeats = duoSeats

proc close(entry: var LadderEntry) =
  if entry.guest != nil and entry.guest.close != nil:
    entry.guest.close()
  entry.guest = nil

proc clearCache(entry: var LadderEntry) =
  entry.cachedIntent = none(LadderEmission)
  entry.cachedPolicy = none(LadderEmission)

proc close*(driver: LadderDriver) =
  if driver == nil:
    return
  for seat in driver.seats.mitems:
    for entry in seat.entries.mitems:
      entry.close()
    seat.entries.setLen(0)

proc newStatusOrdinal(seat: var LadderSeat): uint64 =
  inc seat.nextStatusOrdinal
  seat.nextStatusOrdinal

proc fitStatus(entry: var StatusEntry) =
  while encodeStatusEntry(entry).len > StatusEntryMaxBytes:
    case entry.kind
    of skCallRejected:
      if entry.callReason.len == 0: break
      entry.callReason.setLen(entry.callReason.len - 1)
    of skRetuneRefused, skPlayFaulted:
      if entry.faultReason.len == 0: break
      entry.faultReason.setLen(entry.faultReason.len - 1)
    else:
      break

proc callAcceptedStatus(seat: var LadderSeat; proposalId, generation: uint64;
                        callNumber: uint64; tick: uint32): StatusEntry =
  StatusEntry(kind: skCallAccepted, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, acceptedProposalId: proposalId,
    callNumber: callNumber, tick: tick)

proc callRejectedStatus(seat: var LadderSeat; proposalId, generation: uint64;
                        reason, path: string): StatusEntry =
  result = StatusEntry(kind: skCallRejected, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, rejectedProposalId: proposalId,
    callReason: reason & ":" & path)
  result.fitStatus()

proc playFaultStatus(seat: var LadderSeat; callNumber, generation: uint64;
                     entryId: string; code: FaultCode;
                     reason: string): StatusEntry =
  result = StatusEntry(kind: skPlayFaulted, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, faultCallNumber: callNumber, entryId: entryId,
    faultCode: code, faultReason: reason)
  result.fitStatus()

proc retuneRefusedStatus(seat: var LadderSeat; callNumber, generation: uint64;
                         entryId: string; code: FaultCode;
                         reason: string): StatusEntry =
  result = StatusEntry(kind: skRetuneRefused, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, faultCallNumber: callNumber, entryId: entryId,
    faultCode: code, faultReason: reason)
  result.fitStatus()

proc boundFor(bindings: openArray[LadderBinding],
              name: string): Option[LadderBinding] =
  for binding in bindings:
    if binding.manifest.name == name:
      return some(binding)

proc boundPlays(bindings: openArray[LadderBinding]): seq[BoundPlay] =
  for binding in bindings:
    result.add BoundPlay(manifest: binding.manifest, ready: binding.ready)

proc compiledGuard(bytes: string; registry: PathRegistry): Option[CompiledGuard] =
  if bytes.len == 0:
    none(CompiledGuard)
  else:
    some(compileGuard(bytes, registry))

proc matchingEntry(oldEntries: var seq[LadderEntry],
                   call: ValidatedCallEntry; hash: string): int =
  for index, old in oldEntries:
    if old.call.entryId == call.entryId and old.call.play == call.play and
        old.hash == hash:
      return index
  -1

proc replacementEntry(entry: LadderEntry): ReplacementEntry =
  ReplacementEntry(entryId: entry.call.entryId, playName: entry.call.play,
    moduleHash: entry.hash, paramsBytes: entry.call.paramsBytes,
    state: entry.state)

proc replacementEntry(call: ValidatedCallEntry; hash: string): ReplacementEntry =
  ReplacementEntry(entryId: call.entryId, playName: call.play,
    moduleHash: hash, paramsBytes: call.paramsBytes, retune: call.retune)

proc entrySnapshots*(driver: LadderDriver; seatIndex: int):
    seq[LadderEntrySnapshot] =
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len:
    return
  for entry in driver.seats[seatIndex].entries:
    result.add LadderEntrySnapshot(entryId: entry.call.entryId,
      play: entry.call.play, hash: entry.hash,
      paramsBytes: entry.call.paramsBytes,
      oldParamsBytes: entry.oldParamsBytes, state: entry.state,
      originGeneration: entry.originGeneration, hasGuest: entry.guest != nil,
      hasCachedIntent: entry.cachedIntent.isSome,
      hasCachedPolicy: entry.cachedPolicy.isSome)

proc seatCallNumber*(driver: LadderDriver; seatIndex: int): uint64 =
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len:
    return 0
  driver.seats[seatIndex].callNumber

proc primeCallNumber*(driver: LadderDriver; seatIndex: int;
                      callNumber: uint64) =
  ## Spec 0157 restore: the next accepted call on a still-empty seat takes
  ## `callNumber + 1`, so a re-accepted standing call keeps the number the
  ## restored replay prefix recorded for it.
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len:
    return
  if driver.seats[seatIndex].callNumber == 0:
    driver.seats[seatIndex].callNumber = callNumber

proc callSnapshot*(driver: LadderDriver; seatIndex: int):
    Option[LadderCallSnapshot] =
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len or
      driver.seats[seatIndex].callNumber == 0:
    return none(LadderCallSnapshot)
  let seat = driver.seats[seatIndex]
  some(LadderCallSnapshot(callNumber: seat.callNumber,
    proposalId: seat.acceptedProposalId, bytes: seat.callBytes))

proc acceptCall*(driver: LadderDriver; seatIndex: int; proposalId,
                 originGeneration: uint64; tick: uint32; bytes: sink string;
                 bindings: openArray[LadderBinding];
                 guardContext: IntentContext): LadderCallResult =
  if seatIndex < 0 or seatIndex >= driver.seats.len:
    result.accepted = false
    result.reason = "badSeat"
    result.path = "seat"
    return
  var ctx = CallValidationContext(mode: driver.mode, map: driver.map,
    registry: driver.registry, guardContext: guardContext,
    duoSeats: driver.duoSeats)
  let validated = validateCall(move(bytes), bindings.boundPlays, ctx)
  var seat = addr driver.seats[seatIndex]
  if not validated.accepted:
    result.status = seat[].callRejectedStatus(proposalId, originGeneration,
      validated.reason, validated.path)
    result.statusBytes = encodeStatusEntry(result.status)
    result.reason = validated.reason
    result.path = validated.path
    return

  let nextCallNumber = seat[].callNumber + 1
  var oldEntries = move(seat[].entries)
  var newEntries: seq[LadderEntry]
  for call in validated.entries:
    let binding = bindings.boundFor(call.play).get
    result.entries.add PlayCallEntryIdentity(
      entryId: call.entryId,
      code: CodeIdentity(kind: cikModule, moduleSha256: binding.hash))
    var entry = LadderEntry(call: call, hash: binding.hash,
      originGeneration: originGeneration,
      guard: compiledGuard(call.guardBytes, driver.registry),
      callNumber: nextCallNumber)
    let oldIndex = oldEntries.matchingEntry(call, binding.hash)
    if oldIndex >= 0:
      var old = addr oldEntries[oldIndex]
      let replacement = classifyReplacement([old[].replacementEntry],
        replacementEntry(call, binding.hash))
      case replacement.action
      of raAdoptIdentical:
        entry.state = old[].state
        entry.guest = old[].guest
        entry.cachedIntent = old[].cachedIntent
        entry.cachedPolicy = old[].cachedPolicy
        old[].guest = nil
      of raPendingRetune:
        entry.state = pisPendingRetune
        entry.guest = old[].guest
        entry.oldParamsBytes = replacement.oldParamsBytes
        entry.callNumber = nextCallNumber
        old[].guest = nil
        result.pendingRetunes.add LadderEntryIdentity(entryId: call.entryId,
          play: call.play)
      of raStartAbsent:
        discard
    newEntries.add entry

  for old in oldEntries.mitems:
    old.close()

  seat[].entries = move(newEntries)
  seat[].callNumber = nextCallNumber
  seat[].acceptedProposalId = proposalId
  seat[].callBytes = validated.canonicalBytes
  result.accepted = true
  result.callNumber = nextCallNumber
  result.ladderBytes = seat[].callBytes
  result.status = seat[].callAcceptedStatus(proposalId, originGeneration,
    nextCallNumber, tick)
  result.statusBytes = encodeStatusEntry(result.status)

proc guardPasses(entry: LadderEntry, ctx: IntentContext): bool =
  if entry.state == pisFaulted or entry.state == pisPendingRetune:
    return false
  if entry.guard.isSome:
    return entry.guard.get.evaluate(ctx)
  true

proc emitClass(entry: LadderEntry): EmitClass =
  if entry.call.playClass == mcOverlay: ecOverlay else: ecController

proc bindingFactory(bindings: openArray[LadderBinding],
                    entry: LadderEntry): LadderGuestFactory =
  for binding in bindings:
    if binding.manifest.name == entry.call.play and binding.hash == entry.hash:
      return binding.makeGuest

proc needsInit(entry: LadderEntry, guardActive: bool): bool =
  guardActive and entry.state == pisAbsent and entry.guest == nil

proc entryActiveForInit(entries: openArray[LadderEntry], index: int,
                        ctx: IntentContext): bool =
  let entry = entries[index]
  if entry.call.playClass == mcOverlay:
    return entry.guardPasses(ctx)
  for i in 0 ..< entries.len:
    if entries[i].call.playClass == mcOverlay:
      continue
    if entries[i].guardPasses(ctx):
      return i == index
  false

proc appendStatus(output: var LadderSeatTick; seatIndex: int; entryId: string;
                  status: StatusEntry) =
  output.statuses.add LadderStatus(seat: seatIndex, entryId: entryId,
    status: status, statusBytes: encodeStatusEntry(status))

proc appendLogs(output: var LadderSeatTick; phase: InvocationKind;
                seatIndex: int; entryId: string;
                logs: openArray[ShellLogRecord]) =
  for log in logs:
    output.logs.add LadderLogRecord(phase: phase, seat: seatIndex,
      entryId: entryId, level: log.level, bytes: log.bytes)

proc initializeEntry(driver: LadderDriver; seatIndex, entryIndex: int;
                     input: LadderSeatInput;
                     bindings: openArray[LadderBinding];
                     output: var LadderSeatTick): bool =
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  let factory = bindings.bindingFactory(entry[])
  if factory == nil:
    return false
  entry[].guest = factory(seatIndex, entry[].call, entry[].emitClass)
  if entry[].guest == nil:
    entry[].state = pisFaulted
    let status = seat[].playFaultStatus(seat[].callNumber, entry[].originGeneration,
      entry[].call.entryId, fcInstantiateFailed, "instantiate returned nil")
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  let initResult = entry[].guest.runInit(entry[].call.paramsBytes,
    input.contextBytes)
  output.appendLogs(ivInit, seatIndex, entry[].call.entryId, initResult.logs)
  if initResult.faulted:
    entry[].state = pisFaulted
    entry[].close()
    let status = seat[].playFaultStatus(seat[].callNumber, entry[].originGeneration,
      entry[].call.entryId, initResult.code, initResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  entry[].state = pisLive
  output.initialized.add entry[].call.entryId
  true

proc retuneEntry(driver: LadderDriver; seatIndex, entryIndex: int;
                 bindings: openArray[LadderBinding];
                 output: var LadderSeatTick): bool =
  discard bindings
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  if entry[].guest == nil:
    entry[].state = pisAbsent
    return false
  let retuneResult = entry[].guest.runRetune(entry[].oldParamsBytes,
    entry[].call.paramsBytes)
  output.appendLogs(ivRetune, seatIndex, entry[].call.entryId,
    retuneResult.logs)
  if retuneResult.refused or retuneResult.faulted:
    entry[].state = pisAbsent
    entry[].close()
    let status = seat[].retuneRefusedStatus(seat[].callNumber,
      entry[].originGeneration,
      entry[].call.entryId, retuneResult.code, retuneResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  entry[].state = pisLive
  entry[].oldParamsBytes.setLen(0)
  output.retuned.add LadderEntryIdentity(entryId: entry[].call.entryId,
    play: entry[].call.play)
  true

proc firstInitializationCandidate(seat: LadderSeat,
                                  ctx: IntentContext): int =
  for index in 0 ..< seat.entries.len:
    if seat.entries[index].state == pisPendingRetune:
      return index
    if seat.entries[index].needsInit(seat.entries.entryActiveForInit(index, ctx)):
      return index
  -1

proc scheduleInitializations(driver: LadderDriver;
    inputs: openArray[LadderSeatInput]; bindings: openArray[LadderBinding];
    seatOutputs: var seq[LadderSeatTick]): int =
  if driver.seats.len == 0:
    return
  var
    granted = 0
    scanned = 0
    grantsPerSeat = newSeq[int](driver.seats.len)
  while granted < MaxInitsPerTick and scanned < driver.seats.len:
    let seatIndex = driver.nextInitSeat
    driver.nextInitSeat = (driver.nextInitSeat + 1) mod driver.seats.len
    inc scanned
    if seatIndex >= inputs.len or
        grantsPerSeat[seatIndex] >= MaxInitsPerSeatPerTick:
      continue
    let candidate = driver.seats[seatIndex].firstInitializationCandidate(
      inputs[seatIndex].guardContext)
    if candidate < 0:
      continue
    var succeeded: bool
    if driver.seats[seatIndex].entries[candidate].state == pisPendingRetune:
      succeeded = driver.retuneEntry(seatIndex, candidate, bindings,
        seatOutputs[seatIndex])
    else:
      if not inputs[seatIndex].alive:
        continue
      succeeded = driver.initializeEntry(seatIndex, candidate, inputs[seatIndex],
        bindings, seatOutputs[seatIndex])
    inc granted
    inc grantsPerSeat[seatIndex]
    if not succeeded:
      grantsPerSeat[seatIndex] = MaxInitsPerSeatPerTick
    result = granted
    scanned = 0

proc mergeProtected(target: var ProtectedSet; overlay: ProtectedSet) =
  target.teams = target.teams + overlay.teams
  for seat in overlay.seats:
    if seat notin target.seats:
      target.seats.add seat

proc foldOverlay(target: var CombatPolicy; overlay: CombatPolicy) =
  target.noShoot.mergeProtected(overlay.noShoot)
  target.protect.mergeProtected(overlay.protect)
  var seen: set[PreferTag]
  for tag in target.prefer:
    seen.incl tag
  for tag in overlay.prefer:
    if tag notin seen:
      target.prefer.add tag
      seen.incl tag
  target.holdFire = target.holdFire or overlay.holdFire

proc provenanceFor(entry: LadderEntry; tick: uint32): ProvenanceBase =
  discard tick
  ProvenanceBase(kind: pbEntry, entryId: entry.call.entryId,
    moduleSha256: entry.hash, emitTick: entry.cachedIntent.get.acceptedTick)

proc overlayContribution(entry: LadderEntry; tick: uint32): OverlayContribution =
  discard tick
  OverlayContribution(entryId: entry.call.entryId, moduleSha256: entry.hash,
    acceptedTick: entry.cachedPolicy.get.acceptedTick,
    policySha256: sha256(entry.cachedPolicy.get.canonicalBytes).toHex())

proc sameEmission(a, b: LadderEmission): bool =
  a.canonicalBytes == b.canonicalBytes

proc stepEntry(driver: LadderDriver; seatIndex, entryIndex: int;
               input: LadderSeatInput; tick: uint32;
               viewBytes: var Option[string];
               output: var LadderSeatTick) =
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  if entry[].guest == nil or entry[].state != pisLive:
    return
  if viewBytes.isNone:
    viewBytes = some(input.viewSource(seatIndex, tick))
  let stepResult = entry[].guest.runStep(viewBytes.get, tick, input.selfPos)
  output.appendLogs(ivStep, seatIndex, entry[].call.entryId, stepResult.logs)
  inc output.stepCount
  output.stepped.add entry[].call.entryId
  if stepResult.faulted:
    entry[].state = pisFaulted
    entry[].cachedIntent = none(LadderEmission)
    entry[].cachedPolicy = none(LadderEmission)
    entry[].close()
    let status = seat[].playFaultStatus(seat[].callNumber, entry[].originGeneration,
      entry[].call.entryId, stepResult.code, stepResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return
  if stepResult.emission.intent.isSome:
    var emission = stepResult.emission
    if entry[].cachedIntent.isNone or
        not entry[].cachedIntent.get.sameEmission(emission):
      emission.acceptedTick = tick
      entry[].cachedIntent = some(emission)
  if stepResult.emission.policy.isSome:
    var emission = stepResult.emission
    if entry[].cachedPolicy.isNone or
        not entry[].cachedPolicy.get.sameEmission(emission):
      emission.acceptedTick = tick
      entry[].cachedPolicy = some(emission)

proc livePassingController(seat: LadderSeat, ctx: IntentContext;
                           start = 0): int =
  for index in start ..< seat.entries.len:
    let entry = seat.entries[index]
    if entry.call.playClass != mcOverlay and entry.state == pisLive and
        entry.guardPasses(ctx):
      return index
  -1

proc stepSeat(driver: LadderDriver; seatIndex: int; input: LadderSeatInput;
              tick: uint32; output: var LadderSeatTick) =
  output.seat = seatIndex
  output.callNumber = driver.seats[seatIndex].callNumber
  if not input.alive:
    for entry in driver.seats[seatIndex].entries.mitems:
      if entry.state == pisLive:
        entry.clearCache()
        entry.state = pisParked
    output.usedDefault = true
    output.intent = Intent(kind: ikHold, arriveRadius: 0.0,
      reason: "default:hold")
    output.provenance = Provenance(base: ProvenanceBase(kind: pbDefault))
    return

  var viewBytes = none(string)
  for entry in driver.seats[seatIndex].entries.mitems:
    if entry.state == pisParked:
      entry.clearCache()
      entry.state = pisLive

  for index in 0 ..< driver.seats[seatIndex].entries.len:
    let entry = driver.seats[seatIndex].entries[index]
    if entry.call.playClass == mcOverlay and entry.state == pisLive and
        entry.guardPasses(input.guardContext):
      driver.stepEntry(seatIndex, index, input, tick, viewBytes, output)

  var base: Intent
  var provenance = Provenance(base: ProvenanceBase(kind: pbDefault))
  if input.nativeBase.isSome:
    let native = input.nativeBase.get
    base = native.intent
    output.goal = native.goal
    provenance = native.provenance
    output.contributingCallNumber = max(output.contributingCallNumber,
      native.contributingCallNumber)
    output.usedDefault = false
  else:
    var controllerIndex = driver.seats[seatIndex].livePassingController(
      input.guardContext)
    if controllerIndex >= 0:
      while controllerIndex >= 0:
        output.selectedEntryId =
          driver.seats[seatIndex].entries[controllerIndex].call.entryId
        driver.stepEntry(seatIndex, controllerIndex, input, tick, viewBytes,
          output)
        let controller = driver.seats[seatIndex].entries[controllerIndex]
        if controller.state == pisLive and controller.cachedIntent.isSome:
          base = controller.cachedIntent.get.intent.get
          output.goal = controller.cachedIntent.get.goal
          provenance.base = controller.provenanceFor(tick)
          output.contributingCallNumber = max(output.contributingCallNumber,
            controller.callNumber)
          break
        if controller.state == pisFaulted:
          controllerIndex = driver.seats[seatIndex].livePassingController(
            input.guardContext, controllerIndex + 1)
        else:
          output.usedDefault = true
          break
      if provenance.base.kind == pbDefault:
        output.usedDefault = true
      else:
        output.usedDefault = false
    else:
      output.usedDefault = true

  if output.usedDefault:
    # Resolve once per seat/tick, only after all usable higher bases lose.
    # Keep this result through the overlay fold; never reuse a prior tick.
    let defaultOrder = input.defaultSource(seatIndex, tick)
    base = defaultOrder.intent
    output.goal = defaultOrder.goal

  for entry in driver.seats[seatIndex].entries:
    if entry.call.playClass == mcOverlay and entry.state == pisLive and
        entry.guardPasses(input.guardContext) and entry.cachedPolicy.isSome:
      base.combat.foldOverlay(entry.cachedPolicy.get.policy.get)
      provenance.overlays.add entry.overlayContribution(tick)
      output.contributingCallNumber = max(output.contributingCallNumber, entry.callNumber)

  output.intent = base
  output.provenance = provenance

proc tick*(driver: LadderDriver; inputs: openArray[LadderSeatInput];
           tick: uint32;
           bindings: openArray[LadderBinding]): LadderTickResult =
  doAssert inputs.len == driver.seats.len
  result.seats = newSeq[LadderSeatTick](driver.seats.len)
  result.initCount = driver.scheduleInitializations(inputs, bindings,
    result.seats)
  for seatIndex in 0 ..< driver.seats.len:
    driver.stepSeat(seatIndex, inputs[seatIndex], tick, result.seats[seatIndex])
    result.stepCount += result.seats[seatIndex].stepCount
  doAssert result.stepCount <= driver.seats.len * MaxStepsPerSeatPerTick
