## Pins addBoardObject's inline wire encoding to bitworld's addObject, byte
## for byte. gameHash mixes only simulation state, so no hash run covers the
## encoder: a transposed field here would leave every hash identical while
## every client decoded garbage. This comparison is the check that does
## cover it.
##
## Includes global.nim to reach the private proc and its boardScale, the
## same way test_replay_requests includes server.nim.
{.warning[UnusedImport]: off.}
include ../src/ctf/global

import std/unittest

suite "addBoardObject wire layout":
  test "byte-identical to addObject at every scale and layer class":
    # Board layers (map, fog) scale x/y by boardScale; everything else
    # passes through. z never scales — low(int16) is what addMapBands
    # really sends. Coordinates are chosen so scale 3 stays inside i16,
    # since both encoders share the same conversion checks.
    const
      objectIds = [0, 1, 913, 65535]
      coords = [-10922, -1, 0, 1, 23, 10922]
      zs = [int(low(int16)), -1, 0, 7, int(high(int16))]
      spriteIds = [0, 830, 65535]
      layers = [MapLayerId, FogLayerId, HudTopRightLayerId]
    for scale in [1, 2, 3]:
      boardScale = scale
      for layerId in layers:
        let board = layerId == MapLayerId or layerId == FogLayerId
        for objectId in objectIds:
          for x in coords:
            for y in coords:
              for z in zs:
                for spriteId in spriteIds:
                  var inline, reference: seq[uint8]
                  inline.addBoardObject(objectId, x, y, z, layerId, spriteId)
                  reference.addObject(
                    objectId,
                    (if board: x * scale else: x),
                    (if board: y * scale else: y),
                    z, layerId, spriteId)
                  check inline == reference
    boardScale = 1
