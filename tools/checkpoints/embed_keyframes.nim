## Embeds seek keyframes into an existing `.bitreplay` (spec 0157), the same
## pass the live server runs on close when CTF_REPLAY_KEYFRAME_TICKS is set.
##
##   embed_keyframes <in.bitreplay> <out.bitreplay> [interval]
##
## Run from the repo root (the re-walk needs data/).

import
  std/[os, strutils],
  ../../src/ctf/replays

when isMainModule:
  if paramCount() < 2:
    quit("usage: embed_keyframes <in> <out> [interval]", 2)
  let interval =
    if paramCount() >= 3: parseInt(paramStr(3)) else: DefaultEmbeddedKeyframeTicks
  let source = readFile(paramStr(1))
  let embedded = embedReplayKeyframes(source, interval)
  writeFile(paramStr(2), embedded)
  echo "embedded keyframes every ", interval, " ticks: ", source.len, " B -> ",
    embedded.len, " B"
