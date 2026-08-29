## Level-generator tests: well-formedness, connectivity, purity as a function
## of (seed, depth), the revisit rule, and the MiniHack templates.
##
## The sweeps are the design note's: 500 seeds x 8 depths in a release build,
## a smaller sweep in a debug build so the debug shard stays quick. Both cover
## every generator branch.

import std/[strutils, unittest]

import nethack/[sim, driver, baselines]

const SweepSeeds = when defined(release): 500 else: 120

proc roomsOf(level: Level): seq[Room] =
  for room in level.rooms:
    if room.used:
      result.add(room)

suite "level generator well-formedness":
  test "every level has 6..8 rooms whose wall rings are intact and disjoint":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 2654435761, depth, depth == 5)
        let rooms = level.roomsOf()
        check rooms.len >= 6
        check rooms.len <= 9
        for room in rooms:
          check room.x >= 1
          check room.y >= 1
          check room.x + room.w <= LevelW - 1
          check room.y + room.h <= LevelH - 1
          check room.w >= 3
          check room.h >= 2
          for y in room.y - 1 .. room.y + room.h:
            for x in room.x - 1 .. room.x + room.w:
              let interior = x >= room.x and x < room.x + room.w and
                y >= room.y and y < room.y + room.h
              if not interior:
                ## a wall ring cell is a wall, a door, or a corridor cut
                ## through it — never open rock
                check level.terrainAt(x, y) != tRock

  test "exactly one down staircase and one up staircase, never in one room":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 7919, depth, false)
        var downs = 0
        var ups = 0
        for cell in level.cells:
          if cell.terrain == tStairsDown: inc downs
          if cell.terrain == tStairsUp: inc ups
        check downs == 1
        check ups == 1
        check level.roomOf(level.upX, level.upY) !=
          level.roomOf(level.downX, level.downY)

  test "no object sits on a staircase and no two objects share a cell":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 104729, depth, false)
        var foods = 0
        for i, cell in level.cells:
          if cell.item.kind == ikNone:
            continue
          check cell.terrain == tFloor
          if cell.item.kind == ikFood:
            inc foods
        check foods >= 1          ## hunger must be survivable

  test "monster counts follow the depth ramp and none start in the arrival room":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 15485863, depth, false)
        check level.monsters.len <= min(MaxMonstersPerLevel, 2 + depth) + 2
        for monster in level.monsters:
          check level.cells[idx(monster.x, monster.y)].room !=
            level.arrivalRoom
          check depth >= SpeciesMinDepth[monster.species]
          check depth <= SpeciesMaxDepth[monster.species]

suite "level connectivity":
  test "< and > are mutually reachable and every item is reachable from <":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 32452843, depth, depth == 5)
        check level.levelConnected()

  test "no secret door is ever a cut vertex":
    for seed in 1 .. SweepSeeds:
      for depth in 1 .. 8:
        let level = generateLevel(seed * 49979687, depth, false)
        check level.levelConnected(treatSecretAsRock = true)

suite "levels are a pure function of (seed, depth)":
  test "the same (seed, depth) yields byte-identical levels every time":
    for seed in 1 .. 200:
      for depth in 1 .. 8:
        let a = generateLevel(seed * 3, depth, depth == 5)
        let b = generateLevel(seed * 3, depth, depth == 5)
        check a.cells.len == b.cells.len
        for i in 0 ..< a.cells.len:
          check a.cells[i].terrain == b.cells[i].terrain
          check a.cells[i].trapKind == b.cells[i].trapKind
          check a.cells[i].item.kind == b.cells[i].item.kind
          check a.cells[i].item.id == b.cells[i].item.id
        check a.monsters.len == b.monsters.len
        check a.upX == b.upX and a.downX == b.downX

  test "what happened on level k-1 cannot change level k":
    ## Three different agent behaviours over the same seed, then compare the
    ## generated layout of every level they reached.
    var layouts: array[3, seq[string]]
    for behaviour in 0 .. 2:
      var config = defaultGameConfig()
      config.seed = 987654
      var s = initSimServer(config)
      s.phase = Playing
      var turn = 0
      while not s.ended and turn < 12:
        inc turn
        case behaviour
        of 0: s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
        of 1: s.playTurn(@[Action(verb: vSearch, item: -1)], 0)
        else: s.playTurn(@[Action(verb: vMove, dir: turn mod 8, item: -1)], 0)
      for depth in 1 .. 8:
        var row = ""
        let level = generateLevel(config.seed, depth, depth == 5)
        for cell in level.cells:
          row.add($ord(cell.terrain))
        layouts[behaviour].add(row)
    check layouts[0] == layouts[1]
    check layouts[1] == layouts[2]

  test "a revisited level is restored exactly as it was left":
    var config = defaultGameConfig()
    config.seed = 5150
    var s = initSimServer(config)
    s.phase = Playing
    let li = s.levelIndex
    s.levels[li].cells[idx(s.cog.x, s.cog.y)].item = emptyItem()
    s.cog.x = s.levels[li].downX
    s.cog.y = s.levels[li].downY
    s.levels[li].setTerrain(5, 5, tDoorway)      ## a door we "opened"
    if s.levels[li].monsters.len > 0:
      s.levels[li].monsters[0].alive = false     ## a monster we killed
    s.playTurn(@[Action(verb: vDown, item: -1)], 0)
    check s.cog.depth == 2
    s.playTurn(@[Action(verb: vUp, item: -1)], 0)
    check s.cog.depth == 1
    check s.levels[0].terrainAt(5, 5) == tDoorway
    if s.levels[0].monsters.len > 0:
      check not s.levels[0].monsters[0].alive

suite "minihack templates":
  test "every template is well formed and its > is reachable":
    for name in ["corridor", "lavacross", "monsterroom", "lockedvault",
                 "oracle"]:
      for seed in 1 .. 200:
        let level = generateMinihackLevel(name, seed * 11, 1)
        check level.terrainAt(level.downX, level.downY) == tStairsDown
        check level.terrainAt(level.upX, level.upY) == tStairsUp
        check level.levelConnected()

  test "lavacross has exactly one bridge row and an otherwise unbroken river":
    for seed in 1 .. 200:
      let level = generateMinihackLevel("lavacross", seed * 13, 2)
      var lavaRows = 0
      var bridgeRows = 0
      var river = -1
      for x in 0 ..< LevelW:
        var count = 0
        for y in 0 ..< LevelH:
          if level.terrainAt(x, y) == tLava: inc count
        if count > 0 and river < 0: river = x
      check river >= 0
      for y in 2 .. 15:
        if level.terrainAt(river, y) == tLava: inc lavaRows
        else: inc bridgeRows
      check bridgeRows == 1
      check lavaRows == 13

  test "lockedvault's door is always locked and always the only way in":
    for seed in 1 .. 200:
      let level = generateMinihackLevel("lockedvault", seed * 17, 3)
      var locked = 0
      for cell in level.cells:
        if cell.terrain == tDoorLocked: inc locked
      check locked == 1
      ## the vault is unreachable when the locked door counts as rock
      var walled = level
      for i in 0 ..< walled.cells.len:
        if walled.cells[i].terrain == tDoorLocked:
          walled.cells[i].terrain = tRock
      let mask = walled.reachableMask(walled.upX, walled.upY, false)
      check not mask[idx(walled.downX, walled.downY)]

  test "oracle always places a reachable O":
    for seed in 1 .. 200:
      let level = generateMinihackLevel("oracle", seed * 19, 5)
      var oracles = 0
      for monster in level.monsters:
        if monster.species == spOracle: inc oracles
      check oracles == 1

suite "the descend ladder":
  test "depth 5 of descend is the Oracle level and holds no other monster":
    for seed in 1 .. 120:
      let level = generateLevel(seed * 23, 5, true)
      var oracles = 0
      for monster in level.monsters:
        if monster.species == spOracle:
          inc oracles
          check level.cells[idx(monster.x, monster.y)].room == 4
      check oracles == 1
      for monster in level.monsters:
        if monster.species != spOracle:
          check level.cells[idx(monster.x, monster.y)].room != 4
