## The sim: the exact resolution order of the design note, the deeds, the
## score, the run-end evaluation, the per-tick `gameHash`, and the seat's
## text-native observation (the ASCII map renderer, the message queue and the
## status-line renderer).
##
## Imports and re-exports the sim modules, as the starter's `sim.nim` does,
## so `import nethack/sim` sees everything.
##
## ALL SIM ARITHMETIC IS INTEGER. There is no floating point in this file, in
## dungeon.nim, mobs.nim, items.nim, minihack.nim, driver.nim or
## baselines.nim, and tests/test_nethack_sim.nim greps for it. That is what
## makes the native <-> wasm hash chain exact by construction.

import std/[json, strutils]

import sim_types, sim_config, dungeon, mobs, items, minihack

export sim_types, sim_config, dungeon, mobs, items, minihack

type
  SimServer* = object
    config*: GameConfig
    tickCount*: int
    turnsPlayed*: int
    phase*: Phase
    lobbyTicks*: int

    cog*: Cog
    levels*: seq[Level]
    visible*: seq[bool]
    potionKnown*: array[PotionNames.len, bool]
    potionAppearance*: array[PotionNames.len, int]

    queue*: seq[Primitive]
    messages*: seq[string]
    events*: seq[JsonNode]

    gameHashValue*: uint64

    ended*: bool
    endRule*: EndRule
    endReason*: EndReason
    causeOfDeath*: CauseOfDeath
    killer*: string
    stopDetail*: string

    depthReached*: int
    deeds*: array[3, bool]
    monstersKilled*, itemsPicked*, timesAte*, potionsQuaffed*: int
    oracleConsults*, doorsKicked*, trapsTriggered*: int
    goldPickedUp*, primitivesExecuted*: int
    actionsDropped*, macrosUnreachable*, repliesRepaired*: int
    levelTurns*, levelTicks*, levelKills*, levelGold*: seq[int]

    playerName*: string
    policyKind*: string
    fallbackTurns*, llmTurns*: int
    deadSeat*: bool
    registered*: bool

    notes*: string
    lastSay*: string
    lastExecuted*: seq[string]
    lastTruncated*: bool
    lastDropped*, lastUnreachable*: int
    executedVerb*: string

proc variantName*(config: GameConfig): string =
  if config.levelLadder.len > 0: "minihack" else: "descend"

proc levelIndex*(sim: SimServer): int = sim.cog.depth - 1

proc emit*(sim: var SimServer, kind: string, fields: JsonNode) =
  ## One derived broadcast event. Never enters `gameHash`, so nothing here
  ## can affect determinism.
  var node = %*{"t": sim.tickCount, "k": kind}
  if not fields.isNil and fields.kind == JObject:
    for key, value in fields:
      node[key] = value
  sim.events.add(node)

proc say*(sim: var SimServer, message: string) =
  ## One NetHack message line, rune-truncated at its cap.
  if message.len == 0:
    return
  sim.messages.add(message.truncateRunes(MaxMessageRunes))

proc ensureLevel*(sim: var SimServer, depth: int) =
  ## Levels are generated LAZILY on first arrival and never regenerated: a
  ## revisited level is restored exactly as it was left.
  while sim.levels.len < depth:
    sim.levels.add(Level())
  if sim.levels[depth - 1].generated:
    return
  if sim.config.levelLadder.len >= depth:
    sim.levels[depth - 1] =
      generateMinihackLevel(sim.config.levelLadder[depth - 1], sim.config.seed, depth)
  else:
    sim.levels[depth - 1] = generateLevel(
      sim.config.seed, depth,
      oracleLevel = sim.config.levelLadder.len == 0 and depth == 5 and
        sim.config.dungeonLevels >= 5)

proc recomputeVisibility*(sim: var SimServer) =
  let li = sim.levelIndex
  sim.visible = sim.levels[li].visibleSet(sim.cog.x, sim.cog.y)
  sim.levels[li].mergeMemory(sim.visible, sim.tickCount)

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.phase = Lobby
  result.cog = initCog(config.startHp, config.startNutrition)
  result.potionAppearance = potionAppearanceTable(config.seed)
  result.levels = @[]
  result.depthReached = 1
  result.endReason = reasonComplete
  result.endRule = erNone
  result.causeOfDeath = codNone
  result.playerName = (if config.players.len > 0: config.players[0].name else: "Alpha")
  result.policyKind = "scripted"
  result.levelTurns = newSeq[int](config.dungeonLevels)
  result.levelTicks = newSeq[int](config.dungeonLevels)
  result.levelKills = newSeq[int](config.dungeonLevels)
  result.levelGold = newSeq[int](config.dungeonLevels)
  result.ensureLevel(1)
  result.cog.x = result.levels[0].upX
  result.cog.y = result.levels[0].upY
  result.recomputeVisibility()

# ---------------------------------------------------------------------------
#  Hash
# ---------------------------------------------------------------------------

proc statusBits*(cog: Cog): int =
  (if cog.confused > 0: 1 else: 0) or
  (if cog.paralysed > 0: 2 else: 0) or
  (if cog.stuck > 0: 4 else: 0) or
  (if cog.trapped > 0: 8 else: 0)

proc deedMask*(sim: SimServer): int =
  (if sim.deeds[0]: 1 else: 0) or
  (if sim.deeds[1]: 2 else: 0) or
  (if sim.deeds[2]: 4 else: 0)

proc mixInto(hash: var uint64, value: int) =
  hash = splitmix64(hash xor cast[uint64](int64(value)))

proc gameHash*(sim: SimServer): uint64 = sim.gameHashValue

proc mixTick*(sim: var SimServer) =
  ## The per-tick integrity link, mixed in the fixed order of the design
  ## note. One divergent bit is caught at the tick it happens.
  var hash = sim.gameHashValue
  hash.mixInto(sim.cog.depth)
  hash.mixInto(sim.tickCount)
  hash.mixInto(sim.cog.x)
  hash.mixInto(sim.cog.y)
  hash.mixInto(sim.cog.hp)
  hash.mixInto(sim.cog.maxHp)
  hash.mixInto(sim.cog.ac)
  hash.mixInto(sim.cog.xlevel)
  hash.mixInto(sim.cog.xpPoints)
  hash.mixInto(sim.cog.gold)
  hash.mixInto(sim.cog.nutrition)
  hash.mixInto(sim.cog.statusBits())
  let li = sim.levelIndex
  for i in 0 ..< sim.levels[li].cells.len:
    let cell = sim.levels[li].cells[i]
    hash.mixInto(ord(cell.terrain))
    hash.mixInto(cell.trapKind)
    hash.mixInto(if cell.trapFound: 1 else: 0)
    hash.mixInto(ord(cell.item.kind) * 4096 + cell.item.id)
  for monster in sim.levels[li].monsters:
    hash.mixInto(ord(monster.species))
    hash.mixInto(monster.x)
    hash.mixInto(monster.y)
    hash.mixInto(if monster.alive: monster.hp else: -1)
  for letter in 0 ..< MaxInventory:
    let item = sim.cog.inv[letter]
    hash.mixInto(ord(item.kind))
    hash.mixInto(item.id)
    hash.mixInto(item.count)
  hash.mixInto((if sim.cog.wielded >= 0: sim.cog.wielded + 1 else: 0) * 64 +
    (if sim.cog.worn >= 0: sim.cog.worn + 1 else: 0))
  hash.mixInto(sim.depthReached)
  hash.mixInto(sim.deedMask())
  hash.mixInto(sim.monstersKilled)
  hash.mixInto(sim.timesAte)
  hash.mixInto(sim.tickCount)
  sim.gameHashValue = hash

# ---------------------------------------------------------------------------
#  Score, deeds and the run end
# ---------------------------------------------------------------------------

proc score*(sim: SimServer): int =
  ## Higher is better, and every term only ever ADDS. Depth is strictly
  ## dominant: the largest possible total of the three other terms is
  ## 85 000 < 100 000, so one more dungeon level always beats any amount of
  ## gold, experience and deeds. Death subtracts nothing.
  var deedCount = 0
  for earned in sim.deeds:
    if earned: inc deedCount
  100_000 * (sim.depthReached - 1) +
    10 * min(sim.cog.gold, 2_000) +
    50 * min(sim.cog.xpPoints, 1_000) +
    5_000 * deedCount

proc deedCount*(sim: SimServer): int =
  for earned in sim.deeds:
    if earned: inc result

proc awardDeed(sim: var SimServer, deed: Deed) =
  let index = ord(deed)
  if sim.deeds[index]:
    return
  sim.deeds[index] = true
  sim.emit("deed", %*{"name": $deed})
  sim.say("You feel a deed done: " & $deed & ".")

proc checkDeeds(sim: var SimServer) =
  if sim.timesAte >= 1: sim.awardDeed(deedFed)
  if sim.cog.gold >= 500: sim.awardDeed(deedHoard)

proc endRun*(sim: var SimServer, rule: EndRule, cause: CauseOfDeath,
             killer: string) =
  if sim.ended:
    return
  sim.ended = true
  sim.phase = GameOver
  sim.endRule = rule
  sim.causeOfDeath = cause
  sim.killer = killer
  if rule == erWallClock:
    sim.endReason = reasonDeadline
  elif rule == erFault:
    sim.endReason = reasonFault
  else:
    sim.endReason = reasonComplete
  case rule
  of erDeath:
    sim.emit("death", %*{"cause": $cause, "killer": killer,
                         "depth": sim.cog.depth, "tick": sim.tickCount})
  of erBottom:
    sim.emit("bottom", %*{"depth": sim.cog.depth})
  of erEscaped:
    sim.emit("escaped", %*{"depth": sim.cog.depth})
  else:
    discard
  sim.emit("end", %*{"reason": $sim.endReason, "endRule": $rule,
                     "depth": sim.depthReached, "score": sim.score()})

proc settleFault*(sim: var SimServer, detail: string) =
  ## An unexpected exception in the sim or in the server loop, CAUGHT: the
  ## episode is settled from the last completed tick, `endRule` is `fault`,
  ## `stopDetail` names it (rune-truncated at MaxStopDetailRunes), and the
  ## caller still writes every artifact and exits 0.
  if sim.ended:
    return
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  sim.endRun(erFault, codNone, "")

# ---------------------------------------------------------------------------
#  Experience
# ---------------------------------------------------------------------------

const XpThresholds = [20, 40, 80, 160, 320, 640, 1280]

proc checkExperience(sim: var SimServer) =
  var level = 1
  for threshold in XpThresholds:
    if sim.cog.xpPoints >= threshold:
      inc level
  while sim.cog.xlevel < level:
    inc sim.cog.xlevel
    let gain = 1 + hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount,
                           1500 + sim.cog.xlevel, 8)
    sim.cog.maxHp += gain
    sim.cog.hp += gain
    sim.say("Welcome to experience level " & $sim.cog.xlevel & ".")
    sim.emit("levelup", %*{"xlevel": sim.cog.xlevel, "maxhp": sim.cog.maxHp})

# ---------------------------------------------------------------------------
#  Combat
# ---------------------------------------------------------------------------

proc cogAttackBonus(sim: SimServer): int =
  sim.cog.xlevel + sim.cog.weaponHitBonus() -
    (if sim.cog.hunger in {hWeak, hFainting}: 2 else: 0)

proc killMonster(sim: var SimServer, monsterIndex: int) =
  let li = sim.levelIndex
  let species = sim.levels[li].monsters[monsterIndex].species
  sim.levels[li].monsters[monsterIndex].alive = false
  inc sim.monstersKilled
  if li < sim.levelKills.len:
    inc sim.levelKills[li]
  sim.cog.xpPoints += SpeciesXp[species]
  sim.say("You kill the " & SpeciesName[species] & "!")
  sim.emit("kill", %*{"monster": SpeciesName[species],
                      "x": sim.levels[li].monsters[monsterIndex].x,
                      "y": sim.levels[li].monsters[monsterIndex].y})
  if species == spGnome:
    let drop = 10 + hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount,
                            1601, 50)
    sim.cog.gold += drop
    sim.say("The gnome drops " & $drop & " gold pieces.")
  sim.checkExperience()

proc cogAttack(sim: var SimServer, monsterIndex: int) =
  let li = sim.levelIndex
  let species = sim.levels[li].monsters[monsterIndex].species
  if species == spOracle:
    sim.say("You swap places with nobody.")
    return
  let landed = hits(sim.config.seed, sim.cog.depth, sim.tickCount,
                    1700 + monsterIndex, sim.cogAttackBonus(),
                    SpeciesAc[species])
  if species == spFloatingEye:
    ## The single most famous piece of NetHack lore that kills new players,
    ## preserved exactly: hit OR miss, the gaze freezes the cog for 12 ticks.
    sim.cog.paralysed = 12
    sim.say("You are frozen by the floating eye's gaze!")
  if landed:
    let damage = damageRoll(sim.config.seed, sim.cog.depth, sim.tickCount,
                            1800 + monsterIndex, sim.cog.weaponDie())
    sim.levels[li].monsters[monsterIndex].hp -= damage
    if sim.levels[li].monsters[monsterIndex].hp <= 0:
      sim.killMonster(monsterIndex)
    else:
      sim.say("You hit the " & SpeciesName[species] & ".")
  else:
    sim.say("You miss the " & SpeciesName[species] & ".")

proc hurtCog(sim: var SimServer, damage: int, by: string) =
  sim.cog.hp -= damage
  sim.emit("hurt", %*{"by": by, "dmg": damage, "hp": max(0, sim.cog.hp),
                      "maxhp": sim.cog.maxHp})

# ---------------------------------------------------------------------------
#  Primitives
# ---------------------------------------------------------------------------

proc compassOctant(fromX, fromY, toX, toY: int): string =
  let
    dx = toX - fromX
    dy = toY - fromY
  if dx == 0 and dy == 0:
    return "right here"
  var name = ""
  if dy < -abs(dx) div 2: name.add("north")
  elif dy > abs(dx) div 2: name.add("south")
  if dx > abs(dy) div 2:
    name.add(if name.len > 0: "-east" else: "east")
  elif dx < -abs(dy) div 2:
    name.add(if name.len > 0: "-west" else: "west")
  if name.len == 0: "east" else: name

proc arriveOnLevel(sim: var SimServer, depth, x, y: int) =
  sim.cog.depth = depth
  sim.cog.x = x
  sim.cog.y = y
  if depth > sim.depthReached:
    sim.depthReached = depth
  sim.recomputeVisibility()

proc descend(sim: var SimServer) =
  if sim.cog.depth >= sim.config.dungeonLevels:
    sim.say("You have reached the bottom of the dungeon.")
    sim.endRun(erBottom, codNone, "")
    return
  let fromDepth = sim.cog.depth
  sim.ensureLevel(fromDepth + 1)
  sim.arriveOnLevel(fromDepth + 1, sim.levels[fromDepth].upX, sim.levels[fromDepth].upY)
  sim.say("You descend the stairs. Dlvl " & $sim.cog.depth & ".")
  sim.emit("descend", %*{"from": fromDepth, "to": sim.cog.depth})

proc ascend(sim: var SimServer) =
  if sim.cog.depth <= 1:
    sim.say("You climb out of the dungeon.")
    sim.endRun(erEscaped, codNone, "")
    return
  let fromDepth = sim.cog.depth
  sim.arriveOnLevel(fromDepth - 1, sim.levels[fromDepth - 2].downX,
                    sim.levels[fromDepth - 2].downY)
  sim.say("You climb the stairs. Dlvl " & $sim.cog.depth & ".")
  sim.emit("ascend", %*{"from": fromDepth, "to": sim.cog.depth})

proc lichenHolds(sim: SimServer, x, y: int): bool =
  ## True when a live lichen is on or 8-adjacent to (x, y). This is the cell
  ## test the `stuck` rule measures a move against: the cog stays stuck while
  ## it keeps contact with the lichen that grabbed it.
  let li = sim.levelIndex
  for monster in sim.levels[li].monsters:
    if monster.alive and monster.species == spLichen and
        chebyshev(monster.x, monster.y, x, y) <= 1:
      return true
  false

proc applyMove(sim: var SimServer, dirIn: int) =
  var dir = dirIn
  if sim.cog.confused > 0:
    dir = hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount, 1901, 8)
  let li = sim.levelIndex
  let
    nx = sim.cog.x + DirDx[dir]
    ny = sim.cog.y + DirDy[dir]
  if not inside(nx, ny):
    sim.say("You cannot move there.")
    return
  let monster = sim.levels[li].monsterAt(nx, ny)
  if monster >= 0:
    sim.cogAttack(monster)
    return
  if sim.cog.stuck > 0 and sim.lichenHolds(sim.cog.x, sim.cog.y) and
      not sim.lichenHolds(nx, ny):
    ## A lichen holds on: the cog may act, and may still shuffle around the
    ## lichen, but any move AWAY from it fails. A move that keeps contact —
    ## and a move made after the lichen is dead — is not blocked.
    sim.say("You are stuck to the lichen.")
    return
  case sim.levels[li].terrainAt(nx, ny)
  of tDoorClosed:
    sim.levels[li].setTerrain(nx, ny, tDoorway)
    sim.say("The door opens.")
    sim.emit("door", %*{"action": "open", "x": nx, "y": ny})
  of tDoorLocked:
    sim.say("This door is locked.")
    sim.emit("door", %*{"action": "locked", "x": nx, "y": ny})
  of tLava:
    sim.cog.x = nx
    sim.cog.y = ny
    sim.say("You burn to a crisp.")
    sim.endRun(erDeath, codBurned, "lava")
  else:
    if passable(sim.levels[li].terrainAt(nx, ny)):
      sim.cog.x = nx
      sim.cog.y = ny
    else:
      sim.say("You cannot move there.")

proc applySearch(sim: var SimServer) =
  let li = sim.levelIndex
  for dir in 0 ..< 8:
    let
      nx = sim.cog.x + DirDx[dir]
      ny = sim.cog.y + DirDy[dir]
    if not inside(nx, ny):
      continue
    let cell = sim.levels[li].cells[idx(nx, ny)]
    let hidden = (cell.trapKind >= 0 and not cell.trapFound) or
      cell.terrain == tSecretDoor
    if not hidden:
      continue
    inc sim.levels[li].cells[idx(nx, ny)].searchCount
    if sim.levels[li].cells[idx(nx, ny)].searchCount >=
        sim.config.searchesToReveal:
      if sim.levels[li].cells[idx(nx, ny)].terrain == tSecretDoor:
        sim.levels[li].setTerrain(nx, ny, tDoorClosed)
        sim.say("You find a hidden door.")
      else:
        sim.levels[li].cells[idx(nx, ny)].trapFound = true
        sim.say("You find a " &
          TrapNames[sim.levels[li].cells[idx(nx, ny)].trapKind mod 4] & ".")

proc applyPickup(sim: var SimServer) =
  let li = sim.levelIndex
  let cell = idx(sim.cog.x, sim.cog.y)
  let item = sim.levels[li].cells[cell].item
  if item.kind == ikNone:
    sim.say("There is nothing here to pick up.")
    return
  if item.kind == ikGold:
    sim.cog.gold += item.id
    sim.goldPickedUp += item.id
    if li < sim.levelGold.len:
      sim.levelGold[li] += item.id
    sim.say("$ - " & $item.id & " gold pieces.")
    sim.emit("gold", %*{"amount": item.id, "total": sim.cog.gold})
  else:
    let letter = sim.cog.freeLetter()
    if letter < 0:
      sim.say("You cannot carry anything else.")
      return
    sim.cog.inv[letter] = item
    inc sim.itemsPicked
    let name = itemName(item, sim.potionKnown, sim.potionAppearance)
    sim.say($chr(ord('a') + letter) & " - " & name & ".")
    sim.emit("item", %*{"name": name, "letter": $chr(ord('a') + letter)})
  sim.levels[li].cells[cell].item = emptyItem()

proc applyKick(sim: var SimServer, dir: int) =
  let li = sim.levelIndex
  let
    nx = sim.cog.x + DirDx[dir]
    ny = sim.cog.y + DirDy[dir]
  if not inside(nx, ny):
    sim.say("Ouch! That hurts!")
    sim.hurtCog(1, "the wall")
    return
  let monster = sim.levels[li].monsterAt(nx, ny)
  if monster >= 0:
    let species = sim.levels[li].monsters[monster].species
    if hits(sim.config.seed, sim.cog.depth, sim.tickCount, 2001,
            sim.cogAttackBonus(), SpeciesAc[species]):
      let damage = damageRoll(sim.config.seed, sim.cog.depth, sim.tickCount,
                              2002, 3)
      sim.levels[li].monsters[monster].hp -= damage
      if sim.levels[li].monsters[monster].hp <= 0:
        sim.killMonster(monster)
      else:
        sim.say("You kick the " & SpeciesName[species] & ".")
    else:
      sim.say("You miss the " & SpeciesName[species] & ".")
    return
  if sim.levels[li].terrainAt(nx, ny) == tDoorLocked:
    if sim.cog.hunger in {hWeak, hFainting}:
      sim.say("You are too weak to kick.")
      return
    if hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount, 2003, 3) == 0:
      sim.levels[li].setTerrain(nx, ny, tDoorway)
      inc sim.doorsKicked
      sim.say("As you kick the door, it crashes open!")
      sim.emit("door", %*{"action": "kick", "x": nx, "y": ny})
    else:
      sim.say("WHAMM!!")
    return
  sim.say("Ouch! That hurts!")
  sim.hurtCog(1, "the wall")

proc applyChat(sim: var SimServer, dir: int) =
  let li = sim.levelIndex
  let
    nx = sim.cog.x + DirDx[dir]
    ny = sim.cog.y + DirDy[dir]
  let monster = sim.levels[li].monsterAt(nx, ny)
  if monster < 0 or sim.levels[li].monsters[monster].species != spOracle:
    sim.say("They seem not to notice you.")
    return
  if sim.cog.gold < sim.config.consultCost:
    sim.say("The Oracle scowls at your empty purse.")
    sim.emit("oracle", %*{"paid": false, "hint": ""})
    return
  sim.cog.gold -= sim.config.consultCost
  inc sim.oracleConsults
  sim.awardDeed(deedOracle)
  let hint = compassOctant(sim.cog.x, sim.cog.y,
                           sim.levels[li].downX, sim.levels[li].downY)
  sim.say("The Oracle whispers: the staircase down lies to the " & hint & ".")
  sim.emit("oracle", %*{"paid": true, "hint": hint})

proc applyPrimitive(sim: var SimServer, primitive: Primitive) =
  let li = sim.levelIndex
  case primitive.verb
  of vMove:
    sim.applyMove(primitive.dir)
  of vSearch:
    sim.applySearch()
  of vPickup:
    sim.applyPickup()
  of vEat:
    let outcome = sim.cog.eatItem(primitive.item)
    if outcome.ok:
      inc sim.timesAte
      sim.emit("eat", %*{"name": "food", "nutrition": sim.cog.nutrition})
    sim.say(outcome.message)
  of vQuaff:
    let before = sim.cog.inv[max(0, min(MaxInventory - 1, primitive.item))]
    let appearanceIndex =
      if before.kind == ikPotion:
        sim.potionAppearance[before.id mod PotionNames.len]
      else: 0
    let outcome = sim.cog.quaffItem(
      primitive.item, sim.potionKnown, sim.potionAppearance,
      sim.config.seed, sim.cog.depth, sim.tickCount)
    if outcome.ok:
      inc sim.potionsQuaffed
      sim.emit("quaff", %*{
        "appearance": PotionAppearances[appearanceIndex mod PotionAppearances.len],
        "effect": outcome.effect})
    sim.say(outcome.message)
  of vWield:
    sim.say(sim.cog.wieldItem(primitive.item).message)
  of vWear:
    sim.say(sim.cog.wearItem(primitive.item).message)
  of vKick:
    sim.applyKick(primitive.dir)
  of vChat:
    sim.applyChat(primitive.dir)
  of vDown:
    if sim.levels[li].terrainAt(sim.cog.x, sim.cog.y) == tStairsDown:
      sim.descend()
    else:
      sim.say("You cannot go down here.")
  of vUp:
    if sim.levels[li].terrainAt(sim.cog.x, sim.cog.y) == tStairsUp:
      sim.ascend()
    else:
      sim.say("You cannot go up here.")
  of vWait, vTravel:
    discard

proc triggerTrap(sim: var SimServer, movedThisTick: bool) =
  if not movedThisTick or sim.ended:
    return
  let li = sim.levelIndex
  let cell = idx(sim.cog.x, sim.cog.y)
  if sim.levels[li].cells[cell].trapKind < 0 or
      sim.levels[li].cells[cell].trapFound:
    return
  let kind = sim.levels[li].cells[cell].trapKind mod 4
  sim.levels[li].cells[cell].trapFound = true
  inc sim.trapsTriggered
  var damage = 0
  case kind
  of 0:
    damage = 1 + hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount, 2101, 6)
    sim.say("An arrow shoots out at you!")
  of 1:
    damage = 1 + hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount, 2102, 3)
    sim.say("A little dart shoots out at you!")
  of 2:
    damage = 1 + hashRnd(sim.config.seed, sim.cog.depth, sim.tickCount, 2103, 3)
    sim.cog.trapped = 3
    sim.say("You fall into a pit!")
  else:
    var candidates: seq[int] = @[]
    for y in 0 ..< LevelH:
      for x in 0 ..< LevelW:
        if sim.levels[li].terrainAt(x, y) == tFloor and
            sim.levels[li].monsterAt(x, y) < 0:
          candidates.add(idx(x, y))
    if candidates.len > 0:
      let pick = candidates[hashRnd(sim.config.seed, sim.cog.depth,
                                    sim.tickCount, 2104, candidates.len)]
      sim.cog.x = pick mod LevelW
      sim.cog.y = pick div LevelW
    sim.say("You feel a wrenching sensation.")
  if damage > 0:
    sim.hurtCog(damage, TrapNames[kind])
  sim.emit("trap", %*{"kind": TrapNames[kind], "dmg": damage})

proc monstersAct(sim: var SimServer) =
  if sim.ended:
    return
  let li = sim.levelIndex
  let components = componentMap(sim.levels[li])
  for i in 0 ..< sim.levels[li].monsters.len:
    if not sim.levels[li].monsters[i].alive:
      continue
    let species = sim.levels[li].monsters[i].species
    let actions = actionsThisTick(SpeciesSpeed[species], sim.tickCount)
    for _ in 0 ..< actions:
      if sim.ended or not sim.levels[li].monsters[i].alive:
        break
      let monster = sim.levels[li].monsters[i]
      if chebyshev(monster.x, monster.y, sim.cog.x, sim.cog.y) <= 1 and
          not (monster.x == sim.cog.x and monster.y == sim.cog.y):
        if SpeciesDmg[species] <= 0:
          continue                       ## a floating eye never attacks
        if hits(sim.config.seed, sim.cog.depth, sim.tickCount, 2200 + i,
                SpeciesLevel[species], sim.cog.ac):
          let damage = damageRoll(sim.config.seed, sim.cog.depth,
                                  sim.tickCount, 2300 + i, SpeciesDmg[species])
          sim.say("The " & SpeciesName[species] & " bites!")
          sim.hurtCog(damage, SpeciesName[species])
          if species == spLichen:
            sim.cog.stuck = 3
        else:
          sim.say("The " & SpeciesName[species] & " misses.")
        continue
      let dir = chooseMonsterMove(sim.levels[li], components, i,
                                  sim.cog.x, sim.cog.y, sim.config.seed,
                                  sim.cog.depth, sim.tickCount,
                                  sim.config.aggroRange)
      if dir >= 0:
        sim.levels[li].monsters[i].x += DirDx[dir]
        sim.levels[li].monsters[i].y += DirDy[dir]

proc deathChecks(sim: var SimServer) =
  if sim.ended:
    return
  if sim.cog.hp <= 0:
    var killer = "something"
    let li = sim.levelIndex
    var best = -1
    for i, monster in sim.levels[li].monsters:
      if monster.alive and
          chebyshev(monster.x, monster.y, sim.cog.x, sim.cog.y) <= 1:
        best = i
        break
    if best >= 0:
      killer = SpeciesName[sim.levels[li].monsters[best].species]
    sim.say("You die...")
    sim.endRun(erDeath, codKilled, killer)
    return
  if sim.cog.nutrition <= -200:
    sim.say("You die from starvation.")
    sim.endRun(erDeath, codStarved, "starvation")
    return
  if sim.levels[sim.levelIndex].terrainAt(sim.cog.x, sim.cog.y) == tLava:
    sim.endRun(erDeath, codBurned, "lava")

proc stepTick*(sim: var SimServer) =
  ## ONE dungeon turn, in the numbered order of the design note. This is the
  ## whole physics of the game; nothing else mutates the world.
  if sim.ended:
    return
  let beforeDepth = sim.cog.depth

  # 1. tick, nutrition, hunger state
  inc sim.tickCount
  dec sim.cog.nutrition
  let hunger = hungerOf(sim.cog.nutrition)
  if hunger != sim.cog.hunger:
    sim.cog.hunger = hunger
    sim.say("You feel " & ($hunger).toLowerAscii() & " now.")
    sim.emit("hunger", %*{"state": $hunger})

  var moved = false
  var skipped = false
  sim.executedVerb = ""

  # 2. involuntary states first
  if sim.cog.paralysed > 0:
    dec sim.cog.paralysed
    if sim.queue.len > 0:
      sim.queue.delete(0)
    sim.say("You are frozen.")
    skipped = true
  elif sim.cog.trapped > 0:
    dec sim.cog.trapped
    if sim.queue.len > 0:
      sim.queue.delete(0)
    sim.say("You crawl to the edge of the pit.")
    skipped = true

  if not skipped:
    # 3. pop the next primitive; an empty queue is a real `wait`
    var primitive = Primitive(verb: vWait, dir: 0, item: -1)
    if sim.queue.len > 0:
      primitive = sim.queue[0]
      sim.queue.delete(0)
    let beforeX = sim.cog.x
    let beforeY = sim.cog.y
    # 4. apply it
    sim.applyPrimitive(primitive)
    sim.executedVerb = $primitive.verb
    if primitive.verb != vWait:
      inc sim.primitivesExecuted
    moved = sim.cog.x != beforeX or sim.cog.y != beforeY

  if sim.cog.stuck > 0:
    dec sim.cog.stuck
  if sim.cog.confused > 0:
    dec sim.cog.confused

  # 5. traps
  if sim.cog.depth == beforeDepth:
    sim.triggerTrap(moved)

  # 6. monsters act
  if sim.cog.depth == beforeDepth:
    sim.monstersAct()

  # 7. death checks
  sim.deathChecks()

  # 8. regeneration and experience
  if not sim.ended and sim.config.regenTicks > 0 and
      sim.tickCount mod sim.config.regenTicks == 0 and
      sim.cog.hp < sim.cog.maxHp and
      sim.cog.hunger notin {hWeak, hFainting}:
    inc sim.cog.hp
  sim.checkExperience()

  # 9. visibility, memory and deeds
  sim.recomputeVisibility()
  if sim.cog.depth > sim.depthReached:
    sim.depthReached = sim.cog.depth
  sim.checkDeeds()

  let li = sim.levelIndex
  if li < sim.levelTicks.len:
    inc sim.levelTicks[li]

  # 10. the integrity link
  sim.mixTick()

  # 11. the turn ends early when the run ended or the cog changed level
  if sim.tickCount >= sim.config.maxTicks and not sim.ended:
    sim.endRun(erTurnCap, codNone, "")

proc turnShouldBreak*(sim: SimServer, beforeDepth: int): bool =
  sim.ended or sim.cog.depth != beforeDepth

# ---------------------------------------------------------------------------
#  The observation
# ---------------------------------------------------------------------------

proc monsterBlockMask*(sim: SimServer): seq[bool] =
  ## The cells the driver refuses to path through: those holding a CURRENTLY
  ## VISIBLE monster. A monster the cog cannot see must not steer its plan —
  ## that would leak the one thing NetHack never remembers.
  result = newSeq[bool](LevelW * LevelH)
  let li = sim.levelIndex
  for monster in sim.levels[li].monsters:
    if not monster.alive:
      continue
    if not inside(monster.x, monster.y):
      continue
    if sim.visible[idx(monster.x, monster.y)]:
      result[idx(monster.x, monster.y)] = true

proc renderMap*(sim: SimServer): seq[string] =
  ## Eighteen strings of exactly forty-eight characters: remembered terrain,
  ## remembered items, CURRENTLY VISIBLE monsters, `@` for the cog, and a
  ## space for everything never seen.
  let li = sim.levelIndex
  for y in 0 ..< LevelH:
    var row = newString(LevelW)
    for x in 0 ..< LevelW:
      row[x] =
        if x == sim.cog.x and y == sim.cog.y: '@'
        else: sim.levels[li].glyphAt(x, y, sim.visible, sim.potionKnown,
                                     sim.potionAppearance)
    result.add(row)

proc observedMessages*(sim: SimServer): seq[string] =
  ## At most eight entries; if more were produced the OLDEST are dropped and
  ## the first entry says how many.
  if sim.messages.len <= MaxObservedMessages:
    return sim.messages
  let dropped = sim.messages.len - (MaxObservedMessages - 1)
  result.add("(" & $dropped & " earlier messages)")
  for i in dropped ..< sim.messages.len:
    result.add(sim.messages[i])

proc inventoryJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for letter in 0 ..< MaxInventory:
    let item = sim.cog.inv[letter]
    if item.kind == ikNone:
      continue
    let equipped =
      if sim.cog.wielded == letter: "wielded"
      elif sim.cog.worn == letter: "worn"
      else: ""
    result.add(%*{
      "letter": $chr(ord('a') + letter),
      "name": itemName(item, sim.potionKnown, sim.potionAppearance),
      "kind": $item.kind,
      "count": max(1, item.count),
      "equipped": equipped})

proc visibleJson*(sim: SimServer): JsonNode =
  result = newJArray()
  let li = sim.levelIndex
  for y in 0 ..< LevelH:
    for x in 0 ..< LevelW:
      if not sim.visible[idx(x, y)]:
        continue
      let monster = sim.levels[li].monsterAt(x, y)
      if monster >= 0:
        let species = sim.levels[li].monsters[monster].species
        result.add(%*{"glyph": $SpeciesGlyph[species],
                      "name": SpeciesName[species],
                      "x": x, "y": y, "kind": "monster"})
        continue
      let item = sim.levels[li].cells[idx(x, y)].item
      if item.kind != ikNone:
        result.add(%*{"glyph": $ItemGlyph[item.kind],
                      "name": itemName(item, sim.potionKnown,
                                       sim.potionAppearance),
                      "x": x, "y": y, "kind": $item.kind})

proc deedsJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for i, deed in AllDeeds:
    result.add(%*{"name": $deed, "earned": sim.deeds[i]})

proc levelJson*(sim: SimServer): JsonNode =
  let li = sim.levelIndex
  var roomsSeen = 0
  for room in sim.levels[li].rooms:
    if not room.used:
      continue
    if sim.levels[li].seen[idx(room.x, room.y)]:
      inc roomsSeen
  let downSeen = sim.levels[li].seen[idx(sim.levels[li].downX, sim.levels[li].downY)]
  let upSeen = sim.levels[li].seen[idx(sim.levels[li].upX, sim.levels[li].upY)]
  %*{
    "depth": sim.cog.depth,
    "stairs_down": (if downSeen: %*{"x": sim.levels[li].downX,
                                    "y": sim.levels[li].downY}
                    else: newJNull()),
    "stairs_up": (if upSeen: %*{"x": sim.levels[li].upX,
                                "y": sim.levels[li].upY}
                  else: newJNull()),
    "rooms_seen": roomsSeen,
    "lit": (block:
      let room = sim.levels[li].roomOf(sim.cog.x, sim.cog.y)
      room >= 0 and sim.levels[li].rooms[room].lit)
  }

proc observationJson*(sim: SimServer, turn: int, includeMap: bool): JsonNode =
  ## Exactly what the cog may know: what it has seen, what it is carrying,
  ## and what the message line just told it. The episode seed, unvisited
  ## levels, monsters out of sight, undiscovered traps, unidentified potion
  ## kinds, its own score and its own real player name are all hidden.
  let li = sim.levelIndex
  var executed = newJArray()
  for verb in sim.lastExecuted:
    executed.add(%verb)
  var status = newJArray()
  for name in sim.cog.statusList():
    status.add(%name)
  var messages = newJArray()
  for line in sim.observedMessages():
    messages.add(%line)
  let underItem = sim.levels[li].cells[idx(sim.cog.x, sim.cog.y)].item
  result = %*{
    "you_are": "Alpha the Digger",
    "turn": turn,
    "tick": sim.tickCount,
    "turns_left": max(0, sim.config.maxTurns - sim.turnsPlayed),
    "ticks_left": max(0, sim.config.maxTicks - sim.tickCount),
    "status_line": sim.cog.statusLine(sim.tickCount),
    "you": {
      "x": sim.cog.x, "y": sim.cog.y, "depth": sim.cog.depth,
      "hp": max(0, sim.cog.hp), "max_hp": sim.cog.maxHp, "ac": sim.cog.ac,
      "xlevel": sim.cog.xlevel, "xp": sim.cog.xpPoints,
      "gold": sim.cog.gold, "nutrition": sim.cog.nutrition,
      "hunger": $sim.cog.hunger, "status": status,
      "under_foot": {
        "glyph": $TerrainGlyph[sim.levels[li].terrainAt(sim.cog.x, sim.cog.y)],
        "item": (if underItem.kind == ikNone: newJNull()
                 else: %itemName(underItem, sim.potionKnown,
                                 sim.potionAppearance))}
    },
    "messages": messages,
    "visible": sim.visibleJson(),
    "inventory": sim.inventoryJson(),
    "level": sim.levelJson(),
    "last_plan": {
      "executed": executed,
      "truncated": sim.lastTruncated,
      "dropped": sim.lastDropped,
      "unreachable": sim.lastUnreachable
    },
    "deeds": sim.deedsJson(),
    "depth_reached": sim.depthReached,
    "notes": sim.notes
  }
  if includeMap:
    var rows = newJArray()
    for row in sim.renderMap():
      rows.add(%row)
    result["map"] = rows

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

proc cellsSeen*(sim: SimServer): int =
  for level in sim.levels:
    for value in level.seen:
      if value: inc result

proc winFlag*(sim: SimServer): bool = sim.depthReached >= sim.config.parDepth

proc runResultsJson*(sim: SimServer): string =
  ## The closed results schema. Adding a key means updating the manifest's
  ## `results_schema` and `tools/ci/docker_smoke.sh` in the same commit.
  var deeds = newJArray()
  for i, deed in AllDeeds:
    if sim.deeds[i]:
      deeds.add(%($deed))
  var names = newJArray()
  names.add(%sim.playerName)
  var aliases = newJArray()
  aliases.add(%"Alpha")
  var scores = newJArray()
  scores.add(%sim.score())
  var win = newJArray()
  win.add(%sim.winFlag())
  var kinds = newJArray()
  kinds.add(%sim.policyKind)
  var dead = newJArray()
  dead.add(%sim.deadSeat)
  proc arr(values: seq[int]): JsonNode =
    result = newJArray()
    for value in values:
      result.add(%value)
  let document = %*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": (if sim.winFlag(): %0 else: newJNull()),
    "reason": $sim.endReason,
    "endRule": (if sim.endRule == erNone: "turnCap" else: $sim.endRule),
    "variant": sim.config.variantName(),
    "seed": sim.config.seed,
    "dungeonLevels": sim.config.dungeonLevels,
    "parDepth": sim.config.parDepth,
    "depthReached": sim.depthReached,
    "finalDepth": sim.cog.depth,
    "gold": sim.cog.gold,
    "xpPoints": sim.cog.xpPoints,
    "xlevel": sim.cog.xlevel,
    "monstersKilled": sim.monstersKilled,
    "itemsPicked": sim.itemsPicked,
    "timesAte": sim.timesAte,
    "potionsQuaffed": sim.potionsQuaffed,
    "oracleConsults": sim.oracleConsults,
    "doorsKicked": sim.doorsKicked,
    "trapsTriggered": sim.trapsTriggered,
    "deeds": deeds,
    "deedCount": sim.deedCount(),
    "hpFinal": max(0, sim.cog.hp),
    "maxHpFinal": sim.cog.maxHp,
    "causeOfDeath": $sim.causeOfDeath,
    "killer": sim.killer,
    "levelTurns": arr(sim.levelTurns),
    "levelTicks": arr(sim.levelTicks),
    "levelKills": arr(sim.levelKills),
    "levelGold": arr(sim.levelGold),
    "goldPickedUp": sim.goldPickedUp,
    "cellsSeen": sim.cellsSeen(),
    "cellsTotal": LevelW * LevelH * sim.config.dungeonLevels,
    "primitivesExecuted": sim.primitivesExecuted,
    "actionsDropped": sim.actionsDropped,
    "macrosUnreachable": sim.macrosUnreachable,
    "repliesRepaired": sim.repliesRepaired,
    "finalTick": sim.tickCount,
    "turnsPlayed": sim.turnsPlayed,
    "policyKinds": kinds,
    "llmTurns": sim.llmTurns,
    "fallbackTurns": sim.fallbackTurns,
    "deadSeats": dead,
    "stopDetail": sim.stopDetail
  }
  $document
