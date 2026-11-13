## CTF replay-load compatibility frontend.
##
## bitworld remains the format-1 writer and parser. This layer admits the
## explicitly compatible CTF game versions and owns format 2 so its reserved
## shell records can be added without changing bitworld's generic codec.

import
  std/[algorithm, json, strutils, times],
  zippy,
  bitworld/replays as replayCodec,
  build_stamp,
  ../shell/[replay_records, types]

type
  PendingTimedRecord = object
    phase: uint8
    ordinal: int
    bytes: string

  CtfReplayData* = object
    replay*: ReplayData
    shell*: ShellReplayRecords
    keyframeBlob*: string
      ## The raw embedded-keyframe block (spec 0157), or "" for every replay
      ## written without one. Opaque at this layer: replays.nim owns its
      ## encoding (compressed, pointer-width-portable ReplayKeyframes).

  CtfReplayWriter* = object
    enabled*: bool
    shellEpisode*: bool
    lastMasks*: seq[uint8]
    rawLegacy: bool
      ## A RESUMED format-1 writer (spec 0157): bitworld's writer cannot
      ## append to an existing file, so the resumed stream is written here,
      ## byte-identically to bitworld's own record encoders.
    legacyWriter: replayCodec.ReplayWriter
    file: File
    callRecords: seq[seq[string]]
    annotationRecords: seq[seq[string]]
    transcriptRecords: seq[string]
    manifestWritten: bool
    hasPendingTime: bool
    pendingTime: uint32
    pendingOrdinal: int
    pendingTimedRecords: seq[PendingTimedRecord]

const
  ShellReplayFormatVersion* = 2'u16

proc writeU8(file: File, value: uint8) =
  file.write(char(value))

proc writeU16(file: File, value: uint16) =
  file.writeU8(uint8(value and 0xff'u16))
  file.writeU8(uint8(value shr 8))

proc writeU32(file: File, value: uint32) =
  for shift in countup(0, 24, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u32))

proc writeU64(file: File, value: uint64) =
  for shift in countup(0, 56, 8):
    file.writeU8(uint8((value shr shift) and 0xff'u64))

proc writeReplayString(file: File, value: string) =
  if value.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  file.writeU16(uint16(value.len))
  file.write(value)

proc writeRaw(writer: var CtfReplayWriter, bytes: string) =
  if writer.enabled and writer.shellEpisode:
    if writer.manifestWritten:
      raise newException(ReplayError,
        "shell replay manifest is already final")
    writer.file.write(bytes)

proc flushTimedRecords(writer: var CtfReplayWriter) =
  if not writer.enabled or not writer.shellEpisode or
      not writer.hasPendingTime:
    return
  writer.pendingTimedRecords.sort(proc(a, b: PendingTimedRecord): int =
    result = cmp(a.phase, b.phase)
    if result == 0:
      result = cmp(a.ordinal, b.ordinal))
  for record in writer.pendingTimedRecords:
    writer.file.write(record.bytes)
  writer.pendingTimedRecords.setLen(0)
  writer.hasPendingTime = false

proc writeTimed(writer: var CtfReplayWriter, time: uint32, phase: uint8,
    bytes: sink string) =
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  if writer.hasPendingTime and time < writer.pendingTime:
    raise newException(ReplayError, "shell replay timestamps move backward")
  if writer.hasPendingTime and time > writer.pendingTime:
    writer.flushTimedRecords()
  if not writer.hasPendingTime:
    writer.hasPendingTime = true
    writer.pendingTime = time
  writer.pendingTimedRecords.add(PendingTimedRecord(
    phase: phase, ordinal: writer.pendingOrdinal, bytes: move(bytes)))
  inc writer.pendingOrdinal

proc emitTimed(writer: var CtfReplayWriter, time: uint32, phase: uint8,
    bytes: sink string) =
  if writer.rawLegacy:
    writer.file.write(bytes)
  else:
    writer.writeTimed(time, phase, bytes)

proc usesBitworld(writer: CtfReplayWriter): bool =
  not writer.shellEpisode and not writer.rawLegacy

proc ensureSeatBucket(writer: var CtfReplayWriter, seat: uint8) =
  if int(seat) >= writer.callRecords.len:
    raise newException(ReplayError, "shell replay seat is out of range")

proc stampedConfigJson(configJson: string): string =
  ## The header configJson this writer will record, with the engine build
  ## stamp ("engineStamp": tools/sim_sources_stamp.sh hash) added when this
  ## binary carries one. This is the RECORDING side of the mismatch-banner
  ## tiering (see build_stamp.nim): playback compares the recorded stamp to
  ## its own to tell an expected cross-build hash mismatch from a true
  ## same-build determinism break.
  ##
  ## Safe for every reader, old and new: sim_config.nim's `update` reads
  ## keys selectively off the parsed object, so an unknown "engineStamp" is
  ## ignored and the re-simulated config is unchanged. Unstamped builds
  ## (ctfSimSourcesStamp == "", i.e. tests and ad-hoc dev builds) write the
  ## configJson byte-for-byte as before.
  if ctfSimSourcesStamp.len == 0:
    return configJson
  var node: JsonNode
  try:
    node = parseJson(if configJson.len == 0: "{}" else: configJson)
  except CatchableError:
    # A header configJson this writer cannot parse is not this proc's
    # problem to diagnose — record it untouched, exactly as before.
    return configJson
  if node.kind != JObject:
    return configJson
  node["engineStamp"] = %ctfSimSourcesStamp
  $node

proc openReplayWriter*(
  path: string,
  configJson: string,
  spec: ReplaySpec,
  shellEpisode: bool,
  shellSeatCount = 0,
  openedAtMs = 0'u64,
): CtfReplayWriter =
  ## Opens the CTF-owned replay writer. The caller makes the gate decision;
  ## P5a deliberately does not wire this into the live server. Non-shell
  ## output delegates wholly to bitworld's format-1 writer.
  let configJson = stampedConfigJson(configJson)
  result.shellEpisode = shellEpisode
  if not shellEpisode:
    result.legacyWriter = replayCodec.openReplayWriter(path, configJson, spec)
    result.enabled = result.legacyWriter.enabled
    result.lastMasks = result.legacyWriter.lastMasks
    return
  if shellSeatCount < 0 or shellSeatCount > 256:
    raise newException(ReplayError, "shell replay seat count is out of range")
  if path.len == 0:
    return
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.enabled = true
  result.callRecords = newSeq[seq[string]](shellSeatCount)
  result.annotationRecords = newSeq[seq[string]](shellSeatCount)
  result.file.write(spec.magic)
  result.file.writeU16(ShellReplayFormatVersion)
  result.file.writeReplayString(spec.gameName)
  result.file.writeReplayString(spec.gameVersion)
  let timestamp =
    if openedAtMs != 0'u64:
      openedAtMs
    else:
      uint64(toUnix(getTime())) * 1000'u64
  result.file.writeU64(timestamp)
  result.file.writeReplayString(configJson)

proc writeJoin*(writer: var CtfReplayWriter, time: uint32, player: int,
                name: string, slot: int, token: string) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeJoin(writer.legacyWriter, time, player, name, slot, token)
    return
  if name.len > high(uint16).int or token.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  var bytes = ""
  bytes.add(char(ReplayJoinRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((time shr shift) and 0xff'u32)))
  bytes.add(char(uint8(player)))
  bytes.add(char(uint8(name.len and 0xff)))
  bytes.add(char(uint8(name.len shr 8)))
  bytes.add(name)
  let wireSlot = cast[uint16](int16(slot))
  bytes.add(char(uint8(wireSlot and 0xff)))
  bytes.add(char(uint8(wireSlot shr 8)))
  bytes.add(char(uint8(token.len and 0xff)))
  bytes.add(char(uint8(token.len shr 8)))
  bytes.add(token)
  writer.emitTimed(time, 0, move(bytes))

proc writeJoin*(writer: var CtfReplayWriter, time: uint32, player: int,
                address: string) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeJoin(writer.legacyWriter, time, player, address)
    return
  if address.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  var bytes = ""
  bytes.add(char(ReplayJoinRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((time shr shift) and 0xff'u32)))
  bytes.add(char(uint8(player)))
  bytes.add(char(uint8(address.len and 0xff)))
  bytes.add(char(uint8(address.len shr 8)))
  bytes.add(address)
  writer.emitTimed(time, 0, move(bytes))

proc writeLeave*(writer: var CtfReplayWriter, time: uint32, player: int) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeLeave(writer.legacyWriter, time, player)
    return
  var bytes = ""
  bytes.add(char(ReplayLeaveRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((time shr shift) and 0xff'u32)))
  bytes.add(char(uint8(player)))
  writer.emitTimed(time, 0, move(bytes))

proc writeInput*(writer: var CtfReplayWriter, input: ReplayInput) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeInput(writer.legacyWriter, input)
    return
  var bytes = ""
  bytes.add(char(ReplayInputRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((input.time shr shift) and 0xff'u32)))
  bytes.add(char(input.player))
  bytes.add(char(input.keys))
  writer.emitTimed(input.time, 2, move(bytes))

proc writeChat*(writer: var CtfReplayWriter, time: uint32, player: int,
                message: string) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeChat(writer.legacyWriter, time, player, message)
    return
  if message.len > high(uint16).int:
    raise newException(ReplayError, "Replay string is too long")
  var bytes = ""
  bytes.add(char(ReplayChatRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((time shr shift) and 0xff'u32)))
  bytes.add(char(uint8(player)))
  bytes.add(char(uint8(message.len and 0xff)))
  bytes.add(char(uint8(message.len shr 8)))
  bytes.add(message)
  writer.emitTimed(time, 2, move(bytes))

proc writeDebugSprite*(writer: var CtfReplayWriter, time: uint32,
                       player: int, packet: openArray[uint8]) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeDebugSprite(writer.legacyWriter, time, player, packet)
    return
  if uint64(packet.len) > uint64(high(uint32)):
    raise newException(ReplayError, "Replay byte array is too long")
  var bytes = ""
  bytes.add(char(ReplayDebugSpriteRecord))
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((time shr shift) and 0xff'u32)))
  bytes.add(char(uint8(player)))
  let length = uint32(packet.len)
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((length shr shift) and 0xff'u32)))
  for value in packet:
    bytes.add(char(value))
  writer.emitTimed(time, 2, move(bytes))

proc writeHash*(writer: var CtfReplayWriter, tick: uint32, hash: uint64) =
  if not writer.enabled:
    return
  if writer.usesBitworld:
    replayCodec.writeHash(writer.legacyWriter, tick, hash)
    return
  if writer.manifestWritten:
    raise newException(ReplayError, "shell replay manifest is already final")
  if not writer.rawLegacy:
    writer.flushTimedRecords()
  writer.file.writeU8(ReplayTickHashRecord)
  writer.file.writeU32(tick)
  writer.file.writeU64(hash)
  writer.file.flushFile()

proc writePlayCall*(writer: var CtfReplayWriter, record: PlayCallRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(record.seat)
  let bytes = record.encodePlayCallRecord()
  writer.callRecords[int(record.seat)].add(bytes)
  writer.writeTimed(record.replayTimeMs, 4, bytes)

proc writeAnnotation*(writer: var CtfReplayWriter,
                      annotation: ShellAnnotation) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(annotation.seat)
  let bytes = annotation.encodeAnnotationRecord()
  writer.annotationRecords[int(annotation.seat)].add(bytes)
  writer.writeRaw(bytes)

proc writeLobbyChat*(writer: var CtfReplayWriter, record: LobbyChatRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  let bytes = record.encodeLobbyChatRecord()
  writer.transcriptRecords.add(bytes)
  writer.writeTimed(record.replayTimeMs, 3, bytes)

proc writeBallot*(writer: var CtfReplayWriter, record: BallotRecord) =
  ## `0x17` is hash-coupled, not manifest-arm'd (settled 2c2f905c) -- unlike
  ## `writeLobbyChat` above, there is no `transcriptRecords`-style
  ## accumulator to feed. This writer proc exists for tooling that needs to
  ## produce a real format-2 fixture with a ballot on it (no live casting
  ## path exists yet -- see sim_types.nim's VoteTicksDefault comment); the
  ## eventual live classifier lane can reuse it unchanged.
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.writeRaw(record.encodeBallotRecord())

proc writeLifecycle*(writer: var CtfReplayWriter, record: LifecycleRecord) =
  if not writer.enabled:
    return
  if not writer.shellEpisode:
    raise newException(ReplayError, "shell record requires format 2")
  writer.ensureSeatBucket(record.seat)
  writer.writeTimed(record.replayTimeMs, 1, record.encodeLifecycleRecord())

proc writeManifest*(writer: var CtfReplayWriter) =
  if not writer.enabled or not writer.shellEpisode or writer.manifestWritten:
    return
  writer.flushTimedRecords()
  let manifest = buildShellReplayManifest(
    writer.callRecords, writer.annotationRecords, writer.transcriptRecords)
  writer.writeRaw(manifest.encodeManifestRecord())
  writer.manifestWritten = true

proc flushReplayWriter*(writer: var CtfReplayWriter) =
  if not writer.enabled:
    return
  if writer.shellEpisode:
    writer.flushTimedRecords()
    writer.file.flushFile()
  elif writer.rawLegacy:
    writer.file.flushFile()
  else:
    replayCodec.flushReplayWriter(writer.legacyWriter)

proc closeReplayWriter*(writer: var CtfReplayWriter) =
  if not writer.enabled:
    return
  if writer.shellEpisode:
    writer.writeManifest()
    writer.file.flushFile()
    writer.file.close()
  elif writer.rawLegacy:
    writer.file.flushFile()
    writer.file.close()
  else:
    replayCodec.closeReplayWriter(writer.legacyWriter)
  writer.enabled = false

proc abandonReplayWriter*(writer: var CtfReplayWriter) =
  ## Closes the file WITHOUT finalizing it (no format-2 manifest). Used when
  ## a resumed server replaces the writer it opened at boot with one that
  ## continues a checkpoint's record stream (spec 0157).
  if not writer.enabled:
    return
  if writer.shellEpisode or writer.rawLegacy:
    writer.file.close()
  else:
    replayCodec.closeReplayWriter(writer.legacyWriter)
  writer.enabled = false

proc readU8(bytes: string, offset: var int): uint8 =
  if offset + 1 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = bytes[offset].uint8
  inc offset

proc readU16(bytes: string, offset: var int): uint16 =
  if offset + 2 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  result = uint16(bytes[offset].uint8) or
    (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readI16(bytes: string, offset: var int): int =
  let wireValue = bytes.readU16(offset)
  # The slot field is normatively signed i16; read its complete unsigned wire
  # representation first, then reinterpret that bounded value.
  int(cast[int16](wireValue))

proc readU32(bytes: string, offset: var int): uint32 =
  if offset + 4 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[offset].uint8) shl shift)
    inc offset

proc readU64(bytes: string, offset: var int): uint64 =
  if offset + 8 > bytes.len:
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[offset].uint8) shl shift)
    inc offset

proc readReplayString(bytes: string, offset: var int): string =
  let
    length = bytes.readU16(offset)
    remaining = bytes.len - offset
  # Length is attacker-controlled. Bound the unsigned value before the int
  # conversion so wasm32 never narrows it into a signed domain first.
  if uint64(length) > uint64(remaining):
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  let checkedLength = int(length)
  result = bytes[offset ..< offset + checkedLength]
  offset += checkedLength

proc readReplayBytes(bytes: string, offset: var int): seq[uint8] =
  let
    length = bytes.readU32(offset)
    remaining = bytes.len - offset
  # Replay u32 values are checked unsigned before any int conversion; wasm32 is a first-class viewer target (§8).
  if uint64(length) > uint64(remaining):
    raise newException(ReplayError, "Replay file is truncated at byte " & $offset)
  let checkedLength = int(length)
  result = newSeq[uint8](checkedLength)
  for index in 0 ..< checkedLength:
    result[index] = bytes[offset + index].uint8
  offset += checkedLength

proc isCompressedReplayBytes(bytes: string): bool =
  if bytes.len > 18:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
      b2 = bytes[2].uint8
      b3 = bytes[3].uint8
    if b0 == 31'u8 and b1 == 139'u8 and b2 == 8'u8 and
        (b3 and 224'u8) == 0'u8:
      return true

  if bytes.len > 6:
    let
      b0 = bytes[0].uint8
      b1 = bytes[1].uint8
    if (b0 and 15'u8) == 8'u8 and (b0 shr 4) <= 7'u8 and
        ((uint16(b0) * 256'u16 + uint16(b1)) mod 31'u16) == 0'u16:
      return true

proc replayPayloadBytes(bytes: string, spec: ReplaySpec): string =
  if bytes.startsWith(spec.magic):
    return bytes
  if spec.allowCompressed and bytes.isCompressedReplayBytes():
    return uncompress(bytes)
  bytes

const
  KeyframeTrailerMagic* = "CTFKEYF1"
    ## Embedded replay keyframes (Metta spec 0157) ride AFTER the complete
    ## record stream as a trailer:
    ##
    ##   <format-1 or format-2 replay bytes, unchanged>
    ##   <keyframe block: N bytes>
    ##   <u64 little-endian N>
    ##   "CTFKEYF1"
    ##
    ## A trailer rather than a new record type because format 1 is parsed by
    ## bitworld's generic codec and format 2 requires its manifest to be the
    ## final record — neither can grow an in-stream record without changing a
    ## parser this repo does not own. Readers that know the trailer strip it
    ## before parsing, so the record stream (and its hashes and manifest
    ## chains) is byte-for-byte what the live writer produced. Legacy replays
    ## have no trailer and parse exactly as before. Readers OLDER than the
    ## trailer reject a keyframed file ("Unknown replay record type"), which
    ## is why embedding is opt-in.
  KeyframeTrailerFooterLen = 16

proc splitKeyframeTrailer*(payload: string): tuple[body, blob: string] =
  ## Splits an uncompressed replay payload into its record stream and its
  ## embedded keyframe block ("" when the payload carries none).
  if payload.len < KeyframeTrailerFooterLen or
      not payload.endsWith(KeyframeTrailerMagic):
    return (payload, "")
  var offset = payload.len - KeyframeTrailerFooterLen
  var blobLen = 0'u64
  for shift in countup(0, 56, 8):
    blobLen = blobLen or (uint64(payload[offset].uint8) shl shift)
    inc offset
  let bodyEnd = uint64(payload.len - KeyframeTrailerFooterLen)
  if blobLen > bodyEnd:
    raise newException(ReplayError, "replay keyframe trailer is truncated")
  let blobStart = int(bodyEnd - blobLen)
  (payload[0 ..< blobStart],
    payload[blobStart ..< payload.len - KeyframeTrailerFooterLen])

proc appendKeyframeTrailer*(body, blob: string): string =
  ## Appends one keyframe block to an uncompressed replay record stream that
  ## carries no trailer yet.
  result = body
  result.add(blob)
  let length = uint64(blob.len)
  for shift in countup(0, 56, 8):
    result.add(char(uint8((length shr shift) and 0xff'u64)))
  result.add(KeyframeTrailerMagic)

proc replayRecordBytes*(bytes: string, spec: ReplaySpec): string =
  ## The uncompressed record stream of one replay file, without any embedded
  ## keyframe trailer.
  bytes.replayPayloadBytes(spec).splitKeyframeTrailer().body

proc isCompatible(
  gameVersion: string,
  compatibleGameVersions: openArray[string]
): bool =
  for compatibleVersion in compatibleGameVersions:
    if gameVersion == compatibleVersion:
      return true

proc readHeader(
  replayBytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string],
  offset: var int
): tuple[formatVersion: uint16, data: ReplayData] =
  if replayBytes.len < spec.magic.len:
    raise newException(ReplayError, "Replay file is truncated")
  if replayBytes[0 ..< spec.magic.len] != spec.magic:
    raise newException(ReplayError, "Replay magic does not match")
  offset = spec.magic.len
  result.formatVersion = replayBytes.readU16(offset)
  if result.formatVersion notin [1'u16, 2'u16]:
    raise newException(ReplayError, "Unsupported replay format version")
  result.data.gameName = replayBytes.readReplayString(offset)
  result.data.gameVersion = replayBytes.readReplayString(offset)
  discard replayBytes.readU64(offset)
  result.data.configJson = replayBytes.readReplayString(offset)
  if result.data.gameName != spec.gameName:
    raise newException(ReplayError, "Replay game name does not match")
  if not result.data.gameVersion.isCompatible(compatibleGameVersions):
    raise newException(
      ReplayError,
      "Replay game version " & result.data.gameVersion.escape() &
        " is not compatible"
    )

proc readJoin(
  replayBytes: string,
  offset: var int,
  spec: ReplaySpec
): ReplayJoin =
  result.time = replayBytes.readU32(offset)
  result.player = replayBytes.readU8(offset)
  case spec.joinKind
  of rjkNameSlotToken:
    result.name = replayBytes.readReplayString(offset)
    result.slot = replayBytes.readI16(offset)
    result.token = replayBytes.readReplayString(offset)
  of rjkAddress:
    result.address = replayBytes.readReplayString(offset)
    result.name = result.address

proc playSeatsFromConfig(configJson: string): seq[bool] =
  try:
    let config = parseJson(configJson)
    if config.kind != JObject or not config.hasKey("slots") or
        config["slots"].kind != JArray:
      return
    for slot in config["slots"]:
      result.add(
        slot.kind == JObject and slot.hasKey("control") and
        slot["control"].kind == JString and
        slot["control"].getStr() == "play")
  except JsonParsingError:
    raise newException(ReplayError, "Replay config JSON is invalid")

proc noteRecordOrder(time: uint32, phase: uint8, name: string,
                     hasTime: var bool, lastTime: var uint32,
                     lastPhase: var uint8) =
  ## At one replay time: join/legacy leave; lifecycle; ordinary Sprite
  ## input/chat; lobby transcript; call. A later phase may not be followed by
  ## an earlier one at the same time.
  if hasTime and time < lastTime:
    raise newException(ReplayError,
      "Replay record timestamps move backward at " & name)
  if hasTime and time == lastTime and phase < lastPhase:
    raise newException(ReplayError,
      "Replay same-time record ordering violation at " & name)
  if not hasTime or time > lastTime:
    lastPhase = phase
  else:
    lastPhase = max(lastPhase, phase)
  lastTime = time
  hasTime = true

proc verifyManifest(
  manifest: ShellReplayManifest,
  calls: openArray[tuple[seat: uint8, bytes: string]],
  annotations: openArray[tuple[seat: uint8, bytes: string]],
  transcript: openArray[string],
) =
  let seatCount = manifest.seats.len
  var
    callBuckets = newSeq[seq[string]](seatCount)
    annotationBuckets = newSeq[seq[string]](seatCount)
  for item in calls:
    if int(item.seat) >= seatCount:
      raise newException(ReplayError, "play-call seat is out of range")
    callBuckets[int(item.seat)].add(item.bytes)
  for item in annotations:
    if int(item.seat) >= seatCount:
      raise newException(ReplayError, "annotation seat is out of range")
    annotationBuckets[int(item.seat)].add(item.bytes)
  let computed = buildShellReplayManifest(
    callBuckets, annotationBuckets, transcript)
  for seat in 0 ..< seatCount:
    if manifest.seats[seat].callCount != computed.seats[seat].callCount or
        manifest.seats[seat].callChainSha256 !=
          computed.seats[seat].callChainSha256:
      raise newException(ReplayError,
        "play-call manifest verification failed for seat " & $seat)
    if manifest.seats[seat].annotationCount !=
          computed.seats[seat].annotationCount or
        manifest.seats[seat].annotationChainSha256 !=
          computed.seats[seat].annotationChainSha256:
      raise newException(ReplayError,
        "annotation manifest verification failed for seat " & $seat)
  if manifest.transcriptCount != computed.transcriptCount or
      manifest.transcriptChainSha256 != computed.transcriptChainSha256:
    raise newException(ReplayError,
      "lobby transcript manifest verification failed")

type
  ShellRecordBuckets* = object
    ## The manifest-arm'd record bytes of a format-2 record stream, in file
    ## order, as the writer accumulates them (spec 0157 live resume).
    calls*: seq[tuple[seat: uint8, bytes: string]]
    annotations*: seq[tuple[seat: uint8, bytes: string]]
    transcript*: seq[string]

proc parseFormat2Records(
  replayBytes: string,
  offset: var int,
  spec: ReplaySpec,
  result: var CtfReplayData,
  buckets: var ShellRecordBuckets,
  requireManifest = true,
) =
  let configuredPlaySeats = result.replay.configJson.playSeatsFromConfig()
  var
    lastTick = 0'u32
    hasLastTick = false
    lastInputTime = 0'u32
    lastJoinTime = 0'u32
    lastLeaveTime = 0'u32
    lastChatTime = 0'u32
    lastDebugSpriteTime = 0'u32
    hasRecordTime = false
    lastRecordTime = 0'u32
    lastRecordPhase = 0'u8
    hasLobbyOrdinal = false
    lastLobbyOrdinal = 0'u64
    hasBallotOrdinal = false
    lastBallotOrdinal = 0'u64
    hasAnnotationTick: array[256, bool]
    lastAnnotationTick: array[256, uint32]
    callBytes: seq[tuple[seat: uint8, bytes: string]]
    annotationBytes: seq[tuple[seat: uint8, bytes: string]]
    transcriptBytes: seq[string]
    sawShellRecord = false
    sawManifest = false
    lifecycle = initLifecyclePlayback(configuredPlaySeats)
  while offset < replayBytes.len:
    let
      recordStart = offset
      recordType = replayBytes.readU8(offset)
    try:
      case recordType
      of ReplayTickHashRecord:
        let
          tick = replayBytes.readU32(offset)
          hash = replayBytes.readU64(offset)
        # u32 stays unsigned: high-bit ticks are legal on wasm32.
        if hasLastTick and tick <= lastTick:
          case spec.hashOrder
          of rhoStop:
            break
          of rhoError:
            raise newException(ReplayError,
              "Replay tick hashes move backward")
        lastTick = tick
        hasLastTick = true
        result.replay.hashes.add(ReplayHash(tick: tick, hash: hash))
      of ReplayInputRecord:
        let input = ReplayInput(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          keys: replayBytes.readU8(offset))
        if input.time < lastInputTime:
          raise newException(ReplayError,
            "Replay input timestamps move backward")
        lastInputTime = input.time
        noteRecordOrder(input.time, 2, "input", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.inputs.add(input)
      of ReplayJoinRecord:
        let join = replayBytes.readJoin(offset, spec)
        if join.time < lastJoinTime:
          raise newException(ReplayError,
            "Replay join timestamps move backward")
        lastJoinTime = join.time
        noteRecordOrder(join.time, 0, "join", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.joins.add(join)
      of ReplayLeaveRecord:
        let leave = ReplayLeave(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset))
        if leave.time < lastLeaveTime:
          raise newException(ReplayError,
            "Replay leave timestamps move backward")
        lastLeaveTime = leave.time
        noteRecordOrder(leave.time, 0, "leave", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.leaves.add(leave)
      of ReplayChatRecord:
        if not spec.allowChat:
          raise newException(ReplayError,
            "Replay chat record is not supported")
        let chat = ReplayChat(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          message: replayBytes.readReplayString(offset))
        if chat.time < lastChatTime:
          raise newException(ReplayError,
            "Replay chat timestamps move backward")
        lastChatTime = chat.time
        noteRecordOrder(chat.time, 2, "chat", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.chats.add(chat)
      of ReplayDebugSpriteRecord:
        let debugSprite = ReplayDebugSprite(
          time: replayBytes.readU32(offset),
          player: replayBytes.readU8(offset),
          packet: replayBytes.readReplayBytes(offset))
        if debugSprite.time < lastDebugSpriteTime:
          raise newException(ReplayError,
            "Replay debug sprite timestamps move backward")
        lastDebugSpriteTime = debugSprite.time
        noteRecordOrder(debugSprite.time, 2, "debug sprite", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.replay.debugSprites.add(debugSprite)
      of RecPlayCall:
        sawShellRecord = true
        offset = recordStart
        let call = replayBytes.decodePlayCallRecord(offset)
        for entry in call.entries:
          if entry.code.kind == cikNative and
              entry.code.nativeGameVersion != result.replay.gameVersion:
            raise newException(ReplayError,
              "native play-call identity GameVersion does not match replay")
        noteRecordOrder(call.replayTimeMs, 4, "play call", hasRecordTime,
          lastRecordTime, lastRecordPhase)
        result.shell.calls.add(call)
        callBytes.add((call.seat, replayBytes[recordStart ..< offset]))
      of RecBehaviorAnnotation:
        sawShellRecord = true
        offset = recordStart
        let annotation = replayBytes.decodeAnnotationRecord(offset)
        let seat = int(annotation.seat)
        if hasAnnotationTick[seat] and
            annotation.tick < lastAnnotationTick[seat]:
          raise newException(ReplayError,
            "Replay annotation ticks move backward for seat " & $seat)
        hasAnnotationTick[seat] = true
        lastAnnotationTick[seat] = annotation.tick
        result.shell.annotations.add(annotation)
        annotationBytes.add((annotation.seat,
          replayBytes[recordStart ..< offset]))
      of RecLobbyChat:
        sawShellRecord = true
        offset = recordStart
        let lobby = replayBytes.decodeLobbyChatRecord(offset)
        if hasLobbyOrdinal and lobby.ordinal <= lastLobbyOrdinal:
          raise newException(ReplayError,
            "Replay lobby transcript ordinals are not increasing")
        hasLobbyOrdinal = true
        lastLobbyOrdinal = lobby.ordinal
        noteRecordOrder(lobby.replayTimeMs, 3, "lobby transcript",
          hasRecordTime, lastRecordTime, lastRecordPhase)
        result.shell.lobbyTranscript.add(lobby)
        transcriptBytes.add(replayBytes[recordStart ..< offset])
      of RecVoteReserved:
        # docs/designs/prematch-vote-wire-2026-08-31.md §4: `0x17`, placed
        # under the same tick-ordering rule `0x13` follows (one time value
        # after that tick's join/leave/rebind, before any call record) and
        # in ordinal order like the lobby transcript above. Unlike
        # `RecLobbyChat`, `0x17` is ruled HASH-COUPLED (settled 2c2f905c: "no
        # manifest arm, ... in-chain under the vote gate, no GV claim") --
        # its integrity is the gameplay tick-hash chain, not a manifest arm,
        # so there is no `transcriptBytes`-style accumulator here. This is a
        # decode-and-retain addition for the replay VIEWER (rendering the
        # ballot); it does not recompute or verify the tally/resolution
        # section 5 describes.
        sawShellRecord = true
        offset = recordStart
        let ballot = replayBytes.decodeBallotRecord(offset)
        if hasBallotOrdinal and ballot.ordinal <= lastBallotOrdinal:
          raise newException(ReplayError,
            "Replay ballot ordinals are not increasing")
        hasBallotOrdinal = true
        lastBallotOrdinal = ballot.ordinal
        noteRecordOrder(ballot.replayTimeMs, 3, "ballot",
          hasRecordTime, lastRecordTime, lastRecordPhase)
        result.shell.ballots.add(ballot)
      of RecDisconnect, RecKick, RecRebind:
        sawShellRecord = true
        if replayBytes.len - recordStart < 6:
          raise newException(ReplayError,
            "Replay file is truncated at byte " & $recordStart)
        let lifecycleBytes = replayBytes[recordStart ..< recordStart + 6]
        offset = recordStart + 6
        let record = decodeLifecycleRecord(lifecycleBytes)
        noteRecordOrder(record.replayTimeMs, 1, "lifecycle",
          hasRecordTime, lastRecordTime, lastRecordPhase)
        lifecycle.applyLifecycleRecord(record)
        result.shell.lifecycle.add(record)
      of RecManifest:
        sawShellRecord = true
        if sawManifest:
          raise newException(ReplayError, "duplicate shell replay manifest")
        offset = recordStart
        result.shell.manifest = replayBytes.decodeManifestRecord(offset)
        if configuredPlaySeats.len > 0 and
            result.shell.manifest.seats.len != configuredPlaySeats.len:
          raise newException(ReplayError,
            "shell manifest seat count does not match replay config")
        sawManifest = true
        if offset != replayBytes.len:
          raise newException(ReplayError,
            "shell replay manifest must be the final record")
        verifyManifest(result.shell.manifest, callBytes, annotationBytes,
          transcriptBytes)
        result.shell.manifestVerified = true
      else:
        raise newException(ReplayError, "Unknown replay record type")
    except ReplayRecordError as error:
      raise newException(ReplayError, error.msg)
    except LifecycleRecordError as error:
      raise newException(ReplayError, "invalid lifecycle record: " & error.msg)
  if requireManifest and sawShellRecord and not sawManifest:
    raise newException(ReplayError, "shell replay manifest is missing")
  if not requireManifest and sawManifest:
    raise newException(ReplayError,
      "replay prefix already carries its final manifest")
  buckets.calls = move(callBytes)
  buckets.annotations = move(annotationBytes)
  buckets.transcript = move(transcriptBytes)

proc parseCtfReplayBytes*(
  bytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): CtfReplayData =
  ## Parses one CTF replay and retains verified format-2 shell metadata.
  let (replayBytes, keyframeBlob) =
    bytes.replayPayloadBytes(spec).splitKeyframeTrailer()
  result.keyframeBlob = keyframeBlob
  var offset = 0
  let header = replayBytes.readHeader(
    spec,
    compatibleGameVersions,
    offset
  )
  if header.formatVersion == 1'u16:
    let compatibleSpec = ReplaySpec(
      magic: spec.magic,
      formatVersion: header.formatVersion,
      gameName: spec.gameName,
      gameVersion: header.data.gameVersion,
      joinKind: spec.joinKind,
      allowChat: spec.allowChat,
      allowCompressed: spec.allowCompressed,
      hashOrder: spec.hashOrder
    )
    result.replay = replayCodec.parseReplayBytes(replayBytes, compatibleSpec)
    return

  result.replay = header.data
  var buckets: ShellRecordBuckets
  replayBytes.parseFormat2Records(offset, spec, result, buckets)

proc parseReplayBytes*(
  bytes: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Compatibility surface for existing playback, which consumes only the
  ## legacy mask/sim streams after shell metadata has verified eagerly.
  parseCtfReplayBytes(bytes, spec, compatibleGameVersions).replay

proc loadReplay*(
  path: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): ReplayData =
  ## Loads one format-1 or format-2 CTF replay from disk.
  parseReplayBytes(readFile(path), spec, compatibleGameVersions)

proc loadCtfReplay*(
  path: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string]
): CtfReplayData =
  parseCtfReplayBytes(readFile(path), spec, compatibleGameVersions)

proc resumeReplayWriter*(
  path: string,
  prefix: string,
  spec: ReplaySpec,
  compatibleGameVersions: openArray[string],
  lastMasks: seq[uint8],
): CtfReplayWriter =
  ## Spec 0157 live resume: reopens `path` as a writer that CONTINUES the
  ## record stream `prefix` (a checkpoint's `replayRecords`: header plus
  ## records, flushed at a tick boundary, no manifest, no keyframe trailer).
  ## The prefix is written back verbatim, so the resumed match yields ONE
  ## replay whose hash chain spans the restart. For format 2 the
  ## manifest-arm'd call/annotation/transcript bytes are re-fed from the
  ## prefix, so the final manifest's chains cover the whole match.
  ## `lastMasks` is the boot writer's input-dedupe state at the checkpoint
  ## (the writer records a mask only when it changes, so it must continue
  ## from the same state).
  if path.len == 0 or prefix.len == 0:
    return
  var offset = 0
  let header = prefix.readHeader(spec, compatibleGameVersions, offset)
  if header.formatVersion == 1'u16:
    result.rawLegacy = true
  else:
    result.shellEpisode = true
    var
      parsed = CtfReplayData(replay: header.data)
      buckets: ShellRecordBuckets
    prefix.parseFormat2Records(offset, spec, parsed, buckets,
      requireManifest = false)
    let seatCount = header.data.configJson.playSeatsFromConfig().len
    result.callRecords = newSeq[seq[string]](seatCount)
    result.annotationRecords = newSeq[seq[string]](seatCount)
    for item in buckets.calls:
      if int(item.seat) >= seatCount:
        raise newException(ReplayError, "play-call seat is out of range")
      result.callRecords[int(item.seat)].add(item.bytes)
    for item in buckets.annotations:
      if int(item.seat) >= seatCount:
        raise newException(ReplayError, "annotation seat is out of range")
      result.annotationRecords[int(item.seat)].add(item.bytes)
    result.transcriptRecords = buckets.transcript
  if not open(result.file, path, fmWrite):
    raise newException(IOError, "Could not open replay file: " & path)
  result.file.write(prefix)
  result.file.flushFile()
  result.enabled = true
  result.lastMasks = lastMasks
