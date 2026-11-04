# Paintbot wire protocol — Sprite v1 plus CTF extensions

> **Deprecated since 0.7.253.** This is the direct-input protocol for modes
> enabled with `allowDeprecatedModes: true`, not the Season 2 play-seat wire.
> New policy authors should start in [`policies/starters/`](../policies/starters/README.md).

## Season 2 quick reference (read this first)

*Era: GameVersion 61 / GLORYVERSION 16 / paintbot 0.7.367+ (main `9b6019aa`).*
This whole file is the **deprecated** direct-input protocol below. A Season 2
play seat does not send button masks — it uploads WASM plays and calls them
by name (normative spec:
[`docs/designs/strategy-play-calling-shell-2026-08-29.md`](designs/strategy-play-calling-shell-2026-08-29.md)
§4.3). What Season 2 *does* keep from Sprite v1: the play-seat connection, the
engine's fixed tick rate, and (for a container-based policy) the seat-identity
env vars. One screen, each line pointing at where it is proven:

- **Connect.** Every play seat — Season 2 included — is a websocket at
  `ws://host:port/player?slot=<N>&token=<T>`; the Season 2 wire is the same
  socket upgraded with 0xA0 ModuleUpload
  ([`policies/poc_llm_policy/README.md:26`](../policies/poc_llm_policy/README.md),
  "What it proves").
- **Seat-identity env vars** a container policy reads to build that URL —
  documented for the local PoC harness at
  [`policies/poc_llm_policy/README.md:283-284`](../policies/poc_llm_policy/README.md):
  `POC_HOST`/`POC_PORT` (the game server) and `POC_SLOT`/`POC_TOKEN` (the play
  seat and its token). **`coworld run-episode`/`coworld play` instead inject a
  single pre-built `COWORLD_PLAYER_WS_URL`** (verified against the installed
  `coworld==0.1.46` CLI, `coworld/runner/runner.py:476`) — the two conventions
  are not interchangeable; see the "Run it" section of the poc README.
- **Observe.** The player stream is Sprite v1 frames: 1x map-pixel coordinates
  (see "Observation render scale" below, this file), and the map camera
  object's presence marks in-game vs. lobby/interstitial (see "Lobby and
  interstitial detection" below, this file).
- **Act — the direct-input 8-bit mask** (deprecated modes only; a Season 2
  seat calls plays by name instead, never this mask): bit0 Up=1, bit1
  Down=2, bit2 Left=4, bit3 Right=8, bit4 Select=16, bit5 A=32, bit6 B=64 —
  inherited wholesale from the
  [Sprite v1 base spec](https://github.com/softmax-universe/bitworld/blob/master/docs/sprite_v1.md),
  not redefined in this repo — and bit7 C=128, this repo's own extension (see
  "Player input: bit 7 is the C button" below, this file, and
  `players/baseline/baseline.nim:150`).
- **Tick rate.** 24 ticks/sec, engine-wide, deprecated and Season 2 alike
  (`docs/RULES.md:1237`; also `src/ctf/sim_types.nim:895`, a 5-minute game =
  7,200 ticks at 24/s).
- **Run a policy against a real local episode end to end:** see the root
  [`README.md`](../README.md#run-season-2-locally) or
  [`policies/poc_llm_policy/README.md`](../policies/poc_llm_policy/README.md)'s
  "Run it" section for the verified `coworld run-episode` invocation.

Both the player endpoints (`/player`, POV observation streams) and the
global/spectator endpoint speak
[Sprite v1](https://github.com/softmax-universe/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything CTF adds or changes relative to that base
document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — mechanics, sprite labels, tuning defaults — live in
[`RULES.md`](RULES.md).

## Player input: bit 7 is the C button

Sprite v1 reserves player-input bit `7` ("must be sent as 0"). CTF assigns it:

| Bit | Value | Meaning |
| ---: | ---: | --- |
| `7` | `0x80` (128) | C button — hold to charge a grenade throw, release to throw |

Send it in the standard `0x84` Player Input bitmask alongside the Sprite v1
bits (d-pad, Select, A, B). A player that never sets bit 7 can still move,
tag, and win — but cannot throw a carried grenade. See `RULES.md`, section
*Grenades*, for the charge/release mechanics. (The spray can is not thrown:
carrying one turns the normal trigger into the paint cone; C keeps throwing a
carried grenade.)

## Player Ready (`0x85`) is supported — but do NOT send it in league play

The server understands the Sprite v1 Player Ready packet (`0x85`): after each
rendered frame a player client may send it to signal "done thinking", which
lets the server pace fast-mode games by readiness instead of the wall clock.
Sending it is optional; clients that never send it are paced by timeouts.

**Warning (measured, not theoretical):** on a wall-clock-paced server (league
play runs with `fastMode` off), sending ready every frame corrupts
input-application timing. The reference bot's dead-reckoned aim random-walked
to a median ~15-brad error at the trigger and its gun accuracy collapsed from
44–54% to 13–23%; removing the send flipped an 0W–23L record to 8W–10L vs the
champion (p=0.0039). Send `0x85` only when you know the server is in fast
mode (fixture recording); competitive clients should not send it at all. The
deprecated reference implementation gates it behind `CTF_BOT_FAST_READY=1`
(`players/baseline/baseline.nim`, `fastReadyEnabled`).

## Your own aim: read the `own aim` marker; dead-reckon between frames

The player stream carries an absolute readback of your own aim angle: an
invisible 1×1 HUD marker labeled `own aim <brads>` (256 brads per turn,
0 = east, counter-clockwise), stating your turret angle as of the rendered
tick. Match the label by the `own aim ` prefix and parse the tail. (An
earlier build's "aim dot" label was a previous form of this readback; the
engine retired it, and between the two the observation carried none — bots
from that era dead-reckon open-loop.)

The marker is exact only for the rendered tick, so a client still integrates
between frames:

- Spawn (and respawn) aim points toward the enemy side.
- Each held rotate button turns the continuous aim by the server's
  `aimTurnRate` (default 5 brads per tick, about 7 degrees) for **every elapsed
  sim tick** — including ticks you
  never saw a frame for. If you process frames with `frameAdvance > 1`
  (see below), integrate the rotation across all advanced ticks, then let the
  next frame's marker correct the estimate.
- The aim angle **locks at the trigger pull**: the shot releases after
  `fireWindupTicks` with the aim as of the pull, so stop rotating on the tick
  you fire if you want the shot to go where you aimed.

## Frame pacing: drain the backlog, act on the latest frame

The server keeps applying your **last sent input mask** on every sim tick,
whether or not you sent anything — inputs are level-based state, not events.
If your client falls behind the frame stream, acting on a stale frame means
reacting to a world that has already moved on while your held buttons kept
applying. The reference client drains the socket backlog each loop iteration
(up to 128 buffered frames), decides on the **latest** frame only, and tracks
how many sim ticks elapsed since the previous decision (`frameAdvance`) so
dead-reckoned state (like the aim, above) stays consistent. Only *changes* to
the input mask need to be sent.

## Lobby and interstitial detection

There is no explicit "game phase" message on the player stream. The in-game
signal is the **map camera object** (object id `1`, sprite id `1`): while it
is present, a match is running and its `(x, y)` is the camera anchor; the
server deletes it during the lobby and the game-over interstitial. The
reference client treats "map object deleted" as leave-game (reset transient
state) and "map object defined" as enter-game. The walkability mask arrives
as its own labeled sprite (see `RULES.md`) and is only valid in-game.

## Observation render scale

- **Player/POV streams are 1× map resolution.** Object coordinates and sprite
  pixel sizes are map pixels directly: an object's center
  (`object.x + sprite.width / 2`, same for y) IS its map point on the
  1235×659 map. No divisor is needed.
- **Only the global/spectator/replay stream supersamples**, shipping its
  zoomable board layers at 2× (`RenderScale`); its viewport announces the
  scaled size. The sim, the gameHash, and every value quoted in `RULES.md`
  stay in 1× map pixels.
- A 0.6.0-era build shipped observation coordinates at 3×; that is long gone.
  Any advice about dividing player-stream coordinates by 3 is stale.
