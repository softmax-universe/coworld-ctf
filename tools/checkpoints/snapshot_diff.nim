## Diagnostic for Coworld Checkpoints (spec 0157): does a live server's
## game.snapshot at tick T equal the sim a replay walk reaches at T?
##
##   snapshot_diff <replay.bitreplay> <game.snapshot>
##
## Walks the replay to the snapshot's tick, compares the two sims field by
## field (portable_flatty bytes per top-level SimServer field), then steps
## both one tick under the SAME replay cursor and compares gameHash. Exit 0
## when the sims agree and the step matches.

import
  std/[os, strutils],
  ../../src/ctf/[checkpoint, portable_flatty, replays, sim]

proc freshSim(configJson: string): SimServer =
  var config = defaultGameConfig()
  config.update(configJson)
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false

when isMainModule:
  if paramCount() != 2:
    quit("usage: snapshot_diff <replay.bitreplay> <game.snapshot>", 2)
  let
    data = parseCtfReplayBytesFull(readFile(paramStr(1)))
    snapshot = loadGameSnapshotUri(paramStr(2))
  var walker = initReplayPlayer(data)
  var walked = freshSim(data.replay.configJson)
  while walked.tickCount < snapshot.tick:
    walker.stepReplay(walked)
  echo "walked to tick ", walked.tickCount, " hashFailed=",
    walker.hashValidationFailed
  var restored = freshSim(data.replay.configJson)
  var scratch = ReplayPlayer()
  scratch.restoreGameSnapshot(restored, snapshot)
  echo "hash walked=", walked.gameHash(), " restored=", restored.gameHash()
  var differing = 0
  for name, a, b in fieldPairs(walked, restored):
    when compiles(toPortableFlatty(a)):
      if toPortableFlatty(a) != toPortableFlatty(b):
        inc differing
        echo "  field differs: ", name
  echo differing, " differing top-level fields"
  var second = walker
  second.mismatchQuit = false
  walker.mismatchQuit = false
  walker.stepReplay(walked)
  second.stepReplay(restored)
  echo "tick ", walked.tickCount, " walked=", walked.gameHash(),
    " restored=", restored.gameHash(),
    " recorded=", (if walker.hashIndex > 0 and walker.hashIndex <= data.replay.hashes.len:
      $data.replay.hashes[walker.hashIndex - 1].hash else: "?")
  quit(if differing == 0 and walked.gameHash() == restored.gameHash(): 0 else: 1)
