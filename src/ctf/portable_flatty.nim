## Pointer-width-independent flatty encoding for EMBEDDED replay keyframes and
## game checkpoints (Metta spec 0157, "Coworld Checkpoints").
##
## Plain `flatty` writes `int`/`uint` at the native pointer width and memcpys
## every seq/array whose element type `supportsCopyMem` — including objects
## whose padding and `int` fields differ between a 64-bit native server and the
## 32-bit `ctf_replay.wasm` viewer. That is fine for the in-memory keyframes the
## viewer builds for itself (written and read by the same binary), but a
## keyframe the native server embeds in a `.bitreplay` must decode in wasm32.
##
## This module is the same structural walk as flatty with three differences:
## `int`/`uint` are always 64-bit on the wire (a 64-bit value that does not fit
## a 32-bit reader's `int` raises instead of truncating), enums are int64 as in
## flatty, and memcpy is used only for element types whose layout is identical
## on every target (fixed-width scalars). Everything else is walked field by
## field. Field order is the declaration order, exactly as flatty's.

import
  std/[sets, tables, typetraits],
  flatty/binny,
  flatty/objvar

type
  PortableFlattyError* = object of CatchableError
  SomeTable[K, V] = Table[K, V] | OrderedTable[K, V]

proc toPortable*[T](s: var string, x: seq[T])
proc toPortable*(s: var string, x: object)
proc toPortable*[T: distinct](s: var string, x: T)
proc toPortable*[K, V](s: var string, x: SomeTable[K, V])
proc toPortable*[K](s: var string, x: CountTable[K])
proc toPortable*[N, T](s: var string, x: array[N, T])
proc toPortable*[T: tuple](s: var string, x: T)
proc toPortable*[T](s: var string, x: ref T)
proc toPortable*[T](s: var string, x: SomeSet[T])
proc toPortable*[T](s: var string, x: set[T])

proc fromPortable*[T](s: string, i: var int, x: var seq[T])
proc fromPortable*(s: string, i: var int, x: var object)
proc fromPortable*[T: distinct](s: string, i: var int, x: var T)
proc fromPortable*[K, V](s: string, i: var int, x: var SomeTable[K, V])
proc fromPortable*[K](s: string, i: var int, x: var CountTable[K])
proc fromPortable*[N, T](s: string, i: var int, x: var array[N, T])
proc fromPortable*[T: tuple](s: string, i: var int, x: var T)
proc fromPortable*[T](s: string, i: var int, x: var ref T)
proc fromPortable*[T](s: string, i: var int, x: var SomeSet[T])
proc fromPortable*[T](s: string, i: var int, x: var set[T])

template need(s: string, i, n: int) =
  if i < 0 or i + n > s.len:
    raise newException(PortableFlattyError,
      "portable flatty buffer is truncated at byte " & $i)

template isFixedScalar(T: typedesc): bool =
  T is uint8 or T is int8 or T is uint16 or T is int16 or T is uint32 or
    T is int32 or T is uint64 or T is int64 or T is float32 or
    T is float64 or T is char or T is bool

# Scalars --------------------------------------------------------------------

proc toPortable*(s: var string, x: bool) = s.addUint8(uint8(x))
proc toPortable*(s: var string, x: char) = s.addUint8(uint8(x))
proc toPortable*(s: var string, x: uint8) = s.addUint8(x)
proc toPortable*(s: var string, x: int8) = s.addInt8(x)
proc toPortable*(s: var string, x: uint16) = s.addUint16(x)
proc toPortable*(s: var string, x: int16) = s.addInt16(x)
proc toPortable*(s: var string, x: uint32) = s.addUint32(x)
proc toPortable*(s: var string, x: int32) = s.addInt32(x)
proc toPortable*(s: var string, x: uint64) = s.addUint64(x)
proc toPortable*(s: var string, x: int64) = s.addInt64(x)
proc toPortable*(s: var string, x: float32) = s.addFloat32(x)
proc toPortable*(s: var string, x: float64) = s.addFloat64(x)
proc toPortable*(s: var string, x: int) =
  when sizeof(int) == 4:
    # The inverse of fromPortable's sentinel mapping: a 32-bit engine writes
    # its pointer-width-relative sentinels at 64-bit scale.
    if x == low(int): s.addInt64(low(int64))
    elif x == high(int): s.addInt64(high(int64))
    elif x == low(int) div 2: s.addInt64(low(int64) div 2)
    elif x == high(int) div 2: s.addInt64(high(int64) div 2)
    else: s.addInt64(int64(x))
  else:
    s.addInt64(int64(x))
proc toPortable*(s: var string, x: uint) = s.addUint64(uint64(x))

proc fromPortable*(s: string, i: var int, x: var bool) =
  s.need(i, 1); x = s.readUint8(i) != 0; i += 1
proc fromPortable*(s: string, i: var int, x: var char) =
  s.need(i, 1); x = char(s.readUint8(i)); i += 1
proc fromPortable*(s: string, i: var int, x: var uint8) =
  s.need(i, 1); x = s.readUint8(i); i += 1
proc fromPortable*(s: string, i: var int, x: var int8) =
  s.need(i, 1); x = s.readInt8(i); i += 1
proc fromPortable*(s: string, i: var int, x: var uint16) =
  s.need(i, 2); x = s.readUint16(i); i += 2
proc fromPortable*(s: string, i: var int, x: var int16) =
  s.need(i, 2); x = s.readInt16(i); i += 2
proc fromPortable*(s: string, i: var int, x: var uint32) =
  s.need(i, 4); x = s.readUint32(i); i += 4
proc fromPortable*(s: string, i: var int, x: var int32) =
  s.need(i, 4); x = s.readInt32(i); i += 4
proc fromPortable*(s: string, i: var int, x: var uint64) =
  s.need(i, 8); x = s.readUint64(i); i += 8
proc fromPortable*(s: string, i: var int, x: var int64) =
  s.need(i, 8); x = s.readInt64(i); i += 8
proc fromPortable*(s: string, i: var int, x: var float32) =
  s.need(i, 4); x = s.readFloat32(i); i += 4
proc fromPortable*(s: string, i: var int, x: var float64) =
  s.need(i, 8); x = s.readFloat64(i); i += 8

proc fromPortable*(s: string, i: var int, x: var int) =
  s.need(i, 8)
  let wide = s.readInt64(i)
  i += 8
  when sizeof(int) == 4:
    if wide < int64(low(int32)) or wide > int64(high(int32)):
      # Pointer-width-relative sentinels (`low(int) div 2` as "never",
      # `high(int)` as "unbounded", ...) are written by a 64-bit engine at
      # 64-bit scale; map them to the same sentinel at this target's scale.
      # The sim's own init on wasm32 produces exactly these values, so the
      # restored state matches a wasm32 walk. Any other wide value is real
      # data that cannot be narrowed.
      if wide == low(int64): x = low(int)
      elif wide == high(int64): x = high(int)
      elif wide == low(int64) div 2: x = low(int) div 2
      elif wide == high(int64) div 2: x = high(int) div 2
      else:
        raise newException(PortableFlattyError,
          "portable int does not fit this target's 32-bit int")
      return
  x = int(wide)

proc fromPortable*(s: string, i: var int, x: var uint) =
  s.need(i, 8)
  let wide = s.readUint64(i)
  i += 8
  when sizeof(uint) == 4:
    if wide > uint64(high(uint32)):
      raise newException(PortableFlattyError,
        "portable uint does not fit this target's 32-bit uint")
  x = uint(wide)

proc readLen(s: string, i: var int): int =
  var wide: int64
  s.fromPortable(i, wide)
  if wide < 0 or wide > int64(s.len):
    # Every element occupies at least one byte except empty objects; a length
    # beyond the whole buffer is corrupt input, never a real collection.
    raise newException(PortableFlattyError, "portable length is out of range")
  int(wide)

# Enums and ranges -----------------------------------------------------------

proc toPortable*[T: enum and not range](s: var string, x: T) =
  s.addInt64(int64(ord(x)))

proc fromPortable*[T: enum and not range](s: string, i: var int, x: var T) =
  s.need(i, 8)
  x = cast[T](s.readInt64(i))
  i += 8

proc toPortable*[T: range](s: var string, x: T) =
  s.addInt64(int64(x))

proc fromPortable*[T: range](s: string, i: var int, x: var T) =
  s.need(i, 8)
  x = T(s.readInt64(i))
  i += 8

# Strings --------------------------------------------------------------------

proc toPortable*(s: var string, x: string) =
  s.addInt64(int64(x.len))
  s.add(x)

proc fromPortable*(s: string, i: var int, x: var string) =
  let len = s.readLen(i)
  s.need(i, len)
  x = s[i ..< i + len]
  i += len

# Seqs and arrays ------------------------------------------------------------

proc toPortable*[T](s: var string, x: seq[T]) =
  s.addInt64(int64(x.len))
  when isFixedScalar(T) and not defined(js):
    if x.len > 0:
      let byteLen = x.len * sizeof(T)
      s.setLen(s.len + byteLen)
      copyMem(s[s.len - byteLen].addr, x[0].unsafeAddr, byteLen)
  else:
    for e in x:
      s.toPortable(e)

proc fromPortable*[T](s: string, i: var int, x: var seq[T]) =
  let len = s.readLen(i)
  x.setLen(len)
  when isFixedScalar(T) and not defined(js):
    if len > 0:
      let byteLen = len * sizeof(T)
      s.need(i, byteLen)
      copyMem(x[0].addr, s[i].unsafeAddr, byteLen)
      i += byteLen
  else:
    for j in x.mitems:
      s.fromPortable(i, j)

proc toPortable*[N, T](s: var string, x: array[N, T]) =
  when isFixedScalar(T) and not defined(js):
    if x.len > 0:
      let byteLen = x.len * sizeof(T)
      s.setLen(s.len + byteLen)
      copyMem(s[s.len - byteLen].addr, x[low(x)].unsafeAddr, byteLen)
  else:
    for e in x:
      s.toPortable(e)

proc fromPortable*[N, T](s: string, i: var int, x: var array[N, T]) =
  when isFixedScalar(T) and not defined(js):
    if x.len > 0:
      s.need(i, sizeof(x))
      copyMem(x[low(x)].addr, s[i].unsafeAddr, sizeof(x))
      i += sizeof(x)
  else:
    for j in x.mitems:
      s.fromPortable(i, j)

# Built-in bitsets: their byte layout depends only on the base type's range,
# which is the same on every target.
proc toPortable*[T](s: var string, x: set[T]) =
  let byteLen = sizeof(x)
  s.setLen(s.len + byteLen)
  copyMem(s[s.len - byteLen].addr, x.unsafeAddr, byteLen)

proc fromPortable*[T](s: string, i: var int, x: var set[T]) =
  s.need(i, sizeof(x))
  copyMem(x.addr, s[i].unsafeAddr, sizeof(x))
  i += sizeof(x)

# Objects, tuples, distinct, refs -------------------------------------------

proc toPortable*(s: var string, x: object) =
  when x.isObjectVariant:
    s.toPortable(x.discriminatorField)
    for k, e in x.fieldPairs:
      when k != x.discriminatorFieldName:
        s.toPortable(e)
  else:
    for e in x.fields:
      s.toPortable(e)

proc fromPortable*(s: string, i: var int, x: var object) =
  when x.isObjectVariant:
    var discriminator: type(x.discriminatorField)
    s.fromPortable(i, discriminator)
    new(x, discriminator)
    for k, e in x.fieldPairs:
      when k != x.discriminatorFieldName:
        s.fromPortable(i, e)
  else:
    for e in x.fields:
      s.fromPortable(i, e)

proc toPortable*[T: tuple](s: var string, x: T) =
  for e in x.fields:
    s.toPortable(e)

proc fromPortable*[T: tuple](s: string, i: var int, x: var T) =
  for e in x.fields:
    s.fromPortable(i, e)

proc toPortable*[T: distinct](s: var string, x: T) =
  s.toPortable(x.distinctBase)

proc fromPortable*[T: distinct](s: string, i: var int, x: var T) =
  var base: type(x.distinctBase)
  s.fromPortable(i, base)
  x = T(base)

proc toPortable*[T](s: var string, x: ref T) =
  s.toPortable(x == nil)
  if x != nil:
    s.toPortable(x[])

proc fromPortable*[T](s: string, i: var int, x: var ref T) =
  var isNil: bool
  s.fromPortable(i, isNil)
  if isNil:
    x = nil
  else:
    new(x)
    s.fromPortable(i, x[])

# Tables and sets ------------------------------------------------------------

proc toPortable*[K, V](s: var string, x: SomeTable[K, V]) =
  s.addInt64(int64(x.len))
  for k, v in x:
    s.toPortable(k)
    s.toPortable(v)

proc fromPortable*[K, V](s: string, i: var int, x: var SomeTable[K, V]) =
  let len = s.readLen(i)
  for _ in 0 ..< len:
    var
      k: K
      v: V
    s.fromPortable(i, k)
    s.fromPortable(i, v)
    x[k] = v

proc toPortable*[K](s: var string, x: CountTable[K]) =
  s.addInt64(int64(x.len))
  for k, v in x:
    s.toPortable(k)
    s.toPortable(v)

proc fromPortable*[K](s: string, i: var int, x: var CountTable[K]) =
  let len = s.readLen(i)
  for _ in 0 ..< len:
    var
      k: K
      v: int
    s.fromPortable(i, k)
    s.fromPortable(i, v)
    x[k] = v

proc toPortable*[T](s: var string, x: SomeSet[T]) =
  s.addInt64(int64(x.card))
  for e in x:
    s.toPortable(e)

proc fromPortable*[T](s: string, i: var int, x: var SomeSet[T]) =
  let len = s.readLen(i)
  for _ in 0 ..< len:
    var e: T
    s.fromPortable(i, e)
    x.incl(e)

# Entry points ---------------------------------------------------------------

proc toPortableFlatty*[T](x: T): string =
  ## Encodes `x` with pointer-width-independent framing.
  result.toPortable(x)

proc fromPortableFlatty*[T](s: string, x: typedesc[T]): T =
  ## Decodes a `toPortableFlatty` buffer; raises PortableFlattyError on a
  ## truncated buffer, trailing garbage, or a value this target cannot hold.
  var i = 0
  s.fromPortable(i, result)
  if i != s.len:
    raise newException(PortableFlattyError,
      "portable flatty buffer has " & $(s.len - i) & " trailing bytes")
