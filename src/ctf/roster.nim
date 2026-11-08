## Roster machinery: slot identities and limits, join/auth resolution
## (resolvePlayerSlot), reward accounts, addPlayer/removePlayerAt,
## per-player records and playerResultsJson. Sole runtime consumer beyond
## the sim loop is server.nim. Stage 5 of
## docs/plans/2026-08-01-sim-split.md; re-exported by sim.nim.

import
  std/json,
  sim_types, sim_state, paint

proc perkSetForJoin*(sim: SimServer, team: Team, address: string): PerkSet =
  ## The perk group for a seat about to join `team` as `address`. NAMED
  ## groups (object config form) match the seat's policyName exactly — an
  ## unmatched policy gets nothing, so an operator can pin which policy
  ## receives which buffs. Unnamed groups (array form) deal to the team's
  ## distinct POLICIES in join order — a seat of an already-seated policy
  ## shares that policy's group, a new policy takes the next one (clamped to
  ## the last, so a lone group is simply team-wide). Pure function of
  ## config + the join AND leave stream
  ## (both replay), so playback resolves identically and already-seated
  ## players never reshuffle. Caveat under churn: ranks derive from the
  ## CURRENT roster, so if a policy's seats all leave, the next new policy
  ## inherits its rank — seats of one policy are only guaranteed a shared
  ## group while the team's policy lineup stays stable (always true for
  ## league rosters, which seat once at start).
  let groups = sim.config.perks[team]
  if groups.len == 0:
    return {}
  let pol = policyName(address)
  # A NAMED group pins its perks to exactly that policy; a policy no named
  # group claims gets nothing on an all-named team. (The parser guarantees a
  # team's groups are all-named or all-unnamed.)
  if groups[0].pol.len > 0:
    for group in groups:
      if group.pol == pol:
        return group.perks
    return {}
  var seen: seq[string]
  for p in sim.players:
    if p.team != team:
      continue
    let seatedPol = policyName(p.address)
    if seatedPol notin seen:
      seen.add seatedPol
  var index = seen.find(pol)
  if index < 0:
    index = seen.len
  groups[min(index, groups.high)].perks

proc teamForSlot*(sim: SimServer, order: int): Team =
  ## Returns the configured or default team for one slot: slots deal round
  ## the active teams in enum order (the classic red/blue alternation on
  ## 2-team maps).
  # read the fields in place: binding the slot copied its two string fields,
  # and slotIdentityIndex fans this out O(order) times per badge
  if order >= 0 and order < sim.config.slots.len and
      sim.config.slots[order].hasTeam:
    sim.config.slots[order].team
  else:
    Team(order mod sim.gameMap.teamCount())

const IdentityNames* = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
  ## Per-team player identities, assigned by slot order within the team.

proc slotIdentityIndex*(sim: SimServer, order: int): int =
  ## Returns one slot's identity index (into IdentityNames): its rank among
  ## same-team slots. Derived from the config, not stored, so it is stable
  ## across matches, reconnects, and replays. Wraps past theta in the
  ## degenerate case of more than IdentityNames.len slots on one team.
  let team = sim.teamForSlot(order)
  for i in 0 ..< order:
    if sim.teamForSlot(i) == team:
      inc result
  result = result mod IdentityNames.len

const IdentityNameUnknown* = "?"
  ## Stands in for a slot name that cannot be resolved; see `shoutIdentityName`.

proc shoutIdentityName*(sim: SimServer, shout: Shout): string =
  ## One shout author's anonymous slot name (an `IdentityNames` entry), for the
  ## speech-bubble label.
  ##
  ## Deliberately NOT `shout.address`. The address is the connecting policy's
  ## own name, and EVERY player in earshot reads shout labels off the wire — so
  ## labeling a bubble with the address hands rivals a free roster of who is in
  ## the match, and hands them our own name every time our bots talk to each
  ## other. The slot letter carries the same signal a listener can actually use
  ## ("which teammate called this") with no identity attached.
  ##
  ## Resolved at render time rather than stored on `Shout`, which is
  ## flatty-serialized into `SimServer` and therefore into replays: an extra
  ## field there would be a GameVersion break for a string that only ever
  ## exists in a rendered label.
  ##
  ## A bubble OUTLIVES its author — it displays for ShoutTicks, and the shouter
  ## can disconnect inside that window (`removePlayerAt` drops the row) — so an
  ## unresolvable author falls back to IdentityNameUnknown rather than dropping
  ## the bubble, which is observable state.
  ##
  ## SUBSTRATE NOTE (solo comms, 2026-09-05): the `player.address == shout.
  ## address` lookup this proc runs IS the load-bearing identity resolution a
  ## future alliance/pact system would reuse server-side to attribute a
  ## mutual ALLY declaration to its speaker (see the SUBSTRATE NOTE on
  ## `Shout.address`, sim_types.nim). That system must still resolve the
  ## SAME way this proc does — never expose the raw address to a rival's
  ## perception — it would just resolve to a pact record instead of a
  ## rendered slot letter.
  for player in sim.players:
    if player.address == shout.address:
      return IdentityNames[sim.slotIdentityIndex(player.joinOrder)]
  IdentityNameUnknown

proc playerSlotLimit*(config: GameConfig): int =
  ## Returns the number of slots players may occupy.
  if config.closedRoster: config.slots.len else: MaxPlayers

proc usedSkins*(config: GameConfig): set[Skin] =
  ## Returns the skins needed by slots that can join this game.
  if config.slots.len < config.playerSlotLimit():
    result.incl(DefaultSkin)
  for slot in config.slots:
    result.incl(slot.skin)

proc canAddPlayer*(sim: SimServer): bool =
  ## Returns whether the game has room for another player.
  sim.players.len < sim.config.playerSlotLimit()

proc playerLimitError(config: GameConfig): string =
  ## Returns a user-facing message for the current player cap.
  if config.closedRoster:
    let limit = config.playerSlotLimit()
    return "Configured roster is full (" & $limit &
      (if limit == 1: " player)." else: " players).")
  "can't do more than " & $MaxPlayers & " players."

proc slotConfig(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  ## Returns one slot config or an empty config for missing entries.
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  ## Returns true when a slot has identity restrictions.
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
): bool =
  ## Returns true when a player satisfies one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  ## Returns true when a token matches any configured slot.
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  ## Returns true when any slot has an auth token.
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig,
  slotIndex: int,
  address,
  token: string
) =
  ## Raises when a player does not satisfy one configured slot.
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(
      CtfError,
      "Player name does not match configured slot " & $slotIndex & "."
    )
  if slot.token.len > 0 and token != slot.token:
    raise newException(
      CtfError,
      "Player token does not match configured slot " & $slotIndex & "."
    )

proc configuredPlayerName*(config: GameConfig, requestedSlot: int, token: string): string =
  ## Returns the configured identity for a tokenized slot request.
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  requestedSlot: int,
  token: string
): bool =
  ## Returns whether a player websocket request can pass configured slot auth.
  if requestedSlot >= config.playerSlotLimit():
    return false
  if token.len > 0 and config.hasConfiguredTokens() and
      not config.hasConfiguredToken(token):
    return false
  if requestedSlot >= 0:
    return config.slotAuthMatches(requestedSlot, address, token)
  for i in 0 ..< config.slots.len:
    let slot = config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if matchedName or matchedToken:
      return config.slotAuthMatches(i, address, token)
  not config.closedRoster

proc slotOccupied(sim: SimServer, slotIndex: int): bool =
  ## Returns true when a player already owns a slot.
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc matchingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a matching configured slot for a player or -1.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let couldMatchName = slot.name.len > 0 and slot.name == address
    let couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc conflictingConfiguredSlot(
  sim: SimServer,
  address,
  token: string
): int =
  ## Returns a configured slot matched by name or token but not both.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if (matchedName or matchedToken) and
        not sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc namedConfiguredSlot(sim: SimServer, address: string): int =
  ## Returns an open configured slot with a matching name.
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    if slot.name.len > 0 and slot.name == address:
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  ## Returns the next open unrestricted or matching slot.
  let slotLimit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< slotLimit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  for i in 0 ..< sim.nextJoinOrder:
    if i >= slotLimit:
      break
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc advanceJoinOrder(sim: var SimServer) =
  ## Moves the auto-slot cursor to the next open slot.
  while sim.nextJoinOrder < MaxPlayers and
      sim.slotOccupied(sim.nextJoinOrder):
    inc sim.nextJoinOrder

proc resolvePlayerSlot*(
  sim: SimServer,
  address,
  token: string,
  requestedSlot: int
): int =
  ## Returns the slot a player should use or raises on rejection.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(CtfError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  let conflict = sim.conflictingConfiguredSlot(address, token)
  if conflict >= 0:
    raise newException(
      CtfError,
      "Player credentials do not match configured slot " & $conflict & "."
    )
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  ## Returns the LOWEST player slot not currently occupied. Admission is
  ## strictly slot-sequential (admitPendingJoins requires
  ## `join.slotIndex == sim.nextPlayerSlot()`), so this is the slot pending
  ## joins must fill next.
  ##
  ## NOT simply `sim.players.len`: a raw player count only equals the
  ## lowest open slot when disconnects always vacate the HIGHEST joinOrder.
  ## removePlayerAt deletes the player array entry but never renumbers the
  ## survivors' joinOrder, so when a LOW slot vacates while higher ones
  ## stay seated, the count keeps pointing past the real gap -- admission
  ## then demands a slot index nothing can ever supply, and every socket
  ## behind the gap (reconnecting or newly joining) stalls forever. This is
  ## the reset-dance / "8-of-16 stall": BR hard-stalls on it because BR's
  ## minPlayers equals its seat count, so any mid-stack vacancy blocks the
  ## whole field from ever starting.
  ##
  ## By pigeonhole, among slots 0..sim.players.len (inclusive) at least one
  ## must be free -- there are players.len+1 candidates and only
  ## players.len occupants -- so this loop always finds a slot without
  ## needing an explicit fallback.
  for i in 0 .. sim.players.len:
    if not sim.slotOccupied(i):
      return i

proc resolveTrustedPlayerSlot(
  sim: SimServer,
  address: string,
  requestedSlot: int
): int =
  ## Returns a trusted replay slot without requiring the original token.
  if requestedSlot >= MaxPlayers:
    raise newException(
      CtfError,
      "Player slot must be between 0 and 7."
    )
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(CtfError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(
        CtfError,
        "Player slot " & $requestedSlot & " is already occupied."
      )
    return requestedSlot
  result = sim.namedConfiguredSlot(address)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, "")
  if result < 0:
    raise newException(CtfError, "No available player slot.")

proc rewardAccountIndex(sim: SimServer, address: string): int =
  ## Returns the reward account index for an address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  ## Returns the reward account index, creating the account if needed.
  result = sim.rewardAccountIndex(address)
  if result < 0:
    sim.rewardAccounts.add RewardAccount(
      address: address,
      slotIndex: -1,
      reward: 0
    )
    result = sim.rewardAccounts.high

proc bindRewardAccountSlot(
  sim: var SimServer,
  accountIndex,
  slotIndex: int
) =
  ## Binds a reward account to the stable player slot for this match.
  if accountIndex < 0 or accountIndex >= sim.rewardAccounts.len:
    return
  for i in 0 ..< sim.rewardAccounts.len:
    if i != accountIndex and sim.rewardAccounts[i].slotIndex == slotIndex:
      sim.rewardAccounts[i].slotIndex = -1
  sim.rewardAccounts[accountIndex].slotIndex = slotIndex

proc rewardAccountIndexForSlot*(sim: SimServer, slotIndex: int): int =
  ## Returns the newest reward account index for a player slot.
  if slotIndex < 0 or sim.rewardAccounts.len == 0:
    return -1
  for i in countdown(sim.rewardAccounts.high, 0):
    if sim.rewardAccounts[i].slotIndex == slotIndex:
      return i
  -1

proc playerIndexForSlot*(sim: SimServer, slotIndex: int): int =
  ## Returns the live player index for a player slot.
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == slotIndex:
      return i
  -1

proc playerResultSlotCount(sim: SimServer): int =
  ## Returns the number of player slots represented in final results.
  result = sim.config.slots.len
  if sim.config.closedRoster:
    return
  for player in sim.players:
    result = max(result, player.joinOrder + 1)
  for account in sim.rewardAccounts:
    if account.slotIndex >= 0:
      result = max(result, account.slotIndex + 1)

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  ## Returns true when a player identity is already connected.
  for player in sim.players:
    if player.address == address:
      return true
  false

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live player and keeps index-keyed state aligned.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  for team in sim.teams():
    if sim.flags[team].carrier == playerIndex:
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
    elif sim.flags[team].carrier > playerIndex:
      dec sim.flags[team].carrier
  # GVNEXT(drop): `dropper` is a players[] INDEX, exactly like flags.carrier
  # above, so a mid-match leave shifts it the same way. Left unfixed, the
  # re-grab delay would attach to whichever seat slid into the departed
  # index — the removePlayer-sentinel family of bug. A drop whose OWN dropper
  # leaves becomes ownerless (-1): nobody is serving its delay, so anyone may
  # take it immediately, which is the open-steal default anyway.
  for item in sim.droppedItems.mitems:
    if item.dropper == playerIndex:
      item.dropper = -1
    elif item.dropper > playerIndex:
      dec item.dropper
  sim.players.delete(playerIndex)
  if playerIndex < sim.fovCaches.len:
    sim.fovCaches.delete(playerIndex)

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  ## Adds one player, optionally validating and using a requested slot.
  if not sim.canAddPlayer():
    raise newException(CtfError, sim.config.playerLimitError())
  if sim.playerAddressOccupied(address):
    raise newException(
      CtfError,
      "Player name is already connected."
    )
  let
    order =
      if trusted:
        sim.resolveTrustedPlayerSlot(address, requestedSlot)
      else:
        sim.resolvePlayerSlot(address, token, requestedSlot)
    nextSlot = sim.nextPlayerSlot()
  if not trusted and order != nextSlot:
    raise newException(
      CtfError,
      "Player slot " & $order & " cannot join before slot " &
        $nextSlot & "."
    )
  let
    slot = sim.config.slotConfig(order)
    team = sim.teamForSlot(order)
    color =
      if slot.hasColor:
        slot.color
      else:
        teamColor(team)
    accountIndex = sim.ensureRewardAccount(address)
    perks = sim.perkSetForJoin(team, address)
  let
    spawn = sim.spawnPosition(team, order div sim.gameMap.teamCount())
    groupOffset = sim.spawnGroupOffset()
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasTeam = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  inc sim.seatLifeGenerations[order]
  inc sim.seatConnectionGenerations[order]
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    aimBrads: sim.gameMap.spawnAimBrads(team, groupOffset),
    flipH: sim.gameMap.spawnFlipH(team, groupOffset),
    windupBrads: -1,
    windupStartTick: -1,
    arcAimBrads: -1,
    team: team,
    alive: true,
    # brMode seats ZERO spare lives — see seatLivesFor.
    lives: sim.config.seatLivesFor(team),
    lastDeathTick: -1,
    hp: sim.config.maxHpFor(team, perks),
    perks: perks,
    joinOrder: order,
    seat:
      # Which SEAT commands this cog. Cogs are dealt round-robin across the
      # teams, so cog index parity IS the team ordinal and therefore the
      # seat: 0/2/4/6 are RED-alpha..delta, 1/3/5/7 BLUE-alpha..delta.
      (if sim.config.numAgents > 0: order mod sim.config.numAgents else: 0),
    address: address,
    color: color,
    skin: slot.skin,
    lastShoutTick: -1,
    lastLobbyChatTick: -1,
    paintHitTick: -1,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.fovCaches.add PlayerFov(
    valid: false,
    visible: newSeq[bool](FovCellCount)
  )
  sim.advanceJoinOrder()
  sim.arrangeHomePositions()
  sim.players.high

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  ## Adds accumulated reward to a player and its address account.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  let index = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(index, sim.players[playerIndex].joinOrder)
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc rewardAccountForPlayer*(
  sim: var SimServer,
  playerIndex: int
): int =
  ## Returns the reward account index for a player, creating it if missing.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return -1
  let address = sim.players[playerIndex].address
  result = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(result, sim.players[playerIndex].joinOrder)

proc recordGameTeamAssigned*(
  sim: var SimServer,
  playerIndex: int
) =
  ## Records the team assignment for one player at game start.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].team = sim.players[playerIndex].team
  sim.rewardAccounts[index].hasTeam = true
  sim.rewardAccounts[index].won = false
  sim.rewardAccounts[index].abandoned = false
  inc sim.rewardAccounts[index].games[sim.players[playerIndex].team]

proc recordGameAbandon*(sim: var SimServer, playerIndex: int) =
  ## Marks a player as abandoned for the current game.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].abandoned = true

proc recordGameWin*(sim: var SimServer, playerIndex: int) =
  ## Increments the lifetime per-team win counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  sim.rewardAccounts[index].won = true
  inc sim.rewardAccounts[index].wins[sim.players[playerIndex].team]

proc noteLifeKill*(sim: var SimServer, playerIndex: int) =
  ## Analysis-only: one more kill in this cog's current life (`rambo`).
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  inc sim.players[playerIndex].killsThisLife
  sim.players[playerIndex].bestKillsInLife = max(
    sim.players[playerIndex].bestKillsInLife,
    sim.players[playerIndex].killsThisLife)

proc noteLifeHeal*(sim: var SimServer, playerIndex: int) =
  ## Analysis-only: one more med kit in this cog's current life (`medic`).
  inc sim.players[playerIndex].healsThisLife
  sim.players[playerIndex].bestHealsInLife = max(
    sim.players[playerIndex].bestHealsInLife,
    sim.players[playerIndex].healsThisLife)

proc recordKillCredit*(sim: var SimServer, killerIndex, victimIndex: int) =
  ## Credits one kill to its killer. GV45: an ENEMY kill increments `kills`
  ## (and feeds the kill-spree note); a TEAMMATE kill increments only
  ## `teamKills` — the two stats never mix. Weapon-agnostic: bullets, grenade
  ## blasts, and spray cones all land here.
  if killerIndex < 0 or killerIndex >= sim.players.len:
    return
  if victimIndex < 0 or victimIndex >= sim.players.len:
    return
  if killerIndex == victimIndex:
    return
  let index = sim.rewardAccountForPlayer(killerIndex)
  if sim.players[killerIndex].team == sim.players[victimIndex].team:
    if index >= 0:
      inc sim.rewardAccounts[index].teamKills
    inc sim.players[killerIndex].teamKills
  else:
    if index >= 0:
      inc sim.rewardAccounts[index].kills
    inc sim.players[killerIndex].kills
    sim.noteLifeKill(killerIndex)

proc recordHitDamage*(
  sim: var SimServer,
  attackerIndex, victimIndex, amount: int
) =
  ## Credits hp removed to the attacker's reward account, split by team the
  ## way recordKillCredit splits kills (GV47): damage to an ENEMY lands in
  ## `hitDamage`, damage to a TEAMMATE in `teamHitDamage`. Self-damage
  ## counts as neither, and environmental damage (puddles, barrage shells)
  ## never reaches here because it names no attacker.
  ##
  ## `amount` is the hp the hit removed BEFORE the shield layer soaked its
  ## share — the same figure the per-player `damageDealt` counters carry, so
  ## the account and the endscreen never disagree about what a hit was worth.
  ##
  ## Account-only: unlike kills there is no hashed per-player mirror, so a
  ## grenade thrown by a cog that has since left the game credits nobody
  ## (its live index is -1 by then), exactly as `damageDealt` already does.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return
  if victimIndex < 0 or victimIndex >= sim.players.len:
    return
  if attackerIndex == victimIndex or amount <= 0:
    return
  let index = sim.rewardAccountForPlayer(attackerIndex)
  if index < 0:
    return
  if sim.players[attackerIndex].team == sim.players[victimIndex].team:
    inc sim.rewardAccounts[index].teamHitDamage, amount
  else:
    inc sim.rewardAccounts[index].hitDamage, amount

proc recordDeath*(sim: var SimServer, playerIndex: int) =
  ## Increments the death counter for one player.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].deaths
  inc sim.players[playerIndex].deaths

proc matchKillsDeaths*(sim: SimServer, playerIndex: int): tuple[kills, deaths: int] =
  ## The MATCH-scoped kill/death tally for one seat: the address-keyed
  ## RewardAccount counters recordKillCredit/recordDeath maintain alongside the
  ## per-round Player.kills/Player.deaths above. The Player fields are
  ## zeroed every startGame — i.e. every ROUND, including a BR match's
  ## resetToLobby-then-rejoin cycle between rounds — while the
  ## RewardAccount for an address survives that: resetToLobby empties
  ## `players` but never touches `rewardAccounts`, and ensureRewardAccount
  ## looks an existing account up by address before creating a new one, so
  ## the same seat's running total carries forward round to round for as
  ## long as this address has stayed part of the match. This is what the
  ## own-kd HUD label and the roster scoreboard should read (see labels.nim
  ## LabelPrefixKd/LabelPrefixRoster) so a death — or the round boundary
  ## right after it — never wipes what a player watches accumulate.
  ##
  ## Read-only and non-mutating on purpose (unlike rewardAccountForPlayer):
  ## this runs from the per-tick HUD-build path for every seated viewer, so
  ## it must not perturb rewardAccounts bookkeeping just to render a label.
  ## Falls back to 0/0 on a lookup miss (should not happen: addPlayer always
  ## calls ensureRewardAccount for every seated player) rather than crash a
  ## frame build.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return (0, 0)
  let address = sim.players[playerIndex].address
  for account in sim.rewardAccounts:
    if account.address == address:
      return (account.kills, account.deaths)
  (0, 0)

proc recordCapture*(sim: var SimServer, playerIndex: int) =
  ## Increments the capture counter for one player.
  ##
  ## GLORY PORT (increment 2/3): the deed/xp mint and the "Uphill"/"Fast Break"
  ## pins (v12: endcard distinctions now, not ladder gates -- same pin
  ## sites) live at the CALL SITE (`checkWinCondition`, sim.nim),
  ## not here -- `roster.nim` only imports `sim_types`/`sim_state`, so it
  ## cannot see `awardDeed`/`addXp`/`teamAliveCount` (all in sim.nim, which
  ## imports `roster`, not the reverse). Splitting the mint out of this
  ## proc rather than restructuring the import graph for one call site.
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index >= 0:
    inc sim.rewardAccounts[index].captures
  inc sim.players[playerIndex].captures

proc recordAchievement*(sim: var SimServer, playerIndex: int, id: string) =
  ## Records one earned achievement on the player's address account,
  ## deduplicated: an id earned again in a later game of the same episode
  ## stays a single entry (the platform's badge model counts it once anyway).
  let index = sim.rewardAccountForPlayer(playerIndex)
  if index < 0:
    return
  if id notin sim.rewardAccounts[index].earnedAchievements:
    sim.rewardAccounts[index].earnedAchievements.add(id)

proc squadResultsJson*(sim: SimServer): string =
  ## The paintball results document: ONE entry per SEAT, never per cog.
  ##
  ## It must equal the manifest's `results_schema` key for key — that schema
  ## is `additionalProperties: false` and the certifier rejects any unknown
  ## field, so adding or removing a key here means editing
  ## coworld_manifest_paintbot.json in the same commit.
  ##
  ## `names` are the REAL policy names (spectator side); `team` carries the
  ## in-game aliases. Scores are the mean of the two halves, so
  ## scores[0] + scores[1] == 1.0 exactly for every legal outcome.
  let seats = max(1, sim.config.numAgents)
  var
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    teamList = newJArray()
    residentScore = newJArray()
    visitorScore = newJArray()
    hillTicksList = newJArray()
    residentHill = newJArray()
    visitorHill = newJArray()
    paintTiles = newJArray()
    tagsDealt = newJArray()
    teamTags = newJArray()
    tagsTaken = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  # Every game the episode actually played, plus the one in progress when a
  # deadline or a fault stopped it — the halves already banked keep their
  # scores either way.
  var games: seq[tuple[regime: Regime, ticks: array[Team, int]]]
  for i in 0 ..< sim.gameHill.len:
    games.add((
      (if i < sim.gameRegimes.len: sim.gameRegimes[i] else: regimeResident),
      sim.gameHill[i]))
  if sim.gameHill.len < max(1, sim.config.maxGames) and
      (sim.hillTicks[Red] > 0 or sim.hillTicks[Blue] > 0):
    games.add((sim.regime, sim.hillTicks))
  let faulted = sim.endReason == ReasonFault
  for seat in 0 ..< seats:
    let
      team = Team(seat mod max(1, sim.gameMap.teamCount()))
      other = if team == Red: Blue else: Red
    var
      resident = -1
      visitor = -1
      residentTicks = 0
      visitorTicks = 0
      totalTicks = 0
      halves = 0
      sum = 0
    for game in games:
      let permille = gameScorePermille(
        game.ticks[team] - game.ticks[other], sim.config.hillDecisiveTicks)
      totalTicks += game.ticks[team]
      ## Average the DEVIATION from 500, never the permille itself: integer
      ## division truncates toward zero, so (1000 + 999) div 2 = 999 while the
      ## opponent's (0 + 1) div 2 = 0 — a pair summing to 999 instead of 1000.
      ## Deviations are antisymmetric and `-x div n == -(x div n)` in Nim, so
      ## this keeps score[0] + score[1] EXACTLY 1.0 for every legal outcome.
      sum += permille - 500
      inc halves
      case game.regime
      of regimeResident:
        resident = permille
        residentTicks += game.ticks[team]
      of regimeVisitor:
        visitor = permille
        visitorTicks += game.ticks[team]
    # A `fault` episode is 0.5 / 0.5 — an infra fault is nobody's loss.
    let score =
      if faulted or halves == 0: 500
      else: 500 + sum div halves
    var
      tiles = 0
      dealt = 0
      friendly = 0
      taken = 0
    for i in 0 ..< sim.players.len:
      if sim.players[i].team != team:
        continue
      dealt += sim.players[i].kills
      friendly += sim.players[i].teamKills
      taken += sim.players[i].deaths
    tiles = sim.paintCount[team]
    names.add(%(
      if seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
        sim.seatNames[seat]
      else:
        "player-" & $seat))
    scores.add(%(score.float / 1000.0))
    win.add(%(not faulted and score > 500))
    teamList.add(%teamText(team))
    residentScore.add(%((if resident < 0: 500 else: resident).float / 1000.0))
    visitorScore.add(%((if visitor < 0: 500 else: visitor).float / 1000.0))
    hillTicksList.add(%totalTicks)
    residentHill.add(%residentTicks)
    visitorHill.add(%visitorTicks)
    paintTiles.add(%tiles)
    tagsDealt.add(%dealt)
    teamTags.add(%friendly)
    tagsTaken.add(%taken)
    llmTurns.add(%(if seat < sim.llmTurns.len: sim.llmTurns[seat] else: 0))
    fallbackTurns.add(
      %(if seat < sim.fallbackTurns.len: sim.fallbackTurns[seat] else: 0))
  var results = newJObject()
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["team"] = teamList
  results["residentScore"] = residentScore
  results["visitorScore"] = visitorScore
  results["hillTicks"] = hillTicksList
  results["residentHillTicks"] = residentHill
  results["visitorHillTicks"] = visitorHill
  results["paintTiles"] = paintTiles
  results["tagsDealt"] = tagsDealt
  results["teamTags"] = teamTags
  results["tagsTaken"] = tagsTaken
  results["llmTurns"] = llmTurns
  results["fallbackTurns"] = fallbackTurns
  results["reason"] = %(
    if sim.endReason.len > 0: sim.endReason else: ReasonComplete)
  results["endRule"] = %(
    if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime)
  results["games"] = %games.len
  results["finalTick"] = %sim.tickCount
  results["seed"] = %sim.config.seed
  $results

proc ctfPlayerResultsJson(sim: SimServer): string =
  ## Returns final player win states and LEAGUE SCORES (glory) as JSON:
  ## exactly one entry per SEAT, in seat order, when `numAgents` configures
  ## a seat count.
  ##
  ## SEAT ARITY: a seat can command more than one cog -- `cogSeat`'s own
  ## rule (sim.nim) is `joinOrder mod numAgents`, so seat k's squadmates are
  ## cogs k, k+numAgents, k+2*numAgents, ... (this project's own "k, k+16"
  ## duo-seat spacing, not adjacent indices). This proc used to emit one row
  ## per joined SLOT (== per cog), which equals `numAgents` only when every
  ## seat fields exactly one cog. In the historical hosted-certification
  ## incident, `cogsPerTeam` still defaulted to 4, so classic variants with
  ## `numAgents > 0` accidentally entered server.nim's squad mode and
  ## auto-filled trusted cogs past the real seats up toward `sim.totalCogs()`,
  ## capped by `MaxPlayers` (32) rather than by the seat count -- a 16-seat
  ## classic match's accidental squad-fill silently parked 16 EXTRA anonymous
  ## cogs (32 total, the `MaxPlayers` ceiling) in `sim.players`, and the
  ## pre-fix version of this proc reported one row per cog: the platform's
  ## hosted certification rejected it outright ("game returned 32 scores for
  ## 16 seats"). Every extra cog's stats now fold into its OWNING seat's single
  ## row instead of emitting a separate one, so `scores` always has exactly
  ## `numAgents` entries when a real squad config exists. Identity fields
  ## (name/team/win/score) come only from
  ## the seat's OWN slot -- summing across squadmates would inflate a win/
  ## loss or duplicate a team-scalar score -- while the analysis counters
  ## (kills/deaths/etc.) and achievements are summed/unioned across every
  ## cog the seat commands, so a real kill/capture/wipe by a squadmate still
  ## drives the seat's row (#327's scoring fix stays intact: this never
  ## touches the scoring VALUES, only which row a cog's stats land in).
  ## `numAgents == 0` (no seat concept configured -- synthetic/test rosters
  ## only) keeps the pre-fix behavior: one row per joined slot, unchanged.
  ##
  ## GLORY-AS-LEAGUE-SCORE: `scores[slot]` used to carry the RL training
  ## `reward` (WinReward/LossReward, +-1 scaled by team count) -- that
  ## signal still exists, untouched, on its own channel (`player.reward`,
  ## delivered every tick over the separate `buildRewardPacket` websocket
  ## message; NOT this results document). This field is repurposed to carry
  ## `sim.teamGlory[team]` (the GV48 GLORY ledger, glory.nim/sim.nim's
  ## `awardDeed`) instead: every slot reports its OWN team's already-tracked
  ## glory total, win, lose, or draw -- `playerWon` no longer gates this
  ## (it still gates `win[]` below, unchanged). Glory is per-duo already
  ## (`sim.teamGlory` has one slot per `Team`, 16 in the 8-duo BR game), so
  ## nothing is lost by reporting a non-winner's own total instead of
  ## collapsing it to 0. This can carry a NEGATIVE value (e.g. a
  ## friendly-fire-heavy duo) straight through to the platform's league
  ## ledger -- that is intentional here, not a bug: it is the literal
  ## contents of that duo's own ledger. The only remaining zero-gate is
  ## `sim.phase == GameOver` below (an aborted/incomplete episode still
  ## banks 0 for everyone -- nobody's ledger is final until conclusion).
  ## `scores` is the platform's hardcoded canonical league-score key (its
  ## results schema is `additionalProperties: false` with no field-selection
  ## knob), so glory rides the existing key rather than adding a new one.
  ## Because glory is a TEAM scalar, every cog on one seat's squad reports
  ## the identical value, so the SEAT ARITY fold above (which keeps only the
  ## primary slot's score and drops -- never sums -- a squadmate's) cannot
  ## double- or under-count it.
  ##
  ## teamGlory is read, never written, and was already mixed into gameHash
  ## by GV48 increment 3/3 (sim_state.nim) well before this proc runs at
  ## episode end -- this is pure reporting, touches no hashed state, and
  ## needs no GameVersion bump.
  ##
  ## Single-game assumption: every classic/CTF manifest variant pins
  ## maxGames=1 (only Paintball KOTH, a squadResultsJson-only path, runs
  ## multiple games per episode), so `sim.teamGlory` at match end already
  ## IS the whole episode's total -- there is nothing to accumulate across
  ## games here. A classic variant configured with maxGames > 1 in the
  ## future would need an accumulator (summed before each game's
  ## `resetGloryLedger`) the way a multi-game path would; today none exists.
  var
    resultSlots: seq[int] = @[]
    namesArr: seq[string] = @[]
    scoresArr: seq[int] = @[]
    winArr: seq[bool] = @[]
    teamArr: seq[string] = @[]
    killsArr: seq[int] = @[]
    teamKillsArr: seq[int] = @[]
    hitDamageArr: seq[int] = @[]
    teamHitDamageArr: seq[int] = @[]
    deathsArr: seq[int] = @[]
    capturesArr: seq[int] = @[]
    shotsFiredArr: seq[int] = @[]
    shotsHitArr: seq[int] = @[]
    achievementsArr: seq[seq[string]] = @[]
  for slotIndex in 0 ..< sim.playerResultSlotCount():
    resultSlots.add(slotIndex)
  for slotIndex in resultSlots:
    let
      playerIndex = sim.playerIndexForSlot(slotIndex)
      accountIndex =
        if playerIndex >= 0:
          sim.rewardAccountIndex(sim.players[playerIndex].address)
        else:
          sim.rewardAccountIndexForSlot(slotIndex)
      slotConfig = sim.config.slotConfig(slotIndex)
    var
      name =
        if slotConfig.name.len > 0:
          slotConfig.name
        else:
          "player-" & $slotIndex
      playerTeam = Red
      hasTeam = false
      playerWon = false
      kills = 0
      teamKills = 0
      hitDamage = 0
      teamHitDamage = 0
      deaths = 0
      captures = 0
      shotsFired = 0
      shotsHit = 0
      achievements: seq[string] = @[]
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      name = account.address
      playerTeam = account.team
      hasTeam = account.hasTeam
      playerWon = account.won
      kills = account.kills
      teamKills = account.teamKills
      hitDamage = account.hitDamage
      teamHitDamage = account.teamHitDamage
      deaths = account.deaths
      captures = account.captures
      for id in account.earnedAchievements:
        achievements.add(id)
    if playerIndex >= 0:
      let player = sim.players[playerIndex]
      name = player.address
      playerTeam = player.team
      hasTeam = true
      playerWon = not sim.isDraw and player.team == sim.winner
      # Accuracy counters live only on the player (analysis-only, never
      # mirrored into reward accounts): a slot whose player left reports 0.
      shotsFired = player.shotsFired
      shotsHit = player.shotsHit
    if not hasTeam and slotConfig.hasTeam:
      playerTeam = slotConfig.team
      hasTeam = true
    # GLORY: every slot banks its OWN team's ledger total once the match
    # has genuinely CONCLUDED. `playerWon` does NOT gate this (dropped
    # deliberately -- it still gates `win[]` below, unchanged): a losing or
    # drawing seat reports its own `sim.teamGlory[playerTeam]`, negative
    # values included, instead of a flattened 0. `sim.phase == GameOver` is
    # the one gate that remains, and it is load-bearing on its own: it is
    # true only once `finishGame` has actually run (it sets `sim.winner`,
    # `sim.isDraw`, and `sim.phase = GameOver` together, at the top of that
    # proc). A match that never reaches a decision -- e.g. the roster
    # empties mid-`Playing` with `maxGames <= 0`, which sends the sim
    # straight to `resetToLobby` (`sim.players = @[]`, `sim.phase = Lobby`)
    # without ever calling `finishGame` -- must still bank 0 for every
    # slot: the episode's ledger was never finalized, so none of it should
    # reach the platform's league score, independent of win/lose/draw.
    let glory =
      if sim.phase == GameOver and hasTeam:
        gloryReportInt(sim.teamGlory[playerTeam])
      else:
        0
    namesArr.add(name)
    scoresArr.add(glory)
    winArr.add(playerWon)
    teamArr.add(if hasTeam: teamText(playerTeam) else: "unknown")
    killsArr.add(kills)
    teamKillsArr.add(teamKills)
    hitDamageArr.add(hitDamage)
    teamHitDamageArr.add(teamHitDamage)
    deathsArr.add(deaths)
    capturesArr.add(captures)
    shotsFiredArr.add(shotsFired)
    shotsHitArr.add(shotsHit)
    achievementsArr.add(achievements)

  # --- collapse to one row per SEAT --------------------------------------
  # numAgents <= 0 means "no seat concept configured" (only synthetic/test
  # rosters do this): seatCount falls back to the per-slot row count above,
  # which makes the block below a no-op and keeps pre-fix behavior exactly.
  let seatCount =
    if sim.config.numAgents > 0: sim.config.numAgents
    else: namesArr.len
  if seatCount > 0 and namesArr.len != seatCount:
    if namesArr.len > seatCount:
      # Extra squad-filled cogs past the real seats: fold each one's stats
      # onto its owning seat (`joinOrder mod numAgents`, `cogSeat`'s own
      # rule) before the row itself is dropped. `scoresArr` (glory, a TEAM
      # scalar) is deliberately NOT folded here -- every cog on a seat's
      # squad already carries the identical value, so the primary slot's
      # own entry (kept below) is already correct; summing it would inflate
      # a winning seat's glory by its squad size.
      for i in seatCount ..< namesArr.len:
        let seat = i mod seatCount
        killsArr[seat] += killsArr[i]
        teamKillsArr[seat] += teamKillsArr[i]
        hitDamageArr[seat] += hitDamageArr[i]
        teamHitDamageArr[seat] += teamHitDamageArr[i]
        deathsArr[seat] += deathsArr[i]
        capturesArr[seat] += capturesArr[i]
        shotsFiredArr[seat] += shotsFiredArr[i]
        shotsHitArr[seat] += shotsHitArr[i]
        for id in achievementsArr[i]:
          if id notin achievementsArr[seat]:
            achievementsArr[seat].add(id)
    else:
      # Fewer joined slots than configured seats (a no-show, or a config
      # that never populated `slots`): pad so the invariant -- exactly
      # `numAgents` rows -- holds either direction.
      for i in namesArr.len ..< seatCount:
        namesArr.add("player-" & $i)
        scoresArr.add(0)
        winArr.add(false)
        teamArr.add("unknown")
        killsArr.add(0)
        teamKillsArr.add(0)
        hitDamageArr.add(0)
        teamHitDamageArr.add(0)
        deathsArr.add(0)
        capturesArr.add(0)
        shotsFiredArr.add(0)
        shotsHitArr.add(0)
        achievementsArr.add(@[])
    namesArr.setLen(seatCount)
    scoresArr.setLen(seatCount)
    winArr.setLen(seatCount)
    teamArr.setLen(seatCount)
    killsArr.setLen(seatCount)
    teamKillsArr.setLen(seatCount)
    hitDamageArr.setLen(seatCount)
    teamHitDamageArr.setLen(seatCount)
    deathsArr.setLen(seatCount)
    capturesArr.setLen(seatCount)
    shotsFiredArr.setLen(seatCount)
    shotsHitArr.setLen(seatCount)
    achievementsArr.setLen(seatCount)

  var
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    teamList = newJArray()
    killsList = newJArray()
    teamKillsList = newJArray()
    hitDamageList = newJArray()
    teamHitDamageList = newJArray()
    deathsList = newJArray()
    capturesList = newJArray()
    shotsFiredList = newJArray()
    shotsHitList = newJArray()
    achievementsList = newJArray()
    results = newJObject()
  for i in 0 ..< namesArr.len:
    names.add(%namesArr[i])
    scores.add(%scoresArr[i])
    win.add(%winArr[i])
    teamList.add(%teamArr[i])
    killsList.add(%killsArr[i])
    teamKillsList.add(%teamKillsArr[i])
    hitDamageList.add(%hitDamageArr[i])
    teamHitDamageList.add(%teamHitDamageArr[i])
    deathsList.add(%deathsArr[i])
    capturesList.add(%capturesArr[i])
    shotsFiredList.add(%shotsFiredArr[i])
    shotsHitList.add(%shotsHitArr[i])
    var achievements = newJArray()
    for id in achievementsArr[i]:
      achievements.add(%id)
    achievementsList.add(achievements)
  results["names"] = names
  results["scores"] = scores
  results["win"] = win
  results["team"] = teamList
  results["kills"] = killsList
  results["teamKills"] = teamKillsList
  results["hitDamage"] = hitDamageList
  results["teamHitDamage"] = teamHitDamageList
  results["deaths"] = deathsList
  results["captures"] = capturesList
  results["achievements"] = achievementsList
  # shotsFired/shotsHit stay OUT of the results payload: the platform's
  # episode-results schema is closed (additionalProperties: false) and the
  # certifier rejects unknown fields, blocking every canonical upload. The
  # counters remain on the players for replay-side analysis; re-add here
  # only after the platform schema learns the fields.
  $results

proc playerResultsJson*(sim: SimServer): string =
  ## The episode results document. A paintball game (loadout ==
  ## LoadoutPaintball) reports one entry per SEAT through squadResultsJson;
  ## every classic game (the default LoadoutCtf) plays the starter's rules
  ## through ctfPlayerResultsJson.
  ##
  ## THIS MUST NOT KEY ON numAgents: every flagship classic variant (2v2,
  ## 4ffa, 4ffa8, 1v1, ctf-default, ctf-1v1) sets num_agents to a nonzero
  ## seat count for an unrelated commissioner requirement (squad/seat
  ## broadcast plumbing — see the many OTHER numAgents>0 gates in
  ## server.nim/broadcast.nim, which are legitimately about seat topology,
  ## not scoring). numAgents>0 is true for those games too, so keying the
  ## scoring schema on it silently routes every classic match into the
  ## hill-only squad scorer, whose halves never populate without hill=true —
  ## every seat falls through to the literal 500/500 fault tie, discarding
  ## real kills/captures. loadout is the only field that actually means
  ## "paintball vs classic".
  if sim.config.loadout == LoadoutPaintball:
    sim.squadResultsJson()
  else:
    sim.ctfPlayerResultsJson()
