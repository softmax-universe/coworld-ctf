## Bounded tick-boundary ingress for play-seat uploads and calls.
##
## This module owns transport-era identity, count/byte budgets, idempotency,
## and status-capacity reservations. Payload validation and content hashing
## belong to the runtime consumer on the other side of the server seam.

import std/tables

import ./[packets, seats, types]

type
  PlayIngressCounters* = object
    droppedUploads*: uint32
    droppedCalls*: uint32
    backpressure*: uint32
    feedbackErrors*: uint32

  PlayIngressMessageKind* = enum
    pimUpload
    pimCall

  PlayIngressMessage*[Socket] = object
    socket*: Socket
    generation*: uint64
    case kind*: PlayIngressMessageKind
    of pimUpload:
      upload*: ModuleUploadPacket
    of pimCall:
      call*: PlayCallPacket

  PlayIngressInspectResult* = enum
    piiAllowed
    piiStale
    piiDisconnect

  PlayIngressQueueResult* = enum
    piqQueued
    piqDropped

  PlayIngressRefusalKind* = enum
    pirUpload
    pirCall

  PlayIngressRefusal* = object
    kind*: PlayIngressRefusalKind
    generation*: uint64
    id*: uint64
    reason*: string

  PlayIngressFeedback* = object
    ## Lane C reports only outcomes whose retained status entries have been
    ## retired. Proposal ids name calls whose complete outcome set is gone;
    ## still-in-flight calls must not appear here.
    statusSlotsRetired*: int
    retiredProposalIds*: seq[uint64]

  PlayIngressAck*[Socket] = object
    present*: bool
    socket*: Socket
    generation*: uint64
    packet*: StatusAckPacket

  PlayIngressSeat*[Socket] = object
    binding*: PlaySeatBinding[Socket]
    playerIndex*: int
    counters*: PlayIngressCounters
    admittedModules*: int
    admittedUploadBytes*: uint64
    reservedStatusSlots*: int
    hasUploadIdFloor*: bool
    uploadIdFloor*: uint64
    hasProposalIdFloor*: bool
    proposalIdFloor*: uint64
    pending: seq[PlayIngressMessage[Socket]]
    queuedUploads: int
    queuedCalls: int
    classifiedMessages: int
    classifiedBytes: uint64
    pendingAck: PlayIngressAck[Socket]
    uploadPayloads: Table[uint64, string]
    callPayloads: Table[uint64, string]

  PlayIngressDrain*[Socket] = object
    admitted*: seq[PlayIngressMessage[Socket]]
    refusals*: seq[PlayIngressRefusal]
    rejected*: int

  PlayIngressSnapshot* = object
    counters*: PlayIngressCounters
    admittedModules*: int
    admittedUploadBytes*: uint64
    reservedStatusSlots*: int
    uploadIdFloor*: uint64
    proposalIdFloor*: uint64

const
  RegularStatusCapacity = MaxRetainedStatusEntries - StatusFaultReserve
  UploadStatusReservation = 2
  CallStatusReservation = 1 + MaxLadderEntries

proc saturatingInc(value: var uint32) =
  if value < high(uint32):
    inc value

proc initPlayIngressSeat*[Socket](): PlayIngressSeat[Socket] =
  result.binding = initPlaySeatBinding[Socket]()
  result.playerIndex = -1
  result.uploadPayloads = initTable[uint64, string]()
  result.callPayloads = initTable[uint64, string]()

proc uploadHistory*[Socket](seat: PlayIngressSeat[Socket]):
    seq[tuple[uploadId: uint64, wasm: string]] =
  ## Every upload this seat had admitted, in upload-id order (spec 0157).
  for uploadId, wasm in seat.uploadPayloads:
    result.add((uploadId, wasm))
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1].uploadId > result[j].uploadId:
      swap(result[j - 1], result[j])
      dec j

proc restoreUploadHistory*[Socket](seat: var PlayIngressSeat[Socket];
    uploads: openArray[tuple[uploadId: uint64, wasm: string]];
    admittedModules: int; admittedUploadBytes: uint64;
    hasUploadIdFloor: bool; uploadIdFloor: uint64;
    hasProposalIdFloor: bool; proposalIdFloor: uint64) =
  ## Spec 0157 restore: reinstates the per-episode admission history, so a
  ## restored seat keeps its budgets and id floors and an identical
  ## re-upload stays idempotent exactly as it would have in the original.
  for upload in uploads:
    seat.uploadPayloads[upload.uploadId] = upload.wasm
  seat.admittedModules = admittedModules
  seat.admittedUploadBytes = admittedUploadBytes
  seat.hasUploadIdFloor = hasUploadIdFloor
  seat.uploadIdFloor = uploadIdFloor
  seat.hasProposalIdFloor = hasProposalIdFloor
  seat.proposalIdFloor = proposalIdFloor

proc inspectPlayMessage*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  byteCount: int,
): PlayIngressInspectResult =
  if not seat.binding.admits(socket, generation):
    return piiStale
  if byteCount < 0 or
      seat.classifiedMessages >= MaxMessagesClassifiedPerSeatPerTick or
      uint64(byteCount) > uint64(MaxBytesClassifiedPerSeatPerTick) -
        seat.classifiedBytes:
    seat.pending.setLen(0)
    seat.queuedUploads = 0
    seat.queuedCalls = 0
    discard seat.binding.lose(socket)
    return piiDisconnect
  inc seat.classifiedMessages
  seat.classifiedBytes += uint64(byteCount)
  piiAllowed

proc queueUpload*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: sink ModuleUploadPacket,
): PlayIngressQueueResult =
  if seat.queuedUploads >= MaxUploadsPerSeatPerTick:
    seat.counters.droppedUploads.saturatingInc()
    return piqDropped
  inc seat.queuedUploads
  seat.pending.add(PlayIngressMessage[Socket](
    kind: pimUpload,
    socket: socket,
    generation: generation,
    upload: move(packet)))
  piqQueued

proc queueCall*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: sink PlayCallPacket,
): PlayIngressQueueResult =
  if seat.queuedCalls >= MaxCallsPerSeatPerTick:
    seat.counters.droppedCalls.saturatingInc()
    return piqDropped
  inc seat.queuedCalls
  seat.pending.add(PlayIngressMessage[Socket](
    kind: pimCall,
    socket: socket,
    generation: generation,
    call: move(packet)))
  piqQueued

proc queueStatusAck*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: StatusAckPacket,
) =
  ## StatusAck owns one coalescing slot inside the total classification
  ## budget. The greatest well-formed mark is sufficient because marks are
  ## cumulative high-water acknowledgements.
  if not seat.pendingAck.present or packet.mark > seat.pendingAck.packet.mark:
    seat.pendingAck = PlayIngressAck[Socket](
      present: true,
      socket: socket,
      generation: generation,
      packet: packet)

proc takeStatusAck*[Socket](
  seat: var PlayIngressSeat[Socket],
): PlayIngressAck[Socket] =
  result = seat.pendingAck
  seat.pendingAck.present = false
  if result.present and
      not seat.binding.admits(result.socket, result.generation):
    result.present = false

proc evictStalePending*[Socket](seat: var PlayIngressSeat[Socket]) =
  ## Rebind invalidates predecessor payloads but does not create a new tick.
  ## Keep every per-tick counter charged; the real tick drain resets them.
  seat.pending.setLen(0)

proc applyPlayIngressFeedbackStrict*[Socket](
  seat: var PlayIngressSeat[Socket],
  feedback: PlayIngressFeedback,
) =
  if feedback.statusSlotsRetired < 0 or
      feedback.statusSlotsRetired > seat.reservedStatusSlots:
    raise newException(ValueError,
      "play ingress feedback retires unreserved status capacity")
  for proposalId in feedback.retiredProposalIds:
    if proposalId notin seat.callPayloads:
      raise newException(ValueError,
        "play ingress feedback retires an unknown proposal")
  seat.reservedStatusSlots -= feedback.statusSlotsRetired
  for proposalId in feedback.retiredProposalIds:
    seat.callPayloads.del(proposalId)

proc applyPlayIngressFeedback*[Socket](
  seat: var PlayIngressSeat[Socket],
  feedback: PlayIngressFeedback,
): int =
  ## Production feedback is fail-safe: bad retirement accounting must reduce
  ## capacity to honest backpressure, never terminate the tick/runtime thread.
  var retired = feedback.statusSlotsRetired
  if retired < 0:
    retired = 0
    inc result
  elif retired > seat.reservedStatusSlots:
    retired = seat.reservedStatusSlots
    inc result
  seat.reservedStatusSlots -= retired
  for proposalId in feedback.retiredProposalIds:
    if proposalId in seat.callPayloads:
      seat.callPayloads.del(proposalId)
    else:
      inc result
  for _ in 0 ..< result:
    seat.counters.feedbackErrors.saturatingInc()

proc notePlayIngressFeedbackError*[Socket](seat: var PlayIngressSeat[Socket]) =
  ## Completion identities are another production feedback boundary. Unknown
  ## or duplicate outcomes must be counted without manufacturing a retirement.
  seat.counters.feedbackErrors.saturatingInc()

proc hasCallPayload*[Socket](
  seat: PlayIngressSeat[Socket],
  proposalId: uint64,
): bool =
  proposalId in seat.callPayloads

proc reserve[Socket](seat: var PlayIngressSeat[Socket], count: int): bool =
  if count > RegularStatusCapacity - seat.reservedStatusSlots:
    seat.counters.backpressure.saturatingInc()
    return false
  seat.reservedStatusSlots += count
  true

proc refuse[Socket](drain: var PlayIngressDrain[Socket];
                    kind: PlayIngressRefusalKind;
                    generation, id: uint64; reason: string) =
  inc drain.rejected
  drain.refusals.add(PlayIngressRefusal(
    kind: kind, generation: generation, id: id, reason: reason))

proc admitUpload[Socket](
  seat: var PlayIngressSeat[Socket],
  message: sink PlayIngressMessage[Socket],
  drain: var PlayIngressDrain[Socket],
  uploadWindowClosed: bool,
) =
  let packet = message.upload
  if packet.uploadId in seat.uploadPayloads:
    if seat.uploadPayloads[packet.uploadId] != packet.wasm:
      drain.refuse(pirUpload, message.generation, packet.uploadId,
        "upload_id_conflict")
    return
  if seat.hasUploadIdFloor and packet.uploadId <= seat.uploadIdFloor:
    drain.refuse(pirUpload, message.generation, packet.uploadId,
      "upload_id_stale")
    return
  if seat.admittedModules >= MaxModulesPerSeatPerEpisode:
    drain.refuse(pirUpload, message.generation, packet.uploadId,
      "module_budget_exhausted")
    return
  if uint64(packet.wasm.len) >
      uint64(MaxUploadBytesPerSeatPerEpisode) - seat.admittedUploadBytes:
    drain.refuse(pirUpload, message.generation, packet.uploadId,
      "upload_byte_budget_exhausted")
    return
  if uploadWindowClosed:
    drain.refuse(pirUpload, message.generation, packet.uploadId,
      "uploadWindowClosed")
    return
  if not seat.reserve(UploadStatusReservation):
    drain.refuse(pirUpload, message.generation, packet.uploadId,
      "status_backpressure")
    return
  inc seat.admittedModules
  seat.admittedUploadBytes += uint64(packet.wasm.len)
  seat.hasUploadIdFloor = true
  seat.uploadIdFloor = packet.uploadId
  seat.uploadPayloads[packet.uploadId] = packet.wasm
  drain.admitted.add(move(message))

proc admitCall[Socket](
  seat: var PlayIngressSeat[Socket],
  message: sink PlayIngressMessage[Socket],
  drain: var PlayIngressDrain[Socket],
) =
  let packet = message.call
  if packet.proposalId in seat.callPayloads:
    if seat.callPayloads[packet.proposalId] != packet.callBytes:
      drain.refuse(pirCall, message.generation, packet.proposalId,
        "proposal_id_conflict")
    return
  if seat.hasProposalIdFloor and packet.proposalId <= seat.proposalIdFloor:
    drain.refuse(pirCall, message.generation, packet.proposalId,
      "proposal_id_stale")
    return
  if not seat.reserve(CallStatusReservation):
    drain.refuse(pirCall, message.generation, packet.proposalId,
      "status_backpressure")
    return
  seat.hasProposalIdFloor = true
  seat.proposalIdFloor = packet.proposalId
  seat.callPayloads[packet.proposalId] = packet.callBytes
  drain.admitted.add(move(message))

proc drainPlayIngress*[Socket](
  seat: var PlayIngressSeat[Socket],
  uploadWindowClosed: bool,
): PlayIngressDrain[Socket] =
  let pending = move(seat.pending)
  seat.pending = @[]
  seat.queuedUploads = 0
  seat.queuedCalls = 0
  seat.classifiedMessages = 0
  seat.classifiedBytes = 0
  for message in pending:
    if not seat.binding.admits(message.socket, message.generation):
      continue
    case message.kind
    of pimUpload:
      seat.admitUpload(message, result, uploadWindowClosed)
    of pimCall:
      seat.admitCall(message, result)

proc pendingCount*[Socket](seat: PlayIngressSeat[Socket]): int =
  seat.pending.len

proc snapshot*[Socket](seat: PlayIngressSeat[Socket]): PlayIngressSnapshot =
  PlayIngressSnapshot(
    counters: seat.counters,
    admittedModules: seat.admittedModules,
    admittedUploadBytes: seat.admittedUploadBytes,
    reservedStatusSlots: seat.reservedStatusSlots,
    uploadIdFloor: if seat.hasUploadIdFloor: seat.uploadIdFloor else: 0,
    proposalIdFloor: if seat.hasProposalIdFloor: seat.proposalIdFloor else: 0)
