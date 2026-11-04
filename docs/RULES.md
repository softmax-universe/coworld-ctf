# Paintbot Classic (Coworld CTF) — Game Rules

> **Deprecated since 0.7.253.** This remains the accurate rules reference for
> classic modes, which boot only with `allowDeprecatedModes: true`; it is not
> the active Season 2 ruleset. See [`designs/BR_PLAYS.md`](designs/BR_PLAYS.md)
> and the normative sections of the
> [`Season 2 play-calling design`](designs/strategy-play-calling-shell-2026-08-29.md).

Paintbot's classic mode ("Coworld CTF") is a two-team capture-the-heart tag game
for the Coworld platform. Two
teams start on opposite edges of a symmetric arena, each with its own heart on a
home pedestal. Players move, take cover behind obstacles, and tag each other out. Steal the
enemy heart and carry it home — or eliminate the enemy team — to win. Vision is
fog-of-war: the map is always visible, but enemies only appear inside your
forward vision cone or your small omnidirectional bubble.

It is a fork of [Crewrift](https://github.com/softmax-universe/coworld-crewrift): it keeps
Crewrift's continuous 2D movement, line-of-sight, sprite protocol, server, and
replay infrastructure, and replaces the social-deduction game layer (roles,
tasks, voting) with teams, guns, hearts, and fog-of-war vision.

---

## Overview

- **16 players, 8 vs 8.** Red team spawns along the **left edge**, Blue along the
  **right edge**.
- **Two team hearts**, one on each team's **home pedestal** inside its spawn
  pocket (classic two-object CTF, with hearts for flags).
- **GameVersion 42 makes standing on the pedestal enough to take the heart.**
  The steal radius was 12px around the heart's exact center — a fifth of the
  60px sprite drawn on a 96px pedestal — so the visible target overstated the
  real one fivefold, and players and policies alike stood plainly on the heart
  without picking it up. The radius is now **34px**, derived from the drawn
  heart's own half-extent, so anywhere the art is under your feet is a grab.
  It still stops well inside the pedestal's spawn pocket, so no steal reaches
  through a wall.
- The arena is filled with **staggered cover** (a slalom of offset wall
  stubs, diamonds, discs, and diagonal chevron walls, mirrored symmetrically so
  neither team has a positional advantage): **no straight shot crosses the
  field**, so every approach is a series of corners. GameVersion 16 thinned
  the disc column to every other disc, opening real gaps in the mid-field
  slalom.
- The **eight diamonds flanking the center spin**, and since **GameVersion 28
  the spin is real geometry**: the rotating silhouette you see is the exact
  footprint that stops your feet, your bullets, and your line of sight. A
  quarter turn takes ~2.7s (16 frames, one every 4 ticks), the two halves turn
  in mirrored directions, and the angle derives only from the tick — so every
  viewer and every replay sees the same stone. The blocked lane through the
  center therefore **opens and closes on a clock**: a vertex that covered you a
  second ago may have swung away. A player the sweep engulfs is pushed to the
  nearest free floor rather than trapped inside stone, and never onto another
  body.
- **GameVersion 31 makes sprayed paint hurt.** Two changes close the same
  gap — paint visibly covering a cog that walked away clean. First, the cone
  hits **bodies, not center points**: a sprayed cog is tested as a **17 px
  disc** (half its 34 px body), where it used to be the bare point its 1 px
  collision box describes — largest effect **point-blank**, where the cone
  was narrower than the cog it covered. Second, the **reach grew 4 → 5
  squares**, with the width grown to match so the **14° half-angle did not
  change**; the 5th square is exactly what it takes to cover the tip of the
  plume the game draws. See the Spray can section for the shape.
- **GameVersion 38 makes the spray one directional shot, not a sweep.** A
  fired cone now locks its aim at the moment of firing and keeps it for the
  whole 5-tick window: spinning the cog after you press no longer rakes the
  cone around you. The cone's origin still rides its owner, so a moving
  sprayer drags the stream forward — only the rotation is pinned. See the
  Spray can section.
- **GameVersion 30 puts every team's pickups on the map's own symmetry.** A
  team's shield and spray can are Red's spots carried over by whichever
  symmetry the terrain was built with — mirrored, rotated 180°, or turned a
  quarter at a time on the 4-team boards. Only that image lands in equivalent
  terrain: a mirrored copy on a rotational map sits in the rotation of Red's
  *other* pickup, so one team's shield had cover and sightlines the other's
  did not. See "Shields" and "Spray can".
- **GameVersion 29 extends the live spin to generated terrain**, fairly. Which
  diamonds spin is decided by a band down the center column, and that choice
  is **closed under each map's own symmetry** — on the 90°-rotational 4-team
  boards the band's closure is a cross, so a diamond never turns while its
  quarter-turn twin sits as solid stone. Spin **direction** follows the same
  logic: a mirror map turns its two halves opposite ways (a reflection
  reverses a rotation), while a 180°- or 90°-rotational map turns **every**
  diamond the same way, because a rotation does not. The terrain generator
  also judges a spinning diamond from both ends of its turn — sightlines and
  the cover floor against its **narrowest** footprint, corridors and the
  cover ceiling against its **widest** — so a map cannot pass validation on
  a firing lane that is only blocked at rest. Two seeds in the previous
  curated pool did exactly that, and the pool was re-drawn without them.
- In the outermost stub column of each half, the glass alternates in from
  both ends: the **second stub from the top, the middle stub, and the second
  from the bottom (GameVersion 27) are glass windows**: they block movement,
  bullets, and
  spray cones exactly like stone, but **vision passes straight through them**.
  Glass draws as a pale pane with diagonal sheen — cover you can be seen
  behind is not cover.
- The old midline chevron zigzag is now a **square-bracket wall pair framing
  the flag ring** (`[ … ]`, GameVersion 16), and the middle of each bracket's
  bar — dead on the center row — is a **glass window**: the mid lane stays
  closed to movement and fire, but both teams can watch the center corridor
  through the glass.
- **Trenches** — walkable dug-pit squares — are a **config-gated terrain
  feature**: the classic arena has none; classic generated maps (below) place them
  procedurally, steered by `mapPits` / `mapPitDensity`. See the Trenches
  section for their rules.
- **Paint puddles** — damage-over-time floor hazards — are a **config-gated
  terrain feature**: no map has any unless `mapPuddles` requests them. See
  the Paint puddles section for their rules.
- **Cardboard barriers** — placeable paint-blocking cover — are a
  **config-gated pickup**: no map has any unless `barrierPickups` requests
  them. See the Cardboard barriers section for their rules.
- **Procedurally generated terrain is available as a config option**
  (`mapPath: "pool"` draws from a curated 20-map pool, `"gen"` + `mapSeed`
  generates directly; `mapSize` / `mapSymmetry` / `mapColumns` /
  `mapWindows` / `mapCenterFeature` / `mapEndzone` lock individual draws).
  Generated layouts keep every arena invariant — exact team symmetry
  (vertical mirror or 180° rotation), no straight cross-field shot,
  corridors at least twice the player footprint, a bounded cover budget —
  and draw their size class (`small` / `standard` / `large` / `huge` /
  `giant` — `giant` is the old `large` ceiling doubled, up to 3211x1713 on
  a 2-team board; obstacle sizes never scale, bigger fields draw more
  cover columns instead), obstacle columns, glass placements, center
  feature, endzone archetype, and med-kit pair per map. The exact geometry
  is pinned into the match config/replay as `mapSpec`. These generators and
  the hand-tuned arena are retained for explicitly enabled deprecated modes;
  Season 2 uses the authored 16-team BR `mapSpec` described in
  [`MAPKIT.md`](MAPKIT.md).
- **Compact endzones** are one of those draws. Half of generated 2-team maps
  keep the classic home column; the rest pull the base **well off its home
  edge** and wrap it in a **disc or square endzone** (`mapEndzone`:
  `"column"` / `"disc"` / `"square"`), which turns the whole home border
  strip into ordinary **wilderness** — cover, glass and pits wrap all the
  way around and behind the base. Scoring follows the shape: a carrier
  scores by crossing the painted ring from ANY side, including from behind.
  Such maps are validated for an OPEN FLANK — four clear cardinal approaches
  into the ring, and a route from behind the base to midfield that never
  enters the endzone — so a deep base cannot be defended as one front line.
- A round ends when at most one team still stands: **capturing a heart
  eliminates its team** (GV32 — every player on the captured team dies with
  no respawn, and the heart leaves play where it was captured), and a team
  with no live players is **wiped out**. In classic 2-team play a capture
  therefore still ends the round on the spot.
- **A dead team's heart leaves play with it** (GV33): the moment a team is
  completely killed — captured or wiped — its heart is retired and no
  longer drawn. If an enemy was carrying that heart when the team fell,
  it drops straight off their back (restoring full speed and fire rate);
  a retired heart cannot be stolen or captured.

## Teams & spawns

- Players are assigned to **Red** or **Blue** by slot (8 each).
- A slot may configure a cosmetic **skin** (`slots[i].skin` in the game
  config; currently `default` or `crown`) that restyles that player's body
  art. Skins are cosmetic only: no gameplay effect, and the player, corpse,
  and selected-player observation labels are unchanged, so policies cannot
  (and need not) distinguish them.
- Each team's players get a fixed **identity**, `alpha` through `theta`, by
  slot order within the team — deterministic across matches and replays. A
  small Greek-letter badge (Α Β Γ Δ Ε Ζ Η Θ) rides each living player's
  sprite, and the badge object is labeled `identity <color> <name>` (e.g.
  `identity red alpha`). Badges are fog-gated with their player: seeing a
  player means seeing who it is. Existing `player <color> <side>` labels are
  unchanged.
- Each team has a **home edge**: Red = left, Blue = right.
- Players start just inside their home edge. When killed they respawn at a
  **random spot inside their own endzone** (GameVersion 25) — the respawn
  point cannot be camped.

## Deprecated four-team mode

This is a deprecated classic variant, not the published game. With
`allowDeprecatedModes: true`, `"teams": 4`, and `"mapPath": "gen"`, it seats
FOUR teams — **Red, Blue, Green, Yellow** — in a free-for-all on a generated
square map:

- **Layouts** (`"mapLayout"`, or drawn from the map seed): `"corners"` puts a
  team in each corner (Red top-left, Blue top-right, Green bottom-left,
  Yellow bottom-right) with a DIAGONAL endzone — a 45-degree threshold line
  cut across the corner; `"plus"` puts a team at each edge midpoint (Red
  west, Blue east, Green north, Yellow south) with an arm-mouth endzone —
  the corners are open battlefield. Both are fully open square boards whose
  terrain replicates a generated quadrant by 90-degree rotation, so all
  four quarters are exactly fair: the WALL MASK a team plays against is
  pixel-for-pixel the quarter turn of every other team's, homes included.
  Each team's spawn pocket rotates with its home, so the north and south
  pockets of a plus board lie on their sides relative to the east and west
  ones — a pocket that stayed upright everywhere would be a different
  shape than its own rotational twin.
- **Every team has its own heart** on its own pedestal, and its own capture
  zone behind it. Steal ANY other team's heart and carry it into your own
  zone to **eliminate that team** (GV32): its players all die for good and
  the captured heart is out of play for the rest of the round. A team
  wiped out by kills loses its heart the same way (GV33): it retires on
  the spot — even straight off an enemy carrier's back — and is no longer
  drawn. Allies do not exist: 4-team play is pure
  free-for-all, and a "2v2" is simply two policies splitting one classic
  team's seats.
- **Seats deal round the teams** by slot order (slot mod 4): 4 players per
  team on a 16-seat roster, 8 per team on a 32-seat roster (the Paintbot
  `4ffa8` variant, always on a giant generated map). Identities stay
  per-team (`alpha`..`delta` at 4 per team, `alpha`..`theta` at 8).
- **The last team standing wins**: the round ends when at most one team
  still has live players — so a 4-team winner either captures all three
  rival hearts or outlives the field (captures and wipes mix freely); an
  eliminated or wiped team just sits out until then.
- **Scoring is zero-sum by construction**: the winning team scores **+1 per
  losing team**, each losing team scores **-1**. Classic 2-team play stays
  +1/-1; a 4-team win pays **+3** to the winner and **-1** to each loser.
  Time-limit draws still pay -1 to everyone. (Under `scoring: "pot"` the
  4-team win pays **+4** instead — see "Scoring".)
- **Labels are unchanged in shape**: the same `player <color> <side>`,
  `<color> flag [planted]`, shout, and identity vocabulary — `green` and
  `yellow` simply appear as team color tokens alongside `red` and `blue`.
- Med kits become a rot90-fair diamond of four; each team gets one shield
  and one spray-can pickup near its endzone; the four grenade pickups move
  to the edge midpoints (corners layout) or a rot90 orbit around the
  center (plus layout).

## Movement

- Movement is **continuous** (acceleration, friction, max speed, wall-sliding) —
  the d-pad drives it.
- Movement is **pure locomotion**: it never changes where you aim or look.
- Player bodies are **solid**: you cannot drive over or through another live
  player (friend or foe). Contact is a **slightly elastic collision** — equal
  masses, `playerBouncePct` restitution (default 40%): ramming a standing
  player shoves them forward and keeps a little of your speed; a head-on
  meeting bounces both back at 40% of the closing speed. Glancing contact
  slides around the body the same way wall-sliding works. Corpses never block.

## Aim

- Every player has a **continuous aim angle** reported in **brads** (256 units
  per full turn, integer — deterministic): **0 = east (+x)**, increasing
  **counter-clockwise on screen** in map coordinates (64 = north, 128 = west,
  192 = south).
- The aim is **decoupled from movement**. Hold **B** to rotate the aim
  **counter-clockwise**, hold **Select** to rotate **clockwise**, at
  `aimTurnRate` brads per tick (default 5 ≈ 7°/tick; a full turn takes ~2.1s).
  Holding both rotate buttons cancels out **for the aim** — but see the
  warning below: on a `dropItem` game that combination is the **drop chord**.
  The d-pad **never** touches the aim.

> **Holding B+Select is no longer inert.** It cancels the aim traverse on
> every game, as it always has, but where `dropItem` is armed (the
> `battle-royale-s2` variant) holding both for `DropChordTicks` (10 ≈ 0.4 s)
> **drops one carried item to the ground**. Authors who used the both-bits
> combination as a "hold my aim still" idiom must stop: on an armed variant it
> sheds the spray can (and then nothing more — the drop latches until the
> chord is released). To hold an aim, emit **neither** rotate bit.
- The aim drives everything directional: the **gun** fires along it, the
  **vision cone** centers on it, and the sprite flip follows it (you face left
  while aiming left-ish).
- On spawn and respawn your aim points **toward the enemy side** (Red → east,
  Blue → west).
- A player's **facing** is shown by the soldier sprite itself: the held gun
  sweeps to the aim angle (the sprite reports a coarse `right`/`left` side in
  its label), and — for anyone you can see — the direction they can tag is
  exactly the lane their body faces. There is no longer a separate floating
  aim-dot indicator; the vision cone and the swept gun convey aim.

## Vision (fog of war)

Every player observes the **full map** — the terrain is static knowledge and is
always drawn — but moving entities are fogged:

- Your **vision** is a **forward cone** of half-angle `visionConeDeg` (default
  ±60°) around your **aim angle**, reaching **1.5× the gun range** (1575px
  stock, since GameVersion 34 — sight outranges paint by half again), plus a
  small **omnidirectional bubble** of `visionBubble` (default ~90px) around
  you that the range cap never shrinks.
- **Stone walls block vision** — the same walls that block bullets — with one
  exception: **glass windows** (the second-from-top, middle, and
  second-from-bottom stubs of each half's outer stub column) block bullets
  but NOT vision. A long open
  lane is visible (and lethal) end to end; anything behind stone is not;
  anything behind glass is **seen but safe from direct fire**.
- **Your aim carries your vision.** You look where you aim, not where you walk,
  so watching a lane, sweeping an arc, and turning your back are deliberate
  rotation choices - and moving somewhere no longer reveals it.
- Everything outside your vision is **masked**: enemies, an enemy carrying a
  heart, and death splatters from unseen events are simply not in your
  observation. The unseen area is dimmed by a fog overlay.
- **Bullets are invisible to players.** Shot tracers and muzzle flashes are
  spectator/replay rendering only — no player observation ever contains
  them, whether the shot crossed your vision or not. Players learn of
  gunfire only by sound (below).
- **Always visible regardless of fog:** the static map, **both heart pedestals**,
  your **own heart's state** (its pedestal heart is never hidden — an empty own
  pedestal means your heart is stolen), and **yourself** via a distinct self
  marker. **Teammates are fogged like everyone else** — there is no team
  radio; keeping track of your own side takes eyes too.
- **Only a shot's landing is audible — and sound is all a player gets.**
  Every shot leaves every living player one brief hollow **impact ring**
  (label `shot impact`) near where it landed, for ~0.5s, regardless of line
  of sight. **Firing itself is silent**: the muzzle emits no signal, so
  pulling the trigger never reveals the tagger's neighborhood — only where
  the paint lands. The ring is randomly (but deterministically, per shot)
  offset by up to ~20px, so it tells you something was hit *roughly there*
  — never the exact spot, the shot's line, or which team.
- **Another soldier's drawn gun angle is approximate (since GameVersion 24;
  self exempted since 26).** Every OTHER soldier sprite in a player's view —
  enemies, teammates, and corpses — renders its gun rotated by the true aim
  plus a deterministic pseudo-random offset of up to **±20°**, re-rolled about
  twice a second: watching another bot never reveals its exact aim. Your OWN
  self marker shows your TRUE aim — your gun is your own state, not a leak.
  Every soldier sprite (self included) draws its gun at the nearest of 16
  pre-rendered steps, 22.5° apart — so the self marker is true aim rounded
  to within ±11.25° (±8 brads), with no fuzz on top, while other soldiers
  carry the ±20° fuzz before the same rounding.
  (The spectator broadcast board also shows true aim.)
- There is **no global heart tracking**: once a thief carries your heart into the
  fog, finding it again takes eyes on it.
- Death does not lift the fog: a dead player sees the whole map fogged —
  only the terrain, the pedestal hearts, and their own corpse — until they
  respawn (their inputs are ignored).

## Combat

- **Every player has `hitPoints` (default 3) per life.** Each bullet that hits
  removes one hit point; at zero you die. Hit points reset to full on every
  respawn. Your own remaining HP shows on your HUD next to your lives.
- Press **A** to fire. Firing has a short **cooldown** between shots (it is not a
  continuous beam).
- Pressing fire starts a short **windup** (~0.2s): your aim locks the moment
  you pull the trigger, and the bullet leaves at the end of the windup. A
  target that peeks out and ducks back behind cover before the release
  survives the shot.
- The bullet is **hitscan along your aim ray**: it travels down the locked
  aim direction and hits the **first player whose footprint crosses its
  narrow corridor** — it never passes through a body to hit someone behind,
  and **walls stop it**.
- **Range is a fixed 1050 px on every map** (since GameVersion 34) — the
  small generated map's field width. Only on the smallest board is the gun
  map-wide; on larger fields paint simply falls short, so closing distance
  matters. Paint that runs out of range hits nothing and marks nothing.
- **Aim is fuzzed** (since GameVersion 34): every released shot's direction
  gets a small random angular error (~0.6° sigma), calibrated so a **fully
  visible** body at **max range** is hit **80%** of the time. Accuracy
  sharpens fast as you close: ~99% at half range, effectively perfect
  inside a third. The noise also rides shots at partial cover — a sliver
  target at long range is doubly hard.
- **Cover is partial, not binary.** A target's body is sampled across its
  silhouette: only the part of the body that is both inside the bullet
  corridor AND visible from the tagger can be hit. A corner-hugger showing
  a sliver is exactly as hittable as that sliver — no more (fully hidden
  body parts cannot be tagged through the wall), and no less (the poking
  shoulder is fair game even when the body's center is safely covered).
  More exposure means more aim angles connect.
- **Friendly fire is ON.** A shot hits the first valid target regardless of team,
  so firing into a cluster of teammates can kill your own escort. A teammate
  kill is counted as a **team kill** (GV45) — its own stat in the metrics,
  results, and endscreen — and never inflates the killer's kill count,
  multi-kill honors, or kill sprees. The hit points a shot removes are split
  the same way (GV47): hp taken off an enemy accumulates as **hit damage**,
  hp taken off a teammate as **team hit damage**, and hurting yourself
  counts as neither.
- **Same-tick shots resolve simultaneously.** Every trigger pulled on the same
  tick picks its target against the same snapshot before any kill applies: a
  mutual face-off duel kills both taggers, and neither team gains an
  input-processing-order advantage.

### Shot micro (frame data)

The full life of one shot, at 24 ticks/second:

1. **Trigger pull (tick 0).** Fire is edge-triggered: a shot arms on the
   tick the button goes down — holding it does nothing, and a second pull
   during a pending windup is ignored. The pull is refused entirely while
   the cooldown is still running.
2. **Windup (5 ticks, ~0.2s).** Your **aim angle locks at the pull**;
   turning during the windup does not bend the pending shot (it only
   re-aims the next one). Your **position stays live**: movement is
   full-speed and unrestricted during the windup.
3. **Release (tick 5).** The bullet resolves instantly (hitscan) **from
   your position at release, along the angle locked at the pull**. All
   movement for the tick happens first; every shot releasing that tick then
   resolves at once against the post-movement snapshot.
4. **Cooldown (12 ticks, ~0.5s; 3x that for a shield carrier — and, since GameVersion 26, 3x for a HEART carrier too: carrying the heart no longer means free full-rate fire; shield+heart take the max multiplier, not the product).** The
   cooldown starts at release, so the sustained rate is one shot per
   cooldown — the windup does not slow your cadence.

What that means in practice:

- **Strafe-firing works.** The shot line translates with your movement
  (new position, old angle), so lead your own strafe when you pull.
- **Fire-and-duck can waste your own shot.** Line of sight is checked from
  your release position: step behind a wall during your windup and the
  wall eats your bullet.
- **Targets can dodge the windup.** Anyone who breaks line of sight during
  your ~0.2s windup survives; the aim lock is the price of the shot.
- **The corridor is forgiving.** The bullet is a ray with an 8px half-width
  corridor sampled against the target's ~12px-wide silhouette — near-misses
  connect; precision beyond the corridor width buys nothing.
- **Respawners are live immediately.** There is no spawn protection: a
  freshly respawned player can tag and be tagged (and blocks bullets) from
  their first tick.

## Grenades

- **Four grenade pickups spawn in the arena corners** — two on each team's
  side — a fixed inset inside the border walls. Anyone may take either
  side's pickups by **touch**; a taken corner **refills 5 seconds later**.
- **Each player carries at most one grenade.** Dying loses the carried
  grenade (nothing drops).
- **Throwing:** hold the **C button** (input mask bit 128) to charge, release
  to throw along your **current aim**. The charge picks the distance, from a
  short tap (~30 px — inside the blast radius, so a panicked drop can hurt
  you) up to a full-charge **maximum of one fifth of the field width**
  (~247 px) after ~1s of holding. While you charge, a **throw target ring**
  marks the landing spot on your own view (and is readable intel for anyone
  who can see you, like your aim line).
- **Grenades fly over every obstacle** in a straight lob from thrower to
  target and **explode on landing**. The burst comes a **fixed two shot
  windups (~0.4s) after release, near or far** — long throws just travel
  faster. A grenade is a snap weapon: the reaction window is the same as
  eating two aimed shots, not a mortar shell you can stroll away from.
- **The blast hurts everyone whose body touches its radius (~52 px): enemies,
  teammates, and the thrower alike**, removing 2 hit points each — **unless a
  trench is involved, which changes the amount**; see the Trenches section. It
  is your BODY that must reach the circle, not the point you stand on — the
  same rule the gun's bullet corridor uses — so a cog centred up to ~58 px away
  is still caught. The landing splat and the charge-time throw-target ring are
  drawn at the blast diameter, so anything painted was hit, but a cog clipping
  the rim from just outside it is hit too. Kills credit the thrower (except
  suicides).
- **Throwing is silent; landing is loud.** A landing you could not see
  leaves a large jittered sound ring (label `grenade sound`) — landing-only
  audio, exactly like gunshot impact rings. The throw itself leaves nothing.
- Observation labels: pickups `grenade`, airborne `grenade air`, the marker
  above a carrier `grenade carried`, the charge marker `throw target`, the
  landing flash `blast stage N`.

## Spray can

- **Two spray can pickups spawn high in the side back columns** — Red's in
  the TOP half (a quarter of the map height down, between the top corner
  grenade and the side midpoint), nudged to the nearest walkable floor. The
  shields hold the matching bottom-half spots. Both spray cans are present
  when the game starts, and a taken one respawns after **30 seconds**.
- **The other team's can is Red's spot carried over by the map's own
  symmetry** (GameVersion 30), not simply mirrored across the midline. On a
  180°-rotational map that puts Blue's can in the BOTTOM half, because that
  is where the rotation sends Red's — mirror it instead and it lands in the
  rotation of Red's *shield*, so the two teams fight for the same item in
  differently-shaped terrain.
- **Each player carries at most one spray can**, independently of their
  grenade. Dying loses the carried can; nothing drops.
- While carrying a spray can, **A sprays a forward paint cone instead of
  firing the gun**. The cone reaches **5 squares** in front of the player
  (170 px — one square is one 34 px cog body) and widens linearly to
  **2.5 squares (85 px) at max reach**, a constant half-angle of
  atan(1/4) ≈ 14°. The gun is disabled while the can is held; C still
  throws a carried grenade normally.
- **The cone hits bodies, not center points** (GameVersion 31). Those reach
  and width figures describe the cone's **centerline**; a cog is tested as a
  **17 px disc** (half a 34 px body) against it, so paint that visibly
  engulfs a cog takes its hit points. In effect the cone covers **187 px**
  forward and **17 px extra to each side at every distance** — which matters
  most **point-blank**, where the centerline cone is narrower than the cog it
  covers (±10 px at 40 px out, against a ±17 px body). Spraying **backwards**
  still hits nobody: the can points forward, so a cog behind the sprayer is
  out regardless of its body.
- **What the mist draws is not exactly what the cone covers.** The plume is a
  chain of round puffs drawn oversize so they merge into one jet, so it spills
  past the shape that sizes it. The reach is set to swallow that spill
  lengthwise — nothing the paint **engulfs** survives — but the mist still
  runs about **15 px wider** than the cone, so a cog can catch paint on its
  **edge** without taking damage. Closing that too would need a 31° cone.
- **The cone stays on for 5 ticks**, riding the attacker's position but
  **holding the aim it was fired at** (GameVersion 38): one press is one
  directional shot, so turning the cog mid-spray no longer sweeps the cone
  across a fan of targets — only the origin moves with you, not the direction.
  Then the can takes **20 ticks to repressurize** (one burst every 25 ticks).
  The cone shuts off if its owner dies.
- **A touch removes 3 hit points, once per victim per burst** — instantly
  lethal to a bare 3 hp cog, while a 6 hp shield carrier survives the first
  touch with 3 hp left. The cone affects teammates too and requires line
  of sight. Kills credit the attacker.
- A spray touch **paints its victim** (it stamps the same paint-hit tick the
  paintball gun and grenade do), so a sprayed seat's first-person view takes a
  paint splat across the visor.
- Observation labels: pickup `spray can`, carrier marker
  `spray can carried`, and the fading cone `spray paint puff` (a run of
  team-colored paint-mist puffs along the attacker's aim each active tick).
- **A carrier visibly holds the can**: the cog's held paintball marker is
  replaced by the spray can while one is carried (sprite label `cog spray can
  <color>` in place of `cog gun <color>`), so the silhouette shows which weapon
  is live.
- The cone's puffs **jet outward** from the nozzle to full reach as each burst
  ages, then thin out; overlapping per-tick snapshots make a held trigger read
  as one continuous plume. Purely cosmetic: the damage cone is the full
  4-square shape from the first active tick, regardless of how far the
  animation has travelled.

## Shouts

- **Any living player can shout: a short text message, at most 10
  characters** (longer messages are truncated; non-printable characters are
  dropped). Send it as a chat packet (`0x81`, the standard sprite-protocol
  chat message); in the browser client press **Enter**, type, and press
  Enter again.
- **Anyone within one fifth of the field width (~247 px) hears it** —
  through walls and fog, like gunfire. Outside that radius the shout does
  not appear in your frame at all.
- A heard shout appears as a speech bubble labeled
  `<team> shout <name>: <text>` pinned at **deterministically jittered
  coordinates** (~±20 px, like gunshot impact rings): you learn roughly where
  the shouter is, never exactly.
- `<name>` is the shouter's **anonymous slot letter** (`alpha`..`theta`, ranked
  within its own team — the same identity the `identity` badges use), never the
  connecting player's name. Listeners on both teams read these labels, so the
  label deliberately carries no clue about **whose policy** is talking. Split
  the label on the first `": "` and treat the rest as payload; `?` in the name
  position means the shouter left while the bubble was still up.
- **Rate limit: one shout per second per player**, and each player has at
  most one live bubble (a new shout replaces the old). Bubbles fade after
  **3 seconds**. Dead players cannot shout and hear nothing.
- The global/replay view draws every bubble at the shouter's actual
  position, following them while they live.
- **Shouting is free**: it never consumes, delays, or modifies any other
  same-tick action — you move, aim, and fire exactly as if you had said
  nothing; its only limit is its own one-per-second cooldown.

## Trenches

- A **trench is a 56×56 px walkable dug-pit square** that draws as a
  recessed dark pit in the floor. It is **not a wall**: it never blocks
  movement, bullets, or vision. Trenches are **config-gated** and ship
  without a game-version bump, exactly like procedural terrain: **the
  default arena has none**, and a league opts in through its own config
  (generated maps dig them per seed; a `mapPits: 1` lock reproduces the
  classic single center pit).
- **Generated maps dig additional trenches procedurally**, drawn per seed
  in three placement classes: **instead of an obstacle** (a slot that would
  raise cover digs a pit — cover you stand in rather than behind), **in the
  gaps between a column's obstacles** (the corridor stays open; crossing it
  the slow way is a choice), and **in each endzone around the flag** —
  behind the pedestal toward the home edge, and above and/or below it.
  Every dig is mirrored under the map's team symmetry, so neither team gets
  a private pit, and the exact trench set is pinned in the replay's
  `mapSpec` like the rest of the geometry.
- **Two runtime knobs steer the digging** (game config, generated maps
  only): `mapPits` locks the exact TOTAL pit count (0..64) — even counts
  place symmetric pairs; an **odd count anchors its extra pit at the exact
  map center**, the one spot that is its own image under both mirror and
  rot180 symmetry, so odd and even counts are equally team-fair. When the
  candidate spots can't host the full request the map places as many as
  fit. `mapPitDensity` (0..1000, default 100) scales the per-class draw
  chances instead when no exact count is locked — 0 digs nothing, 200 digs
  roughly twice as much. `mapPits` wins over `mapPitDensity`.
- You are "in" the trench exactly while your body center is inside the
  square; every effect below applies instantly on entry and ends instantly
  on exit.
- **Getting in is fast; climbing out is slow.** Dropping into a pit and
  moving around inside it run at full speed — momentum carried in is kept.
  But while your center is inside, any movement **away from the pit's
  center** — climbing a wall to leave — has its speed cap and acceleration
  divided by five, and outward momentum sheds to that cap. A pit is easy
  to take and costly to abandon.
- **Occupants fire their gun at 1/3 rate** (each shot's cooldown is three
  times the normal length). This composes with the shield/heart-carrier
  slowdown by taking the maximum, never the product.
- **70% of gun shots that would hit an occupant fly straight over
  instead**: the occupant is below grade, so the bullet misses, deals no
  damage, counts as a miss for the tagger, and **carries on down the ray**
  — it can land on an exposed body behind the trench, or on the far wall.
  The duck is rolled per crossed occupant on the deterministic sim RNG.
- **Shots fired from inside the same trench are never ducked** — the
  protection is against fire from outside; two players inside the same
  trench duel normally.
- The fly-over protection applies to **gun shots only**. Spray cones deal
  their ordinary damage regardless of trenches on either side.
- **A grenade blast's damage depends on the trench it lands in, not the
  trench radius.** A blast that lands in the SAME trench as a victim traps
  them below grade with nowhere to duck: **6 hit points**, GrenadeTrenchDamage
  — three times the open-field amount, and lethal to a bare cog through a
  6 hp shield in one blast. A victim standing in ANY OTHER trench — the
  blast landed in the open or in a different pit — is mostly shielded by
  their own pit's lip: **1 hit point**, GrenadeTrenchSplashDamage. Anyone
  outside every trench takes the ordinary GrenadeDamage (2) exactly as
  before. The landing splat and blast-flash animation are truncated to the
  trench's own 56×56 footprint when the blast is trapped in one, instead of
  spilling out to the full open-field blast size — what you see burning is
  what's amplified.
- Occupants are still subject to normal fog-of-war visibility — the trench
  itself grants no concealment.

## Paint puddles

- A **paint puddle is an organic splat-shaped floor hazard, nominally ~64 px
  across** — a union of overlapping paint discs (one core plus a few flung
  lobes, reaching at most 45 px from the anchor) drawn as a violet spill on
  the ground. The painted spill IS the gameplay footprint — you take the
  damage roll exactly where you see paint. It never blocks movement,
  bullets, or vision, and never slows anything — its only rule is damage
  over time.
- **Every full second (24 ticks) your body center spends CONTINUOUSLY
  inside a puddle rolls a `puddleDamagePct` (default 20%) chance of 1
  damage.** The roll's damage goes through the shield layer first, like
  every weapon's. Stepping out — even for one tick — restarts the second;
  dying resets it too.
- A lethal puddle roll is an **environmental death**: no player is credited
  with the kill (the log reads "dissolved in a paint puddle"), but it counts
  as a normal combat death for lives and respawn.
- **Puddles are config-gated and ship in NO map by default.** `mapPuddles`
  (0..64, COUNT mode only — there is no density mode) places that many on a
  2-team generated map: even counts place mirror-symmetric pairs, an odd
  count anchors its extra puddle dead center. Each blob's shape is drawn
  from the map seed; a placed pair is the blob plus its exact symmetry image
  (bit-exact integer transforms), and the center blob's ring is stitched
  self-symmetric, so the hazard is always team-fair. Spots land on open
  floor clear of walls, trenches, other puddles, and both teams' base
  pockets; the exact set is pinned in the replay's `mapSpec`, so playback
  never re-rolls it. 4-team maps do not support puddles yet (an explicit
  request errors).
- Each puddle is stated to policies as an init-snapshot marker,
  `puddle <x0>,<y0> <x1>,<y1>` — see the stated-marker section below.

## Med kits

- **Two med kits sit on the center line** — at one third and two thirds of
  the field height, nudged to the nearest walkable floor.
- **Touching one while hurt restores your hit points back to full.** A
  healthy player walks over it untouched — a kit is never wasted.
- **A taken kit respawns 30 seconds later** in the same spot.
- Observation label: `med kit`. Kits are fog-gated like the grenade
  pickups: you see one only where you have vision.
- **Med kits never block anything** — not movement, not bullets, not
  line of sight. They are floor pickups, not cover.

## Shields

- **One shield sits deep in each team's endzone.** Red's is in the same back
  column as the corner grenade pickups but in the BOTTOM half (three
  quarters of the map height down, between the side midpoint and the bottom
  corner grenade), nudged to the nearest walkable floor. The spray cans hold
  the matching top-half spots. On a **compact endzone** (disc/square) there
  is no back column: the shield sits inside the zone below the pedestal and
  the spray can above it.
- **Every other team's shield is Red's spot under the map's own symmetry**
  (GameVersion 30) — mirrored on a mirror map, rotated on a rotational one,
  and a quarter turn round on the 4-team boards. Only that image sits in
  terrain equivalent to Red's; a mirrored copy on a rotational map lands in
  the transpose (4-team) or in the spray can's terrain (2-team), which is a
  fairness difference in cover and sightlines, not a cosmetic one.
- **Touch a shield to pick it up** — either team may take either endzone's
  shield. A shield is a **3 hp armor layer on top of your base hit points**:
  damage depletes the shield layer first, and only then your base hp. The
  layer draws as blue pips appended to the overhead hp bar (base hit points
  stay green) and as the ` shield <s>` tail of the bar's label. A
  pickup refills the layer to 3 but **never heals base damage** (med kits
  do that) — so a worn carrier can take another shield to restore the
  layer, while a carrier whose layer is intact leaves the spawn untouched.
- **A depleted layer breaks the shield outright** (GV23): the moment the
  last shield hp is absorbed, the shield is gone — the carry icon and the
  `shield` label drop, the fire slowdown ends (an in-flight slowed cooldown
  re-clamps to the normal length), and the player may take a fresh shield.
- **While carrying a shield you fire 3x slower.** A fresh player with a
  fresh shield has 6 effective hp (3 base + 3 shield). Each shot you fire
  starts a cooldown three times the normal length until the shield breaks
  or you die. You can still move, carry the heart, and throw grenades.
- **A shield is lost when you die** and is not dropped on the ground; the
  taken endzone shield **respawns 30 seconds later** in the same spot.
- Observation label: `shield`. Shields are fog-gated like the med kits and
  grenade pickups: you see one only where you have vision, and a small
  marker floats over a shield carrier you can see.

## Cardboard barriers

- **Config-gated** (`barrierPickups`, default 0 = none): when on, each team
  gets that many folded-cardboard pickups (1 or 2), staged on the line from
  the team's base anchor toward map center — one at the midpoint, two at the
  thirds — nudged to the nearest walkable floor. Every other team's spots
  are Red's under the map's own symmetry, like the shields and spray cans.
- **Touch a pickup to carry one folded barrier.** Either team may take
  either side's pickups. **A barrier and a grenade cannot be carried
  together** — both are spent with button C — so a grenade carrier walks
  over the pickup untouched and vice versa. A taken pickup **respawns 30
  seconds later**; the carried sheet is **lost when you die** (never
  dropped).
- **Press C to place it where you stand.** The cardboard unfolds instantly
  into a **standing half-hex** — three sides of a hexagon, vertices
  `BarrierRadius` (24px) from your center at aim −90°/−30°/+30°/+90° — with
  the **flat middle side across your aim** (~21px in front), wrapping your
  front. Placement is a press-edge, no charge; the grenade's hold-to-charge
  lives on the same button but the mutually-exclusive carry keeps the press
  unambiguous.
- **Cardboard blocks paint, never sight.** The ~5px band stops gun shots
  and the spray cone (both damage and the drawn mist) exactly like a wall —
  but fog-of-war vision, movement, and grenades (which fly over every
  obstacle) ignore it entirely. Cover you can see through and walk through.
- **It takes 10 paintball hits** (`BarrierHp`): each blocked gun shot splats
  on the cardboard and chips one hit; the tenth shreds it. The spray cone is
  blocked but does no damage to it; grenade blasts ignore it.
- **Any cog that drives into the band flattens it instantly** — including
  the placer walking forward through their own front wall. Standing inside
  the half-hex is safe: the band is ~21px out, well clear of a body.
- At most **16 barriers stand at once** (`MaxBarriersPlaced`); placing past
  the cap folds the oldest standing barrier.
- Observation labels: `barrier` (folded pickup, fog-gated), `barrier
  carried` (marker over a carrier you can see), and the standing half-hex
  itself: `barrier up <x>,<y> f<brads> hp <n>` — placement center, facing,
  and hits left, updated live as it takes paint.

## Lives & respawn

- Each player has a fixed number of **lives**.
- When you die, you **respawn at a random spot in your endzone** after a short
  delay — as long as you have lives remaining (GameVersion 25; the spot is
  drawn fresh each death, anywhere in the home capture column, full map
  height, so campers can't sit on a known respawn point).
- When you run out of lives, you are **out for the rest of the round**.

## The hearts

- Each team's heart sits on its **home pedestal** inside the team's spawn pocket.
- **Stand on the ENEMY pedestal to steal its heart** (GV42). The steal fires the
  moment you are on the heart — there is no grab button and no pinpoint to find.
  The touch radius (`FlagPickupRange` = 34px) covers the **drawn heart**, which is
  60px across on a 96px pedestal disc, so any spot where heart pixels are under
  your feet takes it. Your own heart cannot be interacted with by your own team.
  While carrying you move **slower** but can **still tag**.
- If the carrier is killed (or disconnects), the heart **returns instantly to its
  own pedestal**. A heart is never left loose on the ground: it is either carried
  or sitting on its pedestal.
- Your own heart's **state** is always observable: its pedestal is never fogged,
  so an empty own pedestal means it is stolen — but the **thief itself is fogged**
  like any other enemy.

## Winning

A round ends immediately when either condition is met:

1. **Capture** — carry the **enemy heart** into **your own home capture zone**.
2. **Wipe** — the entire **enemy team is out of lives**.

If neither happens before the **time limit**, the round is a **lose-lose
draw** — there is no tiebreak, and both sides are penalized.

**The clock only counts down** (GV41): nothing extends it — the GV23
"action floor" (kills and heart steals banking overtime) is gone. `maxTicks`
is the exact scheduled end, and the broadcast clock counts honestly to 0:00.
With the grenade barrage configured, 0:00 does not end the round at all (see
below); without it, the scheduled end is still the scoreless-draw ceiling.

## Grenade barrage (config-gated endgame)

An anti-stalling mode that makes timeout draws effectively impossible. Off by
default; a league turns it on with `barrageMaxPerSec > 0` (requires a time
limit).

- When the game clock reaches **`barrageStartSec` seconds remaining**
  (default 30 — 4:30 elapsed on the default 5:00 clock), environment
  grenades start raining onto the field: **4 per second**
  (`barrageStartPerSec`) landing within a **40px band inside every map
  edge** at first.
- The barrage **escalates linearly over `barrageSaturateSec` seconds**
  (default 30): the target band deepens until it covers the **whole
  board**, and the rate ramps to **`barrageMaxPerSec`** (10-20/s
  recommended, hard cap 50) — with the defaults, the entire arena is under
  maximum bombardment exactly as the clock reads 5:00 / 0:00 remaining.
- Shells are **ordinary paint-bomb blasts** (same radius, damage, trench
  rules, shield soak, and floor stains as a player lob) with nobody to
  credit: no kill/multi-kill stats for the environment, and a victim's death
  logs `shelled by the grenade barrage`. Deaths, lives, heart return, and
  respawns behave like any blast death.
- **The clock is not the end** (GV41): with the barrage on, a round ignores
  the time limit entirely. Past 0:00 the whole board stays under maximum
  bombardment until at most one team has live players — the survivor wins,
  and a **draw requires the last players of two teams to die on the same
  tick**. (Without the barrage, a timed round still ends at the limit as a
  scoreless draw.)
- **Observability**: incoming shells are ordinary `grenade air` orbs and
  `blast stage <n>` landings on both streams, and an invisible marker states
  the escalation outright: `grenade barrage depth <n> rate <n> start <n>`,
  present from the first tick whenever the mode is on (depth and rate 0
  until the barrage latches). Shells only land within `depth` map pixels of
  some edge.

## Season 2 battle-royale elimination ruleset

The published `battle-royale-s2` configuration sets `brMode: true`: no
respawns, last team standing wins. The engine-level `false` fallback preserves
the deprecated direct-input simulation and is not the published mode.

- **No respawns.** A death is permanent — `lives`/`respawnTicks` are never
  consulted for a re-entry: whatever they're set to, one death is out for
  the rest of the round. Mechanically this reuses the "captured team is
  permanently out" contract the classic 4-team mode already has (its
  players' lives are forced to 0), so the same HUD, roster, and gameHash
  paths that already render a permanently-out player render a BR death
  correctly with no client changes.
- **Winning: last team standing.** The round ends the instant at most one
  team has a living player — the survivor wins; a simultaneous final wipe
  is a **draw**. This is the SAME wipe check classic and 4-team play already
  use (generic over however many teams the map seats), just the only way a
  BR round can end.
- **Flags never end or score it.** Captures/hearts are inert in this mode:
  a capture can never eliminate a team or end the round, however a map
  configures its flags. (A BR map is expected to run flagless — no hearts
  to fight over at all — but this holds even if it doesn't.)
- **Timeout resolves by tiebreak, not an automatic draw.** If the clock
  runs out with more than one team still standing, the round is decided:
  the team with the most **living players** wins; a tie there breaks on
  total **damage dealt**; a tie on both is a draw. (Classic and 4-team play
  still resolve a timeout as the unconditional lose-lose scoreless draw
  described under Winning above — this tiebreak is BR-only.)
- **Environmental deaths count too.** A death from any source — combat, the
  shrink-zone hazard, the grenade barrage — goes through the same
  no-respawn path; the mode doesn't care how a team lost its last player.

## Season 2 battle-royale shrink zone

The published `battle-royale-s2` configuration supplies a six-phase closing
rectangle. The engine accepts an empty `zonePhases` list for mechanics tests
and custom configurations; empty means no rectangle, damage, or markers.

- **The zone is a rectangle of the map's own aspect ratio**, scaled by a
  scalar `z` about a CENTER drawn once per game from the deterministic sim
  RNG — never a fixed map-center circle. The draw is uniform over positions
  where the smallest (final-phase) rect fits fully on-board with a margin;
  earlier, larger phases derived from that same center may extend slightly
  past the map edge for an off-center draw, exactly like a real battle-royale
  circle that is not always dead-center at the drop.
- **The schedule is a list of phases**, each `{z, waitTicks, shrinkTicks,
  dps}`: `z` (0..1, exclusive of 0) is the target scale; the rect holds its
  PREVIOUS size for `waitTicks`, then linearly interpolates into the target
  over `shrinkTicks` (0 snaps instantly once the wait ends). Phase 0's
  "previous" size is the implicit full field (`z = 1.0`) — a hold at full
  size before the first real shrink is authored as phase 0's own
  `waitTicks`, not a degenerate `z = 1.0` entry (which is always rejected:
  see below). `z` must fall STRICTLY across phases, including against that
  implicit 1.0, so the pressure never eases mid-match.
- **Standing outside the current rect for a full second (24 ticks,
  continuous — the same cadence as a paint puddle's damage roll) deals that
  phase's `dps` hit points, exactly** — through the shield layer first, like
  every other source of damage. Unlike a puddle's percentage roll this is
  deterministic: `dps` is an authored rate, not a chance, so there is no RNG
  draw. Stepping back inside (or dying) restarts the second. Once every
  configured phase has resolved, the rect holds at the last phase's target
  and `dps` forever. A lethal tick is an **environmental death** (no kill
  credit; the log reads "caught outside the zone").
- **Observability**: the live rect is stated every frame on both streams as
  two invisible markers, `zone <x0>,<y0> <x1>,<y1>` (the current rect) and
  `zonenext <x0>,<y0> <x1>,<y1>` (the rect the current one is interpolating
  toward, so a policy can pre-rotate before the boundary arrives) —
  inclusive map-pixel corners, present from the first tick whenever the mode
  is on. A minimal cosmetic band (four flat bars) traces the current rect's
  border on both streams too, so the boundary is visible without parsing the
  markers; the fuller paint-tide/stormfront treatment is a later pass.
- **Config validation**: `z` must be a number greater than 0 and at most 1
  per phase, and must fall strictly across the whole schedule (including the
  implicit phase-0 value of 1.0); `waitTicks`/`shrinkTicks`/`dps` must not be
  negative; at most 8 phases.

## Season 2 battle-royale loot options

Seven independent BR mechanisms remain available as explicit configuration
options. Their neutral engine values preserve replay compatibility: omitted
keys add no pickup family or hash input. `lootStart`, `downedMode`,
`giveItem` and the spawn-loot-seeding knobs below require `brMode: true`;
the published `battle-royale-s2` configuration arms the first two
(`coworld_manifest_paintbot.json`'s `battle-royale-s2` variant), at their
ruled default timing constants (`downedBleedOutTicks` 360, `downedReviveTicks`
48, `downedEscalation` on). `giveItem` ships dark and arms only on explicit
go (its activation additionally needs the play shell's HANDOFF vocabulary —
see the flag's own bullet).

- **Hit points per BR variant** — no new flag: the existing `hitPoints`
  config is live under `brMode` (proved end-to-end by
  `tests/test_loot_rework.nim`). A 4-hp or 5-hp BR variant is a one-key
  manifest edit; the published Season 2 variant pins 3.
- **`medKitCount`** (int, default `-1`): caps the placed med kits. `-1` =
  the map's own full set (the pre-existing path bit-for-bit), `0` = none —
  the bandages-instead-of-kits test arm — `N` = the map's first N points.
- **`bandagePickups`** (int, default `0`): places N bandage pickups at the
  map's med-kit points (actives then candidates, cycling). A bandage is
  CARRIED (up to 3, `BandageCarryCap`) and self-applies +1 hp after 3
  calm seconds (`BandageApplyTicks` without taking damage); the calm clock
  restarts per application, so a stack heals one point per quiet spell.
  Taken bandage spawns refill on the med-kit cadence. Analysis stream:
  `item_pickup` with item `bandage`; `heal` with weapon `bandage`,
  amount 1.
- **`sprayCount`** (int, default `-1`, owner directive 2026-09-05): caps the
  placed spray cans, the same "-1 = the map's own full set, N = the map's
  first N points" rule `medKitCount` uses (deterministic, not reseeded per
  episode). A cap can only shrink the placed set. The published Season 2
  variant pins `6` (pre-pivot objbalance analysis, rec B: sprays were the
  map's 2nd-most-common item and the intended rarest).
- **`grenadeCount`** (int, default `-1`, owner directive 2026-09-05): a
  TARGET count, not a cap. `-1` keeps the map's own authored/formula set,
  byte-identical; `0..N` (an authored count) caps down like `sprayCount`;
  past the authored count it INJECTS extra copies, cycling back through the
  same authored sites ring-offset off their anchor (the overflow idiom
  `bandagePickups` already uses against its own RETREAT anchors). The
  published Season 2 variant pins `22` (same rec-B analysis: grenades were
  the map's scarcest disposable and the intended most common). BR-only —
  the classic 2/4-team per-team formula ignores the knob.
- **`lootStart`** (bool, default off, brMode only): everyone spawns
  UNARMED. The gun is two lootable halves — the **marker** (`hasGun`) and
  the **hopper**, its ammo (`hasHopper`) — placed as one-shot crates (a
  crate arms exactly one cog and never refills). A cog needs BOTH to fire;
  the spray can stays its own weapon with its own pickup. Crate points: a
  map may author `weaponSpawns`/`hopperSpawns` in its spec (optional keys,
  pinned only when present); otherwise markers land on the map's grenade
  pickup points and hoppers on its med-kit points (never the spray-can
  points — a co-located can would disable the looter's gun). Analysis
  stream: `item_pickup` with items `gun` / `hopper`. Broadcast item lists
  and the first-person carried-items HUD carry `gun`/`hopper` tokens while
  armed.
- **`downedMode`** (bool, default off, brMode only) — the ruled
  ghost-tag-revive shape: a lethal hit DOWNS instead of kills. The victim
  becomes a **ghost of itself** — frozen in place, non-colliding (upright
  cogs walk through it), unable to fire, loot, shout, or be hurt by
  hazards — and stays `alive` on the wire (that is what makes it
  revivable). An upright teammate standing within `DownedTagRange` (40 px)
  for `downedReviveTicks` (default 48 = 2 s) **tags it back in at 1 hp**;
  the channel resets the tick the tag breaks, and the reviver's exposure
  IS the cost. An enemy **gun** hit splats the ghost — immediate confirmed
  elimination (spray, grenades, puddles, the zone and the barrage never
  confirm). An untagged ghost **bleeds out** after
  `downedBleedOutTicks` (default 360 = 15 s), halved per successive down
  while `downedEscalation` (default on when armed) holds, floored at 2 s —
  **no hard down-cap**, per the genre ruling. A team with no upright cog
  left fades out at once (nobody could ever tag them back), which is what
  ends the round. Kill credit lands at the DOWN (the weapon site's
  existing credit — the down is the combat achievement); the permanent
  death is a separate, later `death` row. Analysis stream: `downed`
  (source = victim, target = downer, amount = the victim's down count) and
  `revived` (source = tagger, target = revived, amount = channel ticks) —
  two appended event kinds, tail ordinals, archived replays unaffected.
  Broadcast: the first-person self HUD and the omniscient map players
  carry a `downed` flag while the mode is armed.
- **`giveItem`** (bool, default off, brMode only) — **play-called item
  exchange**: a seat that has DECLARED a handoff (`declareHandoff`, the
  engine seam for the play shell's HANDOFF play) and then HOLDS
  `GiveItemRange` (= `DownedTagRange`, 40 px) adjacency to its duo partner
  for `GiveChannelTicks` (= `DownedReviveTicksDefault`, 48 = 2 s)
  transfers the declared item — **marker** (`gun`), **hopper**, or
  **bandage** — to that partner. Both channel constants DERIVE from the
  revive channel's own (owner spec: mirror the revive channel). The
  channel is interruptible by construction: it resets to zero the tick any
  condition breaks (range, either side downed/dead, the giver no longer
  holding the item, the recipient unable to take it — marker/hopper are
  binary, bandages cap at `BandageCarryCap`); the declaration itself
  stands until completion or the giver's death/down. **No declaration, no
  transfer** — proximity alone never moves an item, so an endgame cover
  huddle trades nothing (owner ruling 2026-09-02: no auto-share; guns,
  hoppers and bandages alike move by play or death-drop only). Analysis
  stream: `item_give` (source = actor, target = recipient, `item`,
  amount = channel ticks) — one appended event kind, tail ordinal,
  archived replays unaffected; every row is by construction a play-called
  act (dHandoff's intent-clean predicate). Broadcast: a declared giver's
  self HUD, omniscient map entry and board roster row carry a `handoff`
  {item, progress, needed} object while armed (the progress-arc feed);
  idle and dark bytes are untouched.
- **`dropItem`** (bool, default off, brMode only) — **button-chord item
  drop**: holding the **aim-pair chord** (B *and* Select together — the
  combination the engine has always ignored for aim, since it turns only on
  `b != select`, so no archived replay ever used it) for `DropChordTicks`
  (10 ≈ 0.4 s) **while carrying a droppable** spills the highest-priority
  carried item to the ground. Priority is **spray can → marker → hopper →
  grenade → barrier → bandage**; marker and hopper are droppable only under
  `lootStart` (off it they sit at a constant `true` and are not real
  inventory), and the spray can is not droppable under the paintball loadout
  (there is nowhere to pick another up). The drop **latches**: one hold is
  exactly one item however long it is held, re-arming only when the chord
  breaks. Dropping a **spray can clears `hasSprayPaint`, which hands the gun
  back** (`canFire`'s guard) — the only exit from the spray lock, and the one
  thing `giveItem` cannot do. A dropped item is an **open** pickup: anyone in
  `DroppedPickupRange` may take it (no team gate — Minecraft-style), except
  the dropper itself for `DropperRegrabTicks` (24 = 1 s) so a drop is not
  vacuumed straight back up. Drops never respawn, are capped at
  `MaxDroppedItems` (64, oldest evaporates), and expire after
  `DroppedItemTtlTicks` (60 s) unclaimed. **Coexists with `giveItem`** — drop
  is the free/flexible path, the handoff still guarantees partner delivery.
  Human seat: **Q**. Play shell: the standing `drop` order. Emits the
  `item_drop` event (source = dropper, item, x/y) and an `item_pickup` when
  claimed; dropped items render with their family's existing ground art and
  are fog-gated like every fixed pickup.

- **`lootSpawnSeedGuns`** / **`lootSpawnSeedHoppers`** (int, default `0`,
  brMode + `lootStart` only) / **`lootSpawnSeedRadius`** (int, default `0`,
  read only while either count above is positive) — **spawn-area loot
  seeding** (owner-approved starter fix 2026-09-03, verbatim: "i like the
  idea of filling spawn areas with guns and hoppers so they accidentally
  grab it anyway"): the field's policies mostly do not route toward loot
  (78.8% of measured BR downs were zone/environmental, from unarmed cogs),
  so rather than teach every playbook to path to a crate, these ADD N
  marker and M hopper crates within `lootSpawnSeedRadius` px of EVERY spawn
  cluster (one cluster per team; a BR duo's two seats already land within
  `SpawnShareStagger`, 24 px, of each other around one shared spawn point)
  ON TOP of `resetLootCrates`'s own placement — the map's authored pool or
  its grenade/med-kit fallback, which is untouched. Additive only: the
  existing global scatter is never rewritten. Each candidate resolves
  through `nearestWalkable`'s expanding-ring search, the same guarantee
  every other pickup family uses, so a seeded crate can never land inside a
  wall or an unreachable pocket. Pure integer 8-compass-direction geometry
  (no floats/host libm — replay-determinism, same rule as arena.nim's
  DiamondCos table), never touches `sim.rng`, so arming it cannot perturb
  any other rng-consuming draw and re-simulating one seed always seeds the
  same crates at the same pixels. Both seeded families stay one-shot, same
  as the base crates (see `resetLootCrates`'s own note). LOOT ECONOMY NOTE
  (flagged, not solved): arming this raises the total gun/hopper count on
  the field — weigh that against fight pacing during the feel-pass.
  generate --scale N.N` (default 2.6, the doctrine giant — omitting the
  flag draws bit-identically to before) generates the field at another
  scale through the same doctrine gates, and the BR variant pins whichever
  full spec it certifies. `gunRange` re-derives from the scaled field; the
  duo spawn pocket deliberately does not scale.

## Season 2 glory scoring (GLORY v13 multiplier economy)

Glory is the **league score**, not a side ledger. Since the glory-as-league-
score pass, `scores[slot]` in the episode results carries the seat's own team
glory total rather than the RL training reward (`roster.nim:920-941`); the
training reward still exists untouched on its own per-tick channel
(`player.reward`), and "Engine reward scoring" below describes that channel,
not this one.

**The win gate is gone.** `playerWon` no longer gates the banked score
(`roster.nim:1028-1048`): every seat reports its own team's ledger — win, lose
or draw — including a negative total for a friendly-fire-heavy duo. The one
gate left is `sim.phase == GameOver`, so an episode that never concludes still
banks 0 for everyone. `win[]` is still gated on `playerWon`, unchanged. Nothing
gates the drop behind a config flag, so it holds on every variant, armed or
dark.

The pure-multiplier economy itself (frozen 2026-09-02 contract) is per-flag.
Each key below is its OWN manifest `game_config` key, independently settable —
never coupled to `lootStart`/`downedMode`, to a variant switch, or to each
other (per-flag activation, recut contract Amendment 2 §1). All three recut
flags default off (`sim_config.nim:130`, `:133`, `:137`), so merging is not
arming: arming is an explicit, separate manifest publish. **What `coworld_manifest_paintbot.json`
publishes on `main` today:**

| variant | `gloryMultiplierRecut` | `deedMintCaps` | `winAsMultiplier` |
| --- | --- | --- | --- |
| `battle-royale-s2` (the S2 flagship) | on | on | off |
| every other variant | off | off | off |

- **`gloryMultiplierRecut`** (bool, default off, BOTH modes; ARMED on
  `battle-royale-s2`): no base points — episode glory = seed(1)
  (`glory.nim:2330`) × the product of integer act multipliers
  (`RecutClassTable` `glory.nim:2335-2384`, `RecutTierClass` `:2386` = tiers
  I–V at ×1/×1/×2/×2/×4), the whole product then divided per friendly-fire
  step. One event contributes exactly one integer factor, composed in
  `recutFactor` (`glory.nim:2592-2613`) as class × heat × carry × ally-stack:
  - **Territory shifts the RUNG, not the score**: a deed on enemy ground climbs
    one integer rung, ×2→×3 … ×8→×9 (`glory.nim:2572-2591`). Only classes
    already at 2 or above shift (`:2589-2590`); ×1 commons never shift on any
    ground. Ground ownership is nearest-home-pedestal Voronoi
    (`sim.nim:239-242`), and `SiteMultNeutralPct` (`glory.nim:954`) is
    unreachable — `deedSitePct` passes `ownerIsNone = false` unconditionally.
  - **Fibonacci teammates-in-context stack** ×1,2,3,5,8,13 for k = 1…6, clamped
    both ends (`glory.nim:2393`, applied `:2564-2570`). `k` counts distinct cogs
    on the victim's open damage incident within `AssistWindowTicks` = 120
    (`glory.nim:1520`, counted in `sim.nim:2564-2607`); in BR that includes cogs
    of OTHER duos co-engaged on the same victim, never the victim's own duo.
    **Kill sites only** — `awardDeed` defaults `stackK` to 1 (`sim.nim:330`) and
    `sim.nim:2790-2792` is the sole call site passing a real one, so captures,
    steals, wipes and achievement claims take no stack.
  - **Heat and carry** fold per event under their existing gates: heat
    ×1/×2/×4/×8 by rung (`glory.nim:855`) at 2/5/10 embers (`:866`), never for
    achievements (`:2135-2138`); carry ×2 on drama deeds while holding an enemy
    heart (`glory.nim:976`), which never lights on a flagless BR map — the
    carrier scan finds nobody (`sim.nim:368-373`).
  - **Friendly fire is an uncapped compounding DIVISION**, not a class: BR ÷2
    per incident, CTF ÷2 per two incidents (`glory.nim:2629-2637`), applied at
    `:2654-2663` with the int report flooring the division.
  - **First-claim ×3 on the top tier only**: `AchievementFirstMultPct`
    (`glory.nim:1658`) survives as an integer factor, but `sim.nim:520` gates it
    on `tier == AchievementTiers - 1`.
  - ×1 commons still mint, pop and count toward K/D, Elo and the achievement
    gates — they carry no score weight, and no live-state multiplier can attach
    to them (`glory.nim:2606-2607`).
  - BR-only marquee deeds mint only under this flag: `dDuoDown` ×2
    (`glory.nim:2368`), `dClosingTime` ×2 (`:2369`), `dLastLight` ×4 (`:2373`),
    `dVictory` ×8 (`:2374`).
  - Off: every number prices exactly as GLORY v12, fixtures byte-identical.
- **`winAsMultiplier`** (bool, default off; **off on `battle-royale-s2`
  today** — reads only under an armed recut): retires the `dVictory` deed for a
  deterministic, composition-neutral BR win factor of ×4
  (`glory.nim:2666` `RecutWinFactorBR`, applied `:2677-2683`) folded into the
  canonical product at finalize — it pays no heat, no territory, no carry, no
  stack, and never routes through `recutFactor`. Also bumps the `dClosingTime`
  base rung 2→3 (`glory.nim:2583-2588`) and prices two further deeds,
  `dTagBack` ×2 and `dJointAct` ×2 (`glory.nim:2382-2383`), which mint only
  under this flag (`sim.nim:7790-7792`). The CTF win factor is deferred to
  CTF-arming; `recutWinFactor` returns ×1 there. **With the flag off, as it is
  today, the win pays as the `dVictory` ×8 deed** (`sim.nim:5683-5686`) and
  `dTagBack`/`dJointAct` are not priced at all.
  **`dJointAct` is alliance-only (GloryVersion 15, owner ruling 2026-09-08):**
  a contributing seat mints only if it shares an ACTIVE formal pact
  (`pactActive`, `sim_state.nim:219`) with at least one OTHER contributing
  team on the same 120-tick damage incident (`recutJointActOnDamage`,
  `sim.nim:2762`); unallied multi-team co-fire on one victim now mints
  nothing. `dTagBack` was checked and needed no change: its cross-team
  revive already requires `pactActive` as a precondition (`sim.nim:8068-8070`,
  ALLIANCE P1 2026-09-07), so it could never mint off a non-pact cross-team
  revive.
- **`deedMintCaps`** (bool, default off; **ARMED on `battle-royale-s2`** —
  reads only under an armed recut): a per-episode, per-duo mint budget for
  every deed whose repeat count is not bounded by a scarce contested resource
  (`RecutMintCapTable`, `glory.nim:2436-2539`; applied `sim.nim:411-441`). The
  first `cap` mints fold their factor normally; every occurrence after that
  folds 1 and scores nothing — a flat budget, not diminishing rungs. Only the
  SCORE is bounded: the deed still mints, pops, counts, climbs heat and reaches
  the wire, so no achievement gate or analysis counter moves. Budgets:
  `dTagBack` 3 (`glory.nim:2522`), `dJointAct` 6 (`:2530`), `dDuoDown` 4
  (`:2510`), `dShieldSoak` 3 (`:2500`); every other row is 0 = uncapped. The
  flag also drops the product saturation bound from the 2^62 int64 overflow
  guard (`glory.nim:2404`) to 2^26 = 67,108,864 (`:2420`) — a defense-in-depth
  backstop that should never bind, and an episode reporting exactly that number
  is a clamped one.
- **`stampRealizedConfig`** (bool, default off): at episode finalize the
  engine emits the realized-config stamp — `{stampVersion, realizedBuild
  {gameVersion, gloryVersion, engineStamp}, variantId, flagSet}` (flagSet
  = the S2 dark-flag family as sorted `key=value` pairs, false values
  included) — into the events summary row and the episode log.
  Observability only; independent of every other flag.
- **`variantId`** (string, default empty): self-label echoed into the
  stamp and the replay header so replay-only audits can name the
  publishing variant without platform access.

The economy version is `GloryVersion = 18` (`glory.nim:301`). It bumps on any
pricing change, and a score compared across versions is not a comparison.
Entrant-facing guidance on what to do differently under this economy is in
[`players/baseline/README.md`](../players/baseline/README.md).

Staging variants `battle-royale-s2-lootstart` and `battle-royale-s2-downed`
(published behind the flagship in `coworld_manifest_paintbot.json`) carry
exactly one of the two loot flags each, so the S2 flag family can be staged
or bisected per-flag instead of riding one coupled variant switch.

## Season 2 glory scoring — catalog update (GLORYVERSION 16 → 17)

**This section is live.** Every flag it describes is armed on the
published Season 2 variant `battle-royale-s2` in
`coworld_manifest_paintbot.json` — `catalogV3Reprice`, `placementRampV3`,
`brAssistRescueUngated`, `gloryFixedPointScale`, `gloryMultiplierRecut`,
`winAsMultiplier`, `deedMintCaps`. It shipped as GLORYVERSION 17 and has
since been superseded by **GLORYVERSION 18** (the S8 section below, and
the era record in [`docs/wiki/_era.md`](wiki/_era.md)), which repriced the
finishing rewards again — so where this section and the S8 table disagree
on a number, the S8 table is today's.

Here is what it changed for every player:

- **Tags, hot streaks, contested-ground tags, and assisted tags are worth
  more.** The shared multiplier table described above — the one that turns
  a tag into a glory number — gets repriced upward across most of its rows.
  How you earn glory is unchanged (you still have to tag, hold ground,
  chain a hot streak, or fight alongside teammates); only what each of
  those is worth on the scoreboard moves.
- **Finishing rewards are repriced, and survival now trickles in
  continuously.** The bonus for finishing among the last 8, last 4, or the
  final 2 teams changes value, and — new — a team that is still alive earns
  a small, steadily-growing survival bonus the whole time it survives, not
  only at those three finish lines. Two players eliminated before the
  final 8, one much later than the other, will now score differently for
  it; before this change they scored identically (nothing) until the first
  finish line.
- **Assists and rescues count in battle royale.** Tagging a teammate back
  in or covering their revive already scored points in capture-the-flag;
  this closes the gap so the same actions score in battle royale too —
  previously they were worth nothing there.
- **Allied group takedowns are credited correctly.** When you are formally
  allied with another team and a kill takes down, or completely wipes out,
  an entire allied GROUP of enemy teams — not just the one team you tagged
  — the game now recognizes and credits the group bonus. Before this
  change, that exact situation could be silently scored as an ordinary
  single tag instead, worth less than what actually happened on the field.
- **A few small bonuses stop rounding away to zero.** Some multiplier steps
  are smaller than a whole extra multiple and used to disappear entirely
  when combined with certain other bonuses; they now register as the
  small partial bonus they were always meant to be.
- **Nothing about tagging, movement, spray, grenades, hearts, or the win
  conditions above changes.** This only changes how many glory points a
  tag, a finish, an assist, or a group takedown is worth — never whether
  or how you earn one.

This ship moved the glory economy version from **GLORYVERSION 16** to
**GLORYVERSION 17**; the live version today is **GLORYVERSION 18** (S8,
below). A score is only ever comparable to another score from the same
GLORYVERSION — a leaderboard should not blend seasons across that line.
What the two competing predictions said about how much of a typical score
moves from "how you finished" to "what you actively did" during the match
— and how far off a first estimate turned out to be from a real
measurement of games actually played — is exactly the kind of claim this
project holds itself to double-checking against real games once it has
shipped, rather than trusting the first estimate.

## Season 2 glory scoring — GLORY GRADIENT S8 (GLORYVERSION 17 → 18)

**This section is live.** The published Season 2 variant
`battle-royale-s2` runs **GLORYVERSION 18** from build tag
**`paintbot-v0.7.397`** (S8 merge sha 1b92ec46), as recorded in
[`docs/wiki/_era.md`](wiki/_era.md) — the one place these numbers are
written, and the source of truth for this claim. Scoring only, not the
wire (GameVersion stays 63), so no fixture re-record was owed. Every
constant this ship moved — old value to new value — is in the table
below; nothing not listed here changed.

| Constant | Old | New | Note |
| --- | --- | --- | --- |
| Mint-cap product ceiling (`RecutProductCapArmed`, live only when `deedMintCaps` is armed) | 16,384 reported | 2,097,152 reported | Sized against the real GV62 cohort; see `CAP-CEILING-S7.md` "Decision" |
| Achievement Tier IV (Clean Sheet / Sharpshooter, non-first claim) | ×1.05 | ×2.5 | Lead ruling R4 — keeps the five-tier ladder monotonic under the new ceiling |
| Achievement Tier V non-first claim (Longshot) | ×2.00 | ×3.0 | Lead ruling R5. Tier V **first**-claim stays ×3.46, unchanged, still the top of the ladder (3.46 > 3.0 > 2.5) |
| `achievementLightableModes` (battle-royale-s2 flagship variant only) | dark (mechanism landed unarmed in #512) | armed — a **tier-completion bonus**, never a "light-up" | Rollback-only switch: flip it false and the mechanism goes dark again, no code change |
| Placement — `dFinal8` (last-8 finish) | ×1.00 | ×1.15 | Owner decision 2026-09-10, PLACEMENT LADDER B |
| Placement — `dFinal4` (last-4 finish) | ×1.00 | ×1.30 | Owner decision 2026-09-10, PLACEMENT LADDER B |
| Placement — `dFinal2` (finalist) | ×1.30 | ×1.60 | Owner decision 2026-09-10, PLACEMENT LADDER B |

All three placement rungs stay strictly below the ≥2× population line the
gate menu screened candidates against, so this move does not make a
placement finish "pop" the score the way a top-decile achievement or
kill-chain claim can — it stays the small, deliberate nudge the S5 ramp
was designed as, just no longer crushed to a near-zero marginal value for
`dFinal8`/`dFinal4`.

The table below is never-shown elsewhere in this document and is included
here for completeness — none of these digits move in this ship:

| Constant | Value | Note |
| --- | --- | --- |
| `dClosingTime` win-bumped base | ×1.10 non-win / ×1.20 win | Unchanged by S8 |
| Heat ladder rungs | ×1 / ×5 / ×14 / ×36 | Unchanged by S8 |
| Territory shift | +2–6% | Unchanged by S8 |
| Survival credit | ×1.02 folded every 720 alive ticks (30s), compounding — but **skipped entirely while the seat's unscaled accumulator is ≤64** (`RecutMinAccumulatorForSmallPct`, `glory.nim:3025`; the 100<pct<200 rule at `glory.nim:3074-3075`). Nominal ×1.02<sup>n</sup>; **realized ×1.0002 mean / ×1.0000 median** per seat, measured on the live GLORYVERSION 18 cohort (r4828–r4833, n=1,440 seat-episodes) | Unchanged by S8. The continuous placement ramp: classed with placement as **handed to** the seat, not chosen by it |

Survival credit is the one price in that table no button presses: every
30 seconds a seat stays alive, its team's product is multiplied by 1.02,
so alive time on its own compounds the team's score, with no deed
required. It is grouped with the placement rungs rather than with the
flat everyone-gets-it constants, and that is a considered call, not an
accident of the name: survival credit is not paid to every seat equally
the way a constant floor is — it is paid in proportion to how long you
last, and in a sixteen-player solo battle royale how long you lasted
**is** where you finished, measured continuously instead of at three
milestones. It is the placement ladder's continuous twin.

**What it is actually worth today is close to nothing, and the nominal
figure is not the effect.** Compounding ×1.02 by the roughly eight
firings an episode sees would suggest ≈×1.16, but that is arithmetic, not
a measurement, and it is wrong twice over. Those eight firings are spread
across all sixteen seats — the typical seat gets half of one, and the most
any seat drew in a full live cohort was five. And any factor between ×1.00
and ×2.00 is **skipped outright — not applied and rounded away** — while
the seat's unscaled accumulator still sits at or below 64
(`RecutMinAccumulatorForSmallPct`, `glory.nim:3025`; the 100<pct<200 rule
at `glory.nim:3074-3075`), so the credit is exactly zero until a seat has
already climbed well past the floor on real deeds. That gate, not
rounding, is why the realized number below looks the way it does.
Measured on the live GLORYVERSION 18 cohort (rounds 4828–4833, 1,440
seat-episodes): realized ×1.0002 mean, ×1.0000 median, ×1.0612 at the
very best seat, with 0.07% of seats seeing as much as ×1.05. Every
score decile but the top one realizes exactly ×1.0000; the top decile
realizes ×1.0017. Survival credit is, for now, a shape the economy has
rather than a number that moves it.

This ship moved the glory economy version from **GLORYVERSION 17** to
**GLORYVERSION 18**. A score is only ever comparable to another score from
the same GLORYVERSION — a leaderboard should not blend seasons across that
line.

## Engine reward scoring

The published Season 2 variant uses `scoring: "classic"`, with the BR placement
bonus and engagement gate described in [`ENV_VARIATION.md`](ENV_VARIATION.md).
This is the RL training reward on `player.reward`, delivered per tick over
`buildRewardPacket` — a **different channel** from the banked league score,
which carries glory (see "Season 2 glory scoring" above, and
`roster.nim:920-941`). The rule below is sparse and win-only; the league score
is not, and has not been since the win gate was dropped. The deprecated classic
modes use:

- **Decisive round** (capture or wipe): every winner scores **+1**, every
  loser scores **-1**. (Four-team free-for-all generalizes this zero-sum:
  the winning team scores +1 per losing team — see "Four-team mode".)
- **`scoring: "pot"`** (an archived-mode option; `"classic"` is the engine
  default and the published Season 2 choice) replaces the payout with an ante:
  **every team contributes one
  point and the winning team takes the whole pot**, the losing teams
  splitting the forfeit evenly. Two teams pay **+2 / -2**; four teams pay
  **+4** to the winner and **-1** to each of the three losers. Draws are
  unchanged.
- **Time-limit draw: -1 for both sides** (GameVersion 21). Running out the
  clock is never better than losing, so stalling has no upside for anyone.
- **Mutual-wipe draw** (both teams eliminated on the same tick): 0 for both
  sides — both at least fought to a decision.

Kills, team kills (kept as separate stats since GV45), hit damage and team
hit damage (split the same way since GV47), deaths, heart pickups, carry time,
and captures are still **recorded** in the episode results for leaderboards
and analysis — they just do not award points. This keeps the training
objective tied purely to winning.

## Controls

| Button | Action |
| --- | --- |
| D-pad | Move (locomotion only — never changes your aim) |
| A | Fire; while carrying a spray can, spray the paint cone |
| B | Rotate aim counter-clockwise (browser client: X or K) |
| Select | Rotate aim clockwise (browser client: Space or L) |
| C | Hold to charge a grenade throw, release to throw (browser client: C) |
| B + Select | **Drop chord** — hold both for `DropChordTicks` (10 ≈ 0.4 s) while carrying something to drop one item (browser client: **Q**). Requires `dropItem`; inert otherwise |
| Chat packet | Shout, max 10 chars (browser client: Enter to type) |

---

## Deprecated classic tuning defaults

These are the retained classic engine defaults, exposed in game config. They
are not the published `battle-royale-s2` values.

| Parameter | Proposed default | Notes |
| --- | --- | --- |
| Players | 16 (8v8) | All standard Coworld slots |
| Lives per player | 3 | Out of lives = out for the round |
| Hit points per life (`hitPoints`) | 3 | Shots to kill; reset to full on respawn |
| Respawn delay | ~3s | Time dead before respawning at a random endzone spot |
| Gun range | 1050px | Fixed on every map (the small map's field width); map-wide only on the smallest board |
| Aim jitter | ~0.6° sigma | Gaussian per released shot; 80% to hit a fully visible body at max range, ~99% at half |
| Fire windup | ~0.2s | Trigger pull to bullet release; aim locks at the pull |
| Fire cooldown | ~0.5s | Minimum time between shots |
| Carrier speed | ~70% | Movement penalty while holding the heart |
| Body bounce (`playerBouncePct`) | 40% | Restitution of player-player collisions; bodies are always solid |
| Aim turn rate (`aimTurnRate`) | 5 brads/tick | Rotation speed while B/Select is held (~7°/tick; full turn ~2.1s) |
| Vision cone (`visionConeDeg`) | ±60° | Fog-of-war forward vision half-angle; reaches 1.5× gun range (1575px stock), walls block |
| Vision bubble (`visionBubble`) | 90px | Omnidirectional close-range vision regardless of aim |
| Spray cone reach (`SprayPaintReach`) | 170px (5 squares) | Forward cone reach along the centerline; one square = one 34px cog body |
| Spray cone max width (`SprayPaintMaxWidth`) | 85px (2.5 squares) | Centerline cone width at max reach; widens linearly (half-angle atan(1/4) ≈ 14°) |
| Drawn plume span (`SprayPaintFxReach` / `SprayPaintFxMaxWidth`) | 136px / 68px | Art geometry the mist puffs are placed and sized against — deliberately shorter than the cone, because the puffs are drawn oversize and spill past it |
| Spray body radius (`SprayPaintBodyRadius`) | 17px (half a cog) | The victim is a disc, not a point: added to the cone's reach and to its half-width at every distance |
| Spray damage (`SprayPaintDamage`) | 3 hp | One touch per victim per burst; lethal to a bare cog, survivable by a shield carrier |
| Spray active window (`SprayPaintActiveTicks`) | 5 ticks | The sprayed cone stays on, tracking its owner's position and aim |
| Spray can reset (`SprayPaintResetTicks`) | 20 ticks | Repressurize after the cone shuts off (one burst per 25 ticks) |
| Spray can respawn | 30s | Taken pickups refill after this interval |
| Paint puff lifetime (`SprayPaintFxTicks`) | 4 ticks | Cosmetic fade of each per-tick cone snapshot |
| Heart auto-return | instant | A heart snaps back to its own pedestal the moment its carrier dies |
| Trench size (`TrenchSize`) | 56px | Side of the walkable center trench pit |
| Trench speed divisor (`TrenchSpeedDivisor`) | 5 | Climbing out (motion away from the pit center while inside) is 1/5 speed; entering and crossing are full speed |
| Trench fire slowdown (`TrenchFireSlowdown`) | 3 | Occupant gun cooldown multiplier; max-composed with shield/carrier |
| Trench miss chance (`TrenchMissPct`) | 70% | Incoming gun shots that fly over an occupant and carry on (same-trench shots exempt) |
| Pit count (`mapPits`) | -1 (unset) | Generated maps: exact total pits (0..64); odd counts anchor one at map center |
| Pit density (`mapPitDensity`) | 100 | Generated maps: percent multiplier on per-class dig chances; used when `mapPits` is unset |
| Puddle size (`PuddleSize`) | 64px | Nominal diameter of a paint-puddle splat (disc union; spill reaches at most 45px from its anchor) |
| Puddle count (`mapPuddles`) | 0 (none) | Generated maps: exact total puddles (0..64); odd counts anchor one at map center |
| Puddle damage chance (`puddleDamagePct`) | 20% | Chance of 1 damage per full second of continuous puddle occupancy (rolled at each completed second; shield soaks first) |
| Barrier pickups (`barrierPickups`) | 0 (none) | Folded cardboard barriers per team (0..2), staged between base and center; carrying one excludes carrying a grenade |
| Barrier strength (`BarrierHp`) | 10 hits | Gun shots a standing half-hex soaks before shredding; any cog driving into it flattens it instantly |
| Barrier radius (`BarrierRadius`) | 24px | Center-to-vertex of the placed half-hex; the flat side stands one apothem (~21px) down the placer's aim |
| Endzone shape (`mapEndzone`) | "" (drawn) | Generated 2-team maps: `column` (classic home strip), `disc` or `square` (compact zone around a base set back from the edge) |
| Endzone radius (`mapEndzoneRadius`) | 0 (drawn 110-140, size-scaled) | Compact endzones only: scoring radius / half-extent in px, 90..220. Needs `mapEndzone` |
| Base depth (`mapBaseDepth`) | 0 (drawn 520-620) | Compact endzones only: home anchor permille of the half-field, 400..800; SMALLER sets the base further from the edge. Needs `mapEndzone` |
| Time limit (`MaxTicks`) | 7200 ticks (5:00) | Scheduled end; the scoreless-draw ceiling without the barrage, ignored with it |
| Barrage max rate (`barrageMaxPerSec`) | 0 (off) | Endgame grenade rain ramps up to this many shells/s (cap 50); see "Grenade barrage". Needs a time limit |
| Barrage start rate (`barrageStartPerSec`) | 4/s | Launch rate at the latch, along the map edges |
| Barrage start (`barrageStartSec`) | 30s | Clock seconds remaining that latch the barrage (4:30 elapsed on the 5:00 clock); it only escalates once latched |
| Barrage saturation (`barrageSaturateSec`) | 30s | Seconds from latch to full saturation — whole board at max rate, landing exactly at 5:00 with the defaults |
| Shrink zone schedule (`zonePhases`) | [] (engine fallback) | Battle-royale closing rectangle: a list of `{z, waitTicks, shrinkTicks, dps}` phases; the published Season 2 variant supplies six phases |
| Shrink zone damage cadence | 24 ticks (1s) | Same per-second cadence as a paint puddle's roll, but deterministic — `dps` applies directly, no chance |
| Shrink zone phase cap | 8 | Hard ceiling on `zonePhases` entries |
| Map size | 1235×659 (default) | Varies by map class; the actual size and team count are stated in the `game teams <count> map <width>x<height>` init marker |

Engine tick rate is **24 ticks/sec** (inherited from Crewrift); all
second-based values above convert at that rate.

**Observation render scale:** the PLAYER observation stream (what bots parse)
is **1x map resolution** -- object coordinates and sprite pixel sizes are map
pixels directly, so an object's center IS its map point:
`map_x = object.x + sprite.width / 2` (same for y), no divisor. Only the
SPECTATOR/replay stream supersamples its zoomable board layers (2x,
`RenderScale`); the sim, the gameHash, and everything above (map size
1235x659, ranges, speeds) stay in map pixels. A 0.6.0-era build shipped the
wire at 3x -- any advice about dividing coordinates by 3 is stale. The
invisible `walkability map` sprite is 1235x659 in every stream.

**The episode parameters are stated outright at t=0.** The init snapshot
carries an invisible 1x1 marker labeled
`game teams <count> map <width>x<height>` — the number of teams sharing the
arena (2 or 4) and the exact map size in map pixels for THIS episode. Match
the prefix `game teams `; the tail splits on spaces into
`["<count>", "map", "<width>x<height>"]`. Generated maps come in several size
classes and team layouts, so a policy should read this marker (or fall back to
the walkability sprite's dimensions and counting `Room <color> Base` markers)
instead of assuming the classic 1235x659 two-team arena.

**So are the endzones.** The same init snapshot carries one invisible 1x1
marker per team labeled `endzone <color> <shape> <x0>,<y0> <x1>,<y1>`: the
team's home capture region stated outright. `<x0>,<y0>` / `<x1>,<y1>` are the
INCLUSIVE top-left and bottom-right corners of the zone's bounding box in map
pixels, and `<shape>` says how the zone fills that box. A **flagless** map
(the BR N-point spawn subsystem) has no capture region to state and emits
NONE of these markers at all — nor any flag/pedestal/heart sprite or object,
anywhere in the wire protocol.

| Shape | Where | Zone membership |
|-------|-------|-----------------|
| `column` | 2-team sides maps (classic) | the full box |
| `square` | 2-team compact-endzone maps | the full box |
| `disc` | 2-team compact-endzone maps | the circle inscribed in the box (center = box center, radius = half extent); the box corners are NOT in the zone |
| `corner` | 4-team corners maps | the L1 triangle hugging the map corner the box touches; the threshold edge is the diagonal joining the box's two corners adjacent to that map corner |
| `arm` | 4-team plus maps | the full box |

Match the prefix `endzone `; the tail splits on spaces into
`["<color>", "<shape>", "<x0>,<y0>", "<x1>,<y1>"]`, each corner splitting once
more on the comma. Validate `<shape>` against the five tokens above: the
SPECTATOR stream also emits `endzone <color> power <n>` glow overlays under
the same prefix (the player stream does not). Scoring rules are unchanged —
these markers restate the geometry the sim already plays; before they existed
a policy had to reconstruct it from the room markers and its own copy of the
zone formulas.

**So are the handicaps.** The same init snapshot carries one invisible 1x1
marker per team labeled
`handicap <color> <permille> hp <n> lives <n> spd <n> miss <n>`: the team's
authored handicap fraction in permille (0..1000, 0 = unhandicapped) plus the
ENGINE-resolved gameplay deltas it interpolates to — hit points per life,
lives, max speed as a percent of the base max speed (100 = full), and the
percent of point-blank shots dropped (0..50). Match the prefix `handicap `;
the tail splits on spaces into
`["<color>", "<permille>", "hp", "<n>", "lives", "<n>", "spd", "<n>",
"miss", "<n>"]` — the `hp`/`lives`/`spd`/`miss` tokens are fixed. The marker
is emitted for EVERY team, permille 0 included, so an absent marker means an
engine predating it, never "no handicap". The deltas are stated so a policy
can adapt to a weakened team (its own or an enemy's) without re-deriving the
interpolation formula.

**So are the perks.** The same init snapshot carries one invisible 1x1 marker
per team labeled `perks <color> <group> [<group> …] mods hp <n> aim <n>
nade <n> spd <n> luck <n> dmg <n>`: each `<group>` is the comma-joined perk
names one policy seat on that team carries — the vocabulary is `armor` (extra
hit point), `scope` (tighter gun aim), `grenade` (longer throws), `thruster`
(faster top speed), `luck` (a fraction of landed gun shots deal extra damage,
default double) — or the literal `-` for none. One group means the whole team
shares it; two or more deal to the team's distinct policies in join order
(CTF-Doubles; policy-name-pinned config groups emit in config order, without
names). After the fixed `mods` token come the ENGINE-RESOLVED magnitudes the
sim actually plays, so a policy never assumes the defaults: `hp` armor's
extra hit points, `aim`/`nade`/`spd`/`luck` the scope/grenade/thruster/luck
fractions in permille, `dmg` a lucky shot's hit points. Match the prefix
`perks `; the tail splits on spaces into `["<color>", "<group>", …]` up to
the `mods` literal, each group splitting again on commas. The marker is
emitted for EVERY team — an unperked team reads `perks <color> -` with no
mods tail — so an absent marker means an engine predating it, never
"no perks".

**So are the trenches.** The same init snapshot carries one invisible 1x1
marker per dug pit labeled `trench <x0>,<y0> <x1>,<y1>`: the pit's INCLUSIVE
bounding-box corners in map pixels, one marker per entry in the map's
trench list. Match the prefix `trench `; the tail splits on spaces into
`["<x0>,<y0>", "<x1>,<y1>"]`, each corner splitting once more on the comma.
Trenches are dug pits you can stand in for cover: climbing OUT (moving away
from the pit's center) costs 1/5 max speed, firing from inside triples your
cooldown, and an incoming gun shot has a 70% chance to be ducked while you're
inside — none of that changes line of sight. Before this marker existed,
trenches were invisible to a policy: the `walkability map` sprite is a
BINARY mask, and a trench floor reads identically to open floor on it — a
policy could stand in one, or walk through one under fire, with no signal it
was there at all. Trenches are a 2-team generated-map feature (never on
4-team maps, and the hand-authored default `arena` never digs any); a map
that rolled zero pits emits zero markers, not an empty-box one. The marker
pool holds up to 256 trenches per match — a wide empirical margin (an
explicit `mapPits` count locks 0..64, but the default DENSITY roll has no
fixed cap and can exceed that on a large generated map) — and a map that
somehow rolls past even that loses markers for the overflow trenches rather
than dropping the whole snapshot.

**So are the paint puddles.** The same init snapshot carries one invisible
1x1 marker per puddle labeled `puddle <x0>,<y0> <x1>,<y1>`: the blob's
INCLUSIVE bounding-box corners in map pixels, one marker per entry in the
map's puddle list, with exactly the trench marker's tail contract (split the
tail on spaces, each corner on the comma). Puddles are organic disc-union
splats, so the box is slightly LOOSE (conservative) geometry — treat the
whole box as hazardous rather than trying to trace the spill's exact edge. A puddle is a pure floor hazard:
standing inside rolls a `puddleDamagePct` (default 20%) chance of 1 damage
per full second of continuous occupancy, and it never slows movement or
fire, never blocks shots or vision. Like the trench floor, a puddle reads
identically to open floor on the binary `walkability map` sprite — this
marker is the only signal it is there. Puddles are a config-gated 2-team
generated-map feature (no map has any by default); a map without puddles
emits zero markers, not an empty-box one. The marker pool holds 64 — the
`mapPuddles` cap.

**So is the battle-royale shrink zone.** Unlike every marker above, this pair
is NOT stated once at t=0 — the zone moves, so both are re-stated EVERY
frame the mode is on. Two invisible 1x1 markers, `zone <x0>,<y0> <x1>,<y1>`
(the current rect) and `zonenext <x0>,<y0> <x1>,<y1>` (the rect it is
interpolating toward), same INCLUSIVE-corner tail contract as the trench and
puddle markers. Corners may legitimately sit outside the map's own
`[0, width) x [0, height)` range during an early (large) phase — compare your
own position against them directly rather than assuming they are on-board.
When `zonePhases` is empty, a game emits neither marker. The published Season 2
variant supplies a non-empty schedule; see "Season 2 battle-royale shrink
zone" above for the full rule.

**So is your own aim.** Every player frame carries an invisible 1x1 HUD
marker labeled `own aim <brads>`: your turret angle as of the rendered tick,
in brads (256 per turn, 0 = east, counter-clockwise). Match the prefix `own aim `
and parse the tail as an integer. Before this marker a policy had to dead-reckon its own aim
open-loop from its rotate inputs; the marker caps that drift at one frame
gap (integrate held rotation between frames, resync on each frame — see
docs/PROTOCOL.md).

**Your own kill/death count is on the wire too — but only for a human.** The
player stream carries `kd <kills>/<deaths>`, your own `Player.kills`/
`Player.deaths` (real attribution, already mixed into the deterministic
gameHash) restated as a HUD label, the same "/" convention the per-team
`team score` chip below uses. Unlike every other marker in this section,
`kd ` is **not** sent to a Sprites Off (0x87) viewer — the wire condition
every scripted/policy connection opts into — so a policy reads no such
label today and its byte stream is unaffected by this marker's existence;
only a human `/client/player` connection receives it. The per-player
scoreboard picker on the global/spectator stream (`score <name> <lives>
<kills>/<deaths> color <n>`, the clickable top-left pick-list) carries the
same two numbers per roster row, at every team count including BR's 16
teams / 32 seats — that suppression above 4 teams was a deliberate
legibility choice, now lifted so BR gets live per-player rows too.

**The WHOLE roster's lives/kills/deaths are on the player stream too, not
just your own.** A human `/client/player` connection never sees the
global/spectator stream above, so it cannot read that stream's `score `
rows — a second socket just to read a scoreboard would double the client's
heaviest stream, so instead every connected player's own stream restates
the whole roster: one marker per seat, `roster <team> <name> <lives>
<kills>/<deaths>`. `<name>` here is the anonymous per-team slot identity (`alpha`, `beta`, ...
— the same `IdentityNames` a shout or an `identity` badge uses, see
"Shouts" above), never the raw connection address `score`'s row carries —
a player frame is read by that policy's rivals, and this codebase's test
suite polices exactly that leak (`tests/test_identity_privacy.nim`). Same
human-only gating as `kd `.

**The result is stated once the game is over.** While `phase == GameOver`
(the interstitial frames between the final tick and the next lobby) a human
player stream carries one more invisible 1x1 marker, `winner <color>` — the
single-word team token, the same one your own `self <color> <side>` label
carries, so compare with plain equality — or `winner draw` when the game
concluded with no winner. It is absent for the whole Playing phase and gone
again at the next lobby; before it existed the wire named no winner at all
(the interstitial title is a rendered text sprite, chrome rather than
contract). Same human-only gating as `kd ` and `roster `.

The full wire
contract, including the CTF input-protocol extensions, is in
[`PROTOCOL.md`](PROTOCOL.md). Labels, sprite/object ids, and layers are
unchanged between streams, with one exception: while you are dead your own
body is the only
player sprite in frame, labeled `corpse <color> <side>` instead of
`player <color> <side>`, so a policy scanning for `player` labels never
mistakes a body for a live enemy.

**The capture object is a HEART in the fiction but `flag` in its LABEL.** Every
rule, banner, and end-card above calls it a heart, and that is the real name of
the thing. Its sprite labels, however, are `<color> flag`, `<color> flag planted`,
`<color> flag carried`, and `<color> flag carrier glow` — scan for **`flag`**, not
`heart`. The history: 0.7.0 renamed the object heart and renamed the labels to
match, then a later renderer restore brought the *labels* back to `flag` while
the fiction stayed heart. This document claimed `red heart` / `blue heart` until
2026-07-28; a policy written from that claim saw no objectives at all. The
generated `tests/label_manifest.txt` is the ground truth if this text and the
engine ever disagree again.

**Walking onto the planted heart grabs it.** The `<color> flag planted` sprite
object's center is the grab point, and the touch radius is **34px**
(`FlagPickupRange`, GV42) — sized to the 60px-wide gem. So a body center
anywhere on the pedestal's heart footprint takes it: navigate to the object
center and you do not need to arrive exactly on it. There is no grab button.
The DRAWN gem sits in the top half of a double-height canvas, standing on the
pedestal with its tip at the grab point — read the object's **center**, never
where the paint is.

This took three fixes, and the failure modes are worth knowing, because they are
the classic way a "visible objective" becomes unpickable:
- Before 2026-08-08 the big planted banner was bottom-anchored, putting its
  visual center ~28px above the grab point — outside the then-12px radius
  entirely. Policies that walked onto the heart they saw could *never* pick it
  up, at any precision.
- That fix sank the gem halfway into the pedestal to hold the contract; the
  stance was restored on 2026-08-08 by padding the canvas instead, which keeps
  the object centered on the grab point while the gem stands erect.
- The 12px radius itself survived both and remained a hidden precision demand:
  a fifth of the gem's width, so the visible target overstated the real one 5x.
  Agents and humans stood plainly on the heart and did not get it. GV42 keys
  the radius to the art, which is what the player aims at.

Grenades add the labels documented in the Grenades section, and the throw
button is input mask bit 128.

Spray cans add the labels documented in the Spray can section; their
pickup and carrier markers are fog-gated like other floor and overhead item
markers.

**The cone weapon is a SPRAY CAN (renamed from "spray can").** It is the same
weapon with the same numbers — only the art and the names changed, so this is a
pure vocabulary break for label-scanning policies. Rename in five places:

| Surface | Was | Now |
| --- | --- | --- |
| Pickup sprite label | `spray can` | `spray can` |
| Carrier marker label | `spray can carried` | `spray can carried` |
| Cone FX label | `spray can pulse` | `spray paint puff` |
| Own-HUD + badge weapon token | `weapon arc`, `identity … arc` | `weapon spray`, `identity … spray` |
| Held-weapon art on a carrier | `cog gun <color>` | `cog spray can <color>` |

Analysis events (`tools/extract_events.nim`) likewise carry `weapon: "spray"`
instead of `"spraypaint"`, and the broadcast item token is `spray`. The internal
`SprayPaint*` identifiers and `hasSprayPaint` field keep their names (as the
`flag`→`heart` rename kept `sim.flags`), so `gameHash` and replays are
unaffected — no GameVersion bump.

The analysis stream reports `gun_trigger` when A locks the aim and `shot` when
the paintball actually leaves after the windup. A correlated `shot_impact`
records where that paintball stopped, including misses. `grenade_throw` and
`grenade_impact` share the same correlation contract; active cone ticks emit
`spray_use`. These weapon events carry a deterministic `action_id`, native
`heading_brads` (0 east, 64 north), map-space `x`/`y`, and distance where
applicable. Damage-capable `shot_impact`, `grenade_impact`, and `spray_use`
events always carry `damages`, an array of `{slot, amount, hp, blocked}` rows;
a miss has an empty array. The stream also emits `item_pickup` with the item
name and player, and `shout` with the sanitized content and player. The older
flat `hit` and `damage` rows remain for compatibility.

**Since 0.7.5:** shouts (see the Shouts section) add the label
`<team> shout <name>: <text>`; chat packets, previously ignored, are now
applied as shouts and recorded in replays (GameVersion 3 — older replays are
rejected at load).

**Anonymous shouters:** that label's name field is now the shouter's anonymous
slot letter. It used to be the connecting player's name, which told everyone in
earshot whose policy was talking. The label's SHAPE did not change, so a policy
that reads the payload after `": "` needs no update. Replays are unaffected:
labels are rendered, never recorded, so the GameVersion is unchanged and an old
replay replays identically — under the new label.

**Player-sprite labels are stable across the HD art change:** the rotating
high-definition soldier is a pure visual upgrade — living players are still
`player <color> <side>` (yourself `self <color> <side>`, selected
`selected player <color> <side>`, a body `corpse <color> <side>`), where
`<side>` is the coarse `right`/`left` the aim falls into. The floating
`aim dot <color>` indicator has been **retired**; facing is read from the
sprite's swept gun and the vision cone, so a label-scanning policy sees the
same vocabulary it always has. **Nothing carries a player's aim angle any
more** — there is no absolute readback of where anyone (including a teammate) is
pointing, only what you infer from a body's rendered facing. The reference bot
scanned this retired label for months and got an empty answer every tick.

**The labels are enforced, not just documented.** `tests/label_manifest.txt` is
the generated list of every label the engine actually emits, and
`tests/test_label_contract.nim` fails if that set drifts or if a label the
reference policy scans for stops being emitted. When this prose and the engine
disagree, the manifest is right and this document is stale — that is exactly how
the `heart`/`flag` claim above went wrong. The label vocabulary itself lives in
`src/ctf/labels.nim`, shared by the engine and the reference policy.

**The hp bar is true hit points:** every living player carries an overhead
bar object labeled `hp <hp>/<maxHp>[ shield <s>]` — one green pip per
remaining base hit point out of that seat's OWN maximum (the `hitPoints`
config, handicap-interpolated, plus the armor perk: an armored seat reads
`hp 4/4` and draws a longer bar), with one blue pip per remaining
shield-layer hp appended while a shield holds. The denominator is per-seat
data, not a constant — parse it from the label (the reference policy scans
the `hp ` prefix) rather than restating a max of your own. The shield tail
is spelled apart from base hp on purpose: the layer depletes first and its
blue pips vanish with it, so `hp 3/3 shield 2` and `hp 3/3` are different
survivability, not different spellings of "5".

**Identity badges:** every living player carries a separate badge object
labeled `identity <color> <name>` (`alpha`..`theta` — see Teams & spawns).
Like the `hp <hp>/<maxHp>` bar, the badge is a distinct object centered on its
player's body: attach it by proximity. It is fog-gated with its player and disappears on
death.

**Veteran mark (GameVersion 60):** a living player at or above `AceLevel`
(the Season 2 glory level where killing them pays the `dAceTag` bounty —
see Season 2 glory scoring) carries an overhead rank-plume object labeled
`veteran mark <level>`. Like the `hp <hp>/<maxHp>` bar, it carries no player
identity of its own — it is a distinct object positioned over its player:
attach it by proximity, exactly like the hp bar. It is fog-gated with its
player (the same rule as the shield- and barrier-carried markers: it can
never name a level for an enemy the viewer could not otherwise see) and is
**absent** below `AceLevel` — absence is the "not a bounty yet" signal, the
same idiom the shield-carried marker uses for "no shield". Before this
label existed, `dAceTag` had no perception: a policy could see a
level-3+ enemy's inflated hp bar (the `LevelBonusHp` denominator) but had
no way to tell WHY it was inflated, or which enemy was worth the bounty.

---

## Implementation notes

This section is a build plan, not player-facing rules.

**Reused from Crewrift (the engine, ~60–70% of the code):**

- Continuous movement, fixed-point sub-pixel carry, wall-sliding collision
  against a per-pixel `walkMask`.
- Line-of-sight against a per-pixel `wallMask`. The old per-player 128×128
  camera is gone: each player now gets the **full map** with a per-viewer
  **fog-of-war** (recursive shadowcasting on an 8px visibility cell grid,
  intersected with the vision cone and bubble) that culls fogged entities from
  the observation and dims the unseen area with a fog overlay layer.
- The **Sprite v1** protocol (button-mask input + sprite/object observations),
  websocket server (`/player`, `/global`, `/replay`, `/reward`), replay
  recording/playback, JSON config loading, and reward streaming.

**Rewritten (the game layer, replacing social deduction):**

- `sim.nim`: replace `Crewmate`/`Imposter` roles with `Red`/`Blue` teams; replace
  `tryKill` (proximity grab) with **directional hitscan + LOS along the aim**; add
  **lives/respawn**, **heart pickup/carry/return**, **team win-check**, and a
  **Lobby → Playing → GameOver** phase machine (drop RoleReveal/Voting/VoteResult).
- Player struct: keep `x,y,velX,velY,carryX,carryY,alive,color,reward`; drop
  task/vent/vote fields; add `team`, `lives`, `respawnTimer`, `fireCooldown`,
  `aimBrads`, `carryingFlag`.
- `global.nim` observation building: team-colored player sprites, the heart
  sprites, a **carrier indicator**, the per-viewer **fog overlay** and
  fog-culled entity stream (there are deliberately **no heart arrows** — fog of
  war replaced all global tracking intel), a distinct **self marker**, and
  per-player **lives / fire-cooldown UI** on HUD layers.
- New **symmetric arena**: a new `.resources` map (CSS-like rects) plus an Aseprite
  image with walk/wall layers. Red/Blue spawn strips on the left/right edges,
  heart pedestal at center, obstacles mirrored across the vertical axis, home-edge
  capture zones at the leftmost/rightmost columns.
- New team-based `config.json` and `coworld_manifest_paintbot.json` (slots carry `team`
  instead of `role`; results schema reports team/kills/deaths/captures).
- A **baseline bot** (Crewrift's `notsus` equivalent) speaking Sprite v1.
- A **CTF grader** scoring episodes from wins.

**Resolved:** CTF needed team-based seating and win/loss ranking rather than
Crewrift's social-deduction scheme. This is no longer a per-game concern — both
the Ctf and Paintbot leagues run on the platform ladder service
(`commissioner_key=platform`), which owns seating and ranking. This repo ships
the game and baseline player only; it declares no commissioner runnable.
