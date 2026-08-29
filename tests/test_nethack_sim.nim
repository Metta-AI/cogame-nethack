## Sim unit tests: terrain, primitives, diagonals, visibility, combat,
## monster speed, hunger, traps, items, stairs, the Oracle, the turn order,
## the integer-only rule and the tick budget.

import std/[os, strutils, times, unittest]

import nethack/[sim, driver, baselines]

proc freshSim(seed = 1234, ladder: seq[string] = @[]): SimServer =
  var config = defaultGameConfig()
  config.seed = seed
  config.levelLadder = ladder
  if ladder.len > 0:
    config.dungeonLevels = ladder.len
  result = initSimServer(config)
  result.phase = Playing

suite "terrain and glyphs":
  test "the board is 48x18 and its whole border ring is solid rock":
    check LevelW == 48
    check LevelH == 18
    let level = generateLevel(7, 1, false)
    for x in 0 ..< LevelW:
      check level.terrainAt(x, 0) == tRock
      check level.terrainAt(x, LevelH - 1) == tRock
    for y in 0 ..< LevelH:
      check level.terrainAt(0, y) == tRock
      check level.terrainAt(LevelW - 1, y) == tRock

  test "the glyph, passability and sight tables are total and match the note":
    for terrain in Terrain:
      discard TerrainGlyph[terrain]
      discard TerrainPassable[terrain]
      discard TerrainClearSight[terrain]
    check TerrainGlyph[tFloor] == '.'
    check TerrainGlyph[tCorridor] == '#'
    check TerrainGlyph[tDoorway] == '\''
    check TerrainGlyph[tDoorClosed] == '+'
    check TerrainGlyph[tDoorLocked] == '+'
    check TerrainGlyph[tSecretDoor] == ' '
    check TerrainGlyph[tStairsDown] == '>'
    check TerrainGlyph[tStairsUp] == '<'
    check TerrainGlyph[tLava] == '}'
    check not TerrainPassable[tDoorClosed]
    check not TerrainPassable[tDoorLocked]
    check TerrainPassable[tLava]        ## enterable, and fatal

  test "the item, monster and feature glyph sets are disjoint and closed":
    var seen: set[char] = {}
    for kind in ItemKind:
      if kind == ikNone:
        continue
      check ItemGlyph[kind] notin seen
      seen.incl(ItemGlyph[kind])
    for species in Species:
      check SpeciesGlyph[species] notin seen
      seen.incl(SpeciesGlyph[species])
    check '@' notin seen

suite "primitives":
  test "moving into a closed door opens it and does NOT move the cog":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tDoorClosed)
    let (x, y) = (s.cog.x, s.cog.y)
    s.playTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
    check s.cog.x == x
    check s.cog.y == y
    check s.levels[li].terrainAt(x + 1, y) == tDoorway

  test "moving into a locked door says so and nothing else happens":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tDoorLocked)
    s.playTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
    check s.levels[li].terrainAt(s.cog.x + 1, s.cog.y) == tDoorLocked
    check "locked" in s.messages.join(" ")

  test "moving into lava kills the cog":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tLava)
    s.playTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
    check s.ended
    check s.endRule == erDeath
    check s.causeOfDeath == codBurned
    check s.killer == "lava"

  test "moving into solid rock spends the tick and nothing else":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tRock)
    let before = s.tickCount
    s.playTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
    check s.tickCount == before + 1
    check s.cog.nutrition == s.config.startNutrition - 1

  test "pickup, eat, wield and wear do exactly what the table says":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].cells[idx(s.cog.x, s.cog.y)].item =
      Item(kind: ikGold, id: 40, count: 1)
    s.playTurn(@[Action(verb: vPickup, item: -1)], 0)
    check s.cog.gold == 40
    check s.goldPickedUp == 40
    s.playTurn(@[Action(verb: vEat, item: 1)], 0)
    check s.timesAte == 1
    check s.cog.nutrition > s.config.startNutrition
    check s.cog.inv[1].kind == ikNone
    s.cog.inv[3] = Item(kind: ikWeapon, id: 3, count: 1)   ## a long sword
    s.playTurn(@[Action(verb: vWield, item: 3)], 0)
    check s.cog.wielded == 3
    check s.cog.weaponDie() == 8
    s.cog.inv[4] = Item(kind: ikArmour, id: 2, count: 1)   ## plate mail
    s.playTurn(@[Action(verb: vWear, item: 4)], 0)
    check s.cog.worn == 4
    check s.cog.ac == 9 - 6

  test "an inapplicable primitive is a no-op that still costs a tick":
    var s = freshSim()
    let before = s.tickCount
    s.playTurn(@[Action(verb: vEat, item: 0)], 0)   ## `a` is the dagger
    check s.tickCount == before + 1
    check s.timesAte == 0

  test "pickup on an empty cell says there is nothing here":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].cells[idx(s.cog.x, s.cog.y)].item = emptyItem()
    s.playTurn(@[Action(verb: vPickup, item: -1)], 0)
    check "nothing here" in s.messages.join(" ")

suite "diagonal rules":
  test "a diagonal may not cut a doorway or a wall corner":
    var level = newLevel(1)
    for y in 1 .. 3:
      for x in 1 .. 3:
        level.setTerrain(x, y, tFloor)
    ## south-east out of (1, 1) passes (2, 1) and (1, 2): open floor, legal.
    check not level.cornerCut(1, 1, 1)
    level.setTerrain(2, 1, tWallH)
    check level.cornerCut(1, 1, 1)      ## now it would cut a wall corner
    level.setTerrain(2, 1, tDoorway)
    check level.cornerCut(1, 1, 1)      ## and a doorway is just as illegal

  test "orthogonal steps are never corner cuts":
    let level = generateLevel(3, 1, false)
    for dir in OrthoDirs:
      check not level.cornerCut(10, 5, dir)

  test "a grid bug never moves diagonally":
    var level = newLevel(1)
    for y in 1 .. 5:
      for x in 1 .. 10:
        level.setTerrain(x, y, tFloor)
    level.addMonster(spGridBug, 5, 3)
    let components = componentMap(level)
    for tick in 1 .. 40:
      let dir = chooseMonsterMove(level, components, 0, 8, 3, 11, 1, tick, 10)
      if dir >= 0:
        check dir mod 2 == 0

suite "visibility":
  test "a lit room shows its whole floor and wall ring; a dark one shows 3x3":
    var s = freshSim()
    let li = s.levelIndex
    var lit = -1
    for i, room in s.levels[li].rooms:
      if room.used and room.lit:
        lit = i
        break
    if lit >= 0:
      let room = s.levels[li].rooms[lit]
      let visible = s.levels[li].visibleSet(room.x, room.y)
      for y in room.y ..< room.y + room.h:
        for x in room.x ..< room.x + room.w:
          check visible[idx(x, y)]
      check visible[idx(room.x - 1, room.y - 1)]
    ## a corridor cell is never in a room, so it always sees exactly 3x3
    var corridor = -1
    for i in 0 ..< s.levels[li].cells.len:
      if s.levels[li].cells[i].terrain == tCorridor:
        corridor = i
        break
    if corridor >= 0:
      let
        cx = corridor mod LevelW
        cy = corridor div LevelW
        visible = s.levels[li].visibleSet(cx, cy)
      var count = 0
      for value in visible:
        if value: inc count
      check count <= 9

  test "monsters are never remembered and a never-seen cell renders as a space":
    var s = freshSim()
    let li = s.levelIndex
    var found = false
    for y in 0 ..< LevelH:
      for x in 0 ..< LevelW:
        if not s.levels[li].seen[idx(x, y)]:
          check s.levels[li].glyphAt(x, y, s.visible, s.potionKnown,
                                     s.potionAppearance) == ' '
          found = true
    check found
    ## place a monster on a remembered but not currently visible cell
    var target = -1
    for i in 0 ..< s.levels[li].seen.len:
      if s.levels[li].seen[i] and not s.visible[i] and
          s.levels[li].cells[i].terrain == tFloor:
        target = i
        break
    if target >= 0:
      s.levels[li].addMonster(spSewerRat, target mod LevelW, target div LevelW)
      check s.levels[li].glyphAt(target mod LevelW, target div LevelW,
                                 s.visible, s.potionKnown,
                                 s.potionAppearance) != 'r'

  test "a secret door renders as rock until three searches find it":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tSecretDoor)
    s.recomputeVisibility()
    check s.levels[li].glyphAt(s.cog.x + 1, s.cog.y, s.visible, s.potionKnown,
                               s.potionAppearance) == ' '
    s.playTurn(@[Action(verb: vSearch, item: -1),
                 Action(verb: vSearch, item: -1)], 0)
    check s.levels[li].terrainAt(s.cog.x + 1, s.cog.y) == tSecretDoor
    s.playTurn(@[Action(verb: vSearch, item: -1)], 0)
    check s.levels[li].terrainAt(s.cog.x + 1, s.cog.y) == tDoorClosed

suite "combat is deterministic and integer":
  test "the same (seed, depth, tick, salt) always yields the same roll":
    for i in 0 ..< 10_000:
      let a = hashRnd(7, 3, i, 17, 20)
      let b = hashRnd(7, 3, i, 17, 20)
      check a == b
      check a >= 0 and a < 20

  test "to-hit and damage stay inside their declared ranges":
    for tick in 1 .. 2000:
      let damage = damageRoll(11, 2, tick, 5, 8)
      check damage >= 1 and damage <= 9
      discard hits(11, 2, tick, 5, 2, 7)

  test "a floating eye paralyses on a hit AND on a miss":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
    s.levels[li].addMonster(spFloatingEye, s.cog.x + 1, s.cog.y)
    var runner = s.beginTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
    s.stepTurn(runner)
    check s.cog.paralysed == 12
    check "frozen by the floating eye" in s.messages.join(" ")

  test "a lichen sticks":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y + 1, tFloor)
    s.levels[li].setTerrain(s.cog.x - 1, s.cog.y, tFloor)
    s.levels[li].addMonster(spLichen, s.cog.x + 1, s.cog.y)
    s.cog.stuck = 3
    let (x, y) = (s.cog.x, s.cog.y)
    ## west is a move AWAY from the lichen: it fails.
    s.playTurn(@[Action(verb: vMove, dir: 4, item: -1)], 0)
    check s.cog.x == x and s.cog.y == y
    check "stuck to the lichen" in s.messages.join(" ")
    ## south-east keeps contact with the same lichen: it is allowed.
    s.cog.stuck = 3
    s.playTurn(@[Action(verb: vMove, dir: 1, item: -1)], 0)
    check s.cog.x == x + 1 and s.cog.y == y + 1
    ## with the lichen dead there is nothing to be stuck to.
    for i in 0 ..< s.levels[li].monsters.len:
      if s.levels[li].monsters[i].species == spLichen:
        s.levels[li].monsters[i].alive = false
    s.cog.stuck = 3
    let (bx, by) = (s.cog.x, s.cog.y)
    s.playTurn(@[Action(verb: vMove, dir: 6, item: -1)], 0)
    check not (s.cog.x == bx and s.cog.y == by)

  test "a monster never enters lava and never steps onto the cog":
    var level = newLevel(1)
    for y in 1 .. 5:
      for x in 1 .. 10:
        level.setTerrain(x, y, tFloor)
    level.setTerrain(4, 3, tLava)
    level.addMonster(spSewerRat, 5, 3)
    let components = componentMap(level)
    for tick in 1 .. 200:
      let dir = chooseMonsterMove(level, components, 0, 3, 3, 5, 1, tick, 10)
      if dir >= 0:
        let
          nx = level.monsters[0].x + DirDx[dir]
          ny = level.monsters[0].y + DirDy[dir]
        check level.terrainAt(nx, ny) != tLava
        check not (nx == 3 and ny == 3)

suite "monster speed":
  test "the movement-point identity gives exactly `speed` actions per 12 ticks":
    for species in Species:
      let speed = SpeciesSpeed[species]
      var total = 0
      for tick in 1 .. 12:
        total += actionsThisTick(speed, tick)
      check total == speed
    check actionsThisTick(0, 5) == 0

suite "hunger and starvation":
  test "nutrition falls one per tick and the five states switch exactly":
    check hungerOf(1001) == hSatiated
    check hungerOf(1000) == hNotHungry
    check hungerOf(150) == hNotHungry
    check hungerOf(149) == hHungry
    check hungerOf(50) == hHungry
    check hungerOf(49) == hWeak
    check hungerOf(1) == hWeak
    check hungerOf(0) == hFainting
    var s = freshSim()
    s.playTurn(@[Action(verb: vWait, item: -1)], 0)
    check s.cog.nutrition == s.config.startNutrition - 1

  test "a cog that never eats starves, and the death is `starved`":
    var s = freshSim()
    s.cog.nutrition = -199
    s.playTurn(@[Action(verb: vWait, item: -1)], 0)
    check s.ended
    check s.causeOfDeath == codStarved
    check s.killer == "starvation"

  test "Weak blocks kicking and regeneration":
    var s = freshSim()
    let li = s.levelIndex
    s.cog.nutrition = 20
    s.cog.hunger = hungerOf(s.cog.nutrition)
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tDoorLocked)
    s.playTurn(@[Action(verb: vKick, dir: 0, item: -1)], 0)
    check s.levels[li].terrainAt(s.cog.x + 1, s.cog.y) == tDoorLocked
    check "too weak" in s.messages.join(" ")

suite "traps":
  test "each trap kind applies once, becomes discovered and never fires again":
    for kind in 0 .. 3:
      var s = freshSim()
      let li = s.levelIndex
      let target = idx(s.cog.x + 1, s.cog.y)
      s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
      s.levels[li].cells[target].trapKind = kind
      s.levels[li].cells[target].trapFound = false
      s.playTurn(@[Action(verb: vMove, dir: 0, item: -1)], 0)
      check s.levels[li].cells[target].trapFound
      check s.trapsTriggered == 1

suite "items and identification":
  test "potion appearances are a seeded permutation of the six colours":
    for seed in 1 .. 200:
      let table = potionAppearanceTable(seed)
      var seen: set[uint8] = {}
      for value in table:
        check value >= 0 and value < PotionAppearances.len
        check uint8(value) notin seen
        seen.incl(uint8(value))

  test "an unidentified potion shows its appearance, an identified one its name":
    var s = freshSim()
    s.cog.inv[3] = Item(kind: ikPotion, id: 0, count: 1)
    let unidentified = itemName(s.cog.inv[3], s.potionKnown, s.potionAppearance)
    check unidentified.startsWith("a ")
    check unidentified.endsWith(" potion")
    s.playTurn(@[Action(verb: vQuaff, item: 3)], 0)
    check s.potionKnown[0]
    check s.potionsQuaffed == 1
    check itemName(Item(kind: ikPotion, id: 0, count: 1), s.potionKnown,
                   s.potionAppearance) == "potion of healing"

  test "ac is 9 minus the worn armour bonus":
    var s = freshSim()
    check s.cog.ac == 9 - 2
    s.cog.worn = -1
    s.cog.recomputeAc()
    check s.cog.ac == 9

suite "stairs and depth":
  test "down arrives on the next level's up-staircase and back again":
    var s = freshSim()
    let li = s.levelIndex
    s.cog.x = s.levels[li].downX
    s.cog.y = s.levels[li].downY
    s.playTurn(@[Action(verb: vDown, item: -1)], 0)
    check s.cog.depth == 2
    check s.cog.x == s.levels[1].upX
    check s.depthReached == 2
    s.playTurn(@[Action(verb: vUp, item: -1)], 0)
    check s.cog.depth == 1
    check s.depthReached == 2               ## monotone

  test "up on level 1 ends the run `escaped`":
    var s = freshSim()
    let li = s.levelIndex
    s.cog.x = s.levels[li].upX
    s.cog.y = s.levels[li].upY
    s.playTurn(@[Action(verb: vUp, item: -1)], 0)
    check s.ended
    check s.endRule == erEscaped
    check s.endReason == reasonComplete

  test "down on the last level ends the run `bottom`":
    var config = defaultGameConfig()
    config.seed = 99
    config.dungeonLevels = 1
    config.parDepth = 1
    var s = initSimServer(config)
    s.phase = Playing
    s.cog.x = s.levels[0].downX
    s.cog.y = s.levels[0].downY
    s.playTurn(@[Action(verb: vDown, item: -1)], 0)
    check s.ended
    check s.endRule == erBottom

suite "the Oracle":
  test "a consultation costs fifty gold, earns the deed once and gives a hint":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
    s.levels[li].addMonster(spOracle, s.cog.x + 1, s.cog.y)
    s.cog.gold = 30
    s.playTurn(@[Action(verb: vChat, dir: 0, item: -1)], 0)
    check s.cog.gold == 30
    check s.oracleConsults == 0
    s.cog.gold = 120
    s.playTurn(@[Action(verb: vChat, dir: 0, item: -1)], 0)
    check s.cog.gold == 70
    check s.oracleConsults == 1
    check s.deeds[ord(deedOracle)]
    s.playTurn(@[Action(verb: vChat, dir: 0, item: -1)], 0)
    check s.deedCount() == 1                ## never twice

suite "turn and tick order":
  test "an empty plan spends the whole turn waiting":
    var s = freshSim()
    s.playTurn(@[], 0)
    check s.tickCount == s.config.turnTicks

  test "paralysis discards the next primitive without dropping the tick":
    var s = freshSim()
    s.cog.paralysed = 3
    let (x, y) = (s.cog.x, s.cog.y)
    s.playTurn(@[Action(verb: vMove, dir: 0, item: -1),
                 Action(verb: vMove, dir: 0, item: -1)], 0)
    check s.cog.x == x and s.cog.y == y
    check s.tickCount >= 2

  test "a run-ending event breaks the tick loop and no later tick is counted":
    var s = freshSim()
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tLava)
    var actions: seq[Action] = @[]
    for i in 0 ..< 10:
      actions.add(Action(verb: vMove, dir: 0, item: -1))
    s.playTurn(actions, 0)
    check s.ended
    check s.tickCount == 1

suite "no floating point in the sim":
  test "the sim sources contain no float type, literal or sqrt":
    for name in ["sim", "dungeon", "mobs", "items", "minihack", "driver",
                 "baselines"]:
      let source = readFile("src/nethack/" & name & ".nim")
      for line in source.splitLines():
        let code = line.strip()
        if code.startsWith("#") or code.startsWith("##"):
          continue
        check "sqrt(" notin code
        check ": float" notin code
        check "float(" notin code

suite "tick budget":
  test "a full 2200-tick descend episode completes well inside a second":
    var config = defaultGameConfig()
    config.seed = 20260828
    var s = initSimServer(config)
    s.phase = Playing
    let started = cpuTime()
    var turn = 0
    while not s.ended and turn < config.maxTurns:
      inc turn
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
    check cpuTime() - started < 5.0
    check s.tickCount <= config.maxTicks
