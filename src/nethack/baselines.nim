## The two scripted baselines. Both are league fillers; `delver` is also the
## server-side fallback, imported by decide.nim rather than duplicated, so
## the two can never drift.
##
## Both emit the SAME reply objects an LLM does, through the same validator,
## which is what makes the bounded-orders test meaningful. Neither ever emits
## `say` or `notes` — a baseline that narrated would make the feed lie about
## which seats are LLMs.

import sim

type
  Baseline* = enum
    blDelver = "delver"
    blBumbler = "bumbler"

  BaselineParams* = object
    ## `delver`'s tunables, a parameter object chosen by the sweep in
    ## tools/tune_baselines.nim, not guessed. tools/ci/baseline_tuning.json
    ## records the pick and tests/test_nethack_tuning.nim asserts the shipped
    ## defaults still equal it.
    fleeHpNumerator*: int
    lootRadius*: int
    searchBurst*: int
    frontierFarthest*: bool
      ## Among the cells that touch the most unseen space, prefer the
      ## FARTHEST reachable one rather than the nearest. The budget that
      ## binds here is TURNS (55), not ticks: a nearest-frontier crawler
      ## spends a whole command turn walking four cells, so it never leaves
      ## dungeon level 1. Crossing the known map in one plan is what turns
      ## the 40-primitive budget into depth.

  BaselineState* = object
    heading*: int

const DefaultBaselineParams* = BaselineParams(
  fleeHpNumerator: 1,
  lootRadius: 15,
  searchBurst: 8,
  frontierFarthest: false
)

proc parseBaseline*(name: string): Baseline =
  ## Anything unrecognised is the published default (`delver`), exactly as
  ## the starter's baselines.nim resolves an unknown name.
  case name
  of "bumbler": blBumbler
  else: blDelver

proc moveAction(dir: int): Action =
  Action(verb: vMove, dir: dir, item: -1)

proc travelAction(x, y: int): Action =
  Action(verb: vTravel, x: x, y: y, item: -1)

proc simpleAction(verb: Verb): Action =
  Action(verb: verb, item: -1)

proc itemAction(verb: Verb, letter: int): Action =
  Action(verb: verb, item: letter)

proc adjacentMonster(sim: SimServer): int =
  ## The lowest-index live monster on a currently visible 8-neighbour cell.
  let li = sim.levelIndex
  result = -1
  for dir in 0 ..< 8:
    let
      nx = sim.cog.x + DirDx[dir]
      ny = sim.cog.y + DirDy[dir]
    if not inside(nx, ny) or not sim.visible[idx(nx, ny)]:
      continue
    let monster = sim.levels[li].monsterAt(nx, ny)
    if monster >= 0:
      return monster

proc adjacentMonsterCount(sim: SimServer): int =
  let li = sim.levelIndex
  for dir in 0 ..< 8:
    let
      nx = sim.cog.x + DirDx[dir]
      ny = sim.cog.y + DirDy[dir]
    if inside(nx, ny) and sim.visible[idx(nx, ny)] and
        sim.levels[li].monsterAt(nx, ny) >= 0:
      inc result

proc nearbyMonster(sim: SimServer, radius: int): int =
  ## The nearest VISIBLE monster inside `radius`, ties by index. Walking away
  ## from a monster does not break contact — everything that chases moves at
  ## the cog's own speed — so a crawler that travels past a live monster is
  ## chewed for the whole plan. Closing and killing it is cheaper.
  let li = sim.levelIndex
  result = -1
  var best = radius + 1
  for i, monster in sim.levels[li].monsters:
    if not monster.alive or not inside(monster.x, monster.y):
      continue
    if not sim.visible[idx(monster.x, monster.y)]:
      continue
    if monster.species == spOracle or monster.species == spFloatingEye:
      continue
    let distance = max(abs(monster.x - sim.cog.x), abs(monster.y - sim.cog.y))
    if distance <= radius and distance < best:
      best = distance
      result = i

proc directionTo(sim: SimServer, x, y: int): int =
  for dir in 0 ..< 8:
    if sim.cog.x + DirDx[dir] == x and sim.cog.y + DirDy[dir] == y:
      return dir
  -1

proc rememberedTerrainCell(sim: SimServer, terrain: Terrain): int =
  let li = sim.levelIndex
  for i in 0 ..< sim.levels[li].memTerrain.len:
    if sim.levels[li].seen[i] and sim.levels[li].memTerrain[i] == terrain:
      return i
  -1

proc adjacentLockedDoor(sim: SimServer): int =
  let li = sim.levelIndex
  for dir in 0 ..< 8:
    let
      nx = sim.cog.x + DirDx[dir]
      ny = sim.cog.y + DirDy[dir]
    if inside(nx, ny) and sim.levels[li].terrainAt(nx, ny) == tDoorLocked:
      return dir
  -1

proc reachableDoor(
  sim: SimServer, terrain: Terrain
): tuple[found: bool, ax, ay, dir: int] =
  ## The nearest remembered door of one kind that can be walked up to, with
  ## the ORTHOGONAL approach cell and the direction from it into the door. A
  ## diagonal step may not cut a doorway, so only orthogonal approaches are
  ## offered.
  let li = sim.levelIndex
  let scan = sim.levels[li].bfsFrom(sim.cog.x, sim.cog.y,
                                    sim.monsterBlockMask())
  var
    best = -1
    bestDistance = 0
  for i in 0 ..< sim.levels[li].memTerrain.len:
    if not sim.levels[li].seen[i] or sim.levels[li].memTerrain[i] != terrain:
      continue
    let
      dx = i mod LevelW
      dy = i div LevelW
    for dir in OrthoDirs:
      let
        nx = dx - DirDx[dir]
        ny = dy - DirDy[dir]
      if not inside(nx, ny):
        continue
      let distance = scan.dist[idx(nx, ny)]
      if distance < 0:
        continue
      if best < 0 or distance < bestDistance or
          (distance == bestDistance and i < best):
        best = i
        bestDistance = distance
        result = (true, nx, ny, dir)

proc frontierCell(sim: SimServer, params: BaselineParams): int =
  ## The remembered traversable cell 8-adjacent to the MOST unseen cells,
  ## ties by lowest BFS distance then lowest (y, x).
  let li = sim.levelIndex
  let scan = sim.levels[li].bfsFrom(sim.cog.x, sim.cog.y,
                                    sim.monsterBlockMask())
  var best = -1
  var bestScore = 0
  var bestDistance = 0
  for i in 0 ..< scan.dist.len:
    if scan.dist[i] < 0 or scan.dist[i] == 0:
      continue
    let
      cx = i mod LevelW
      cy = i div LevelW
    var unseen = 0
    for dir in 0 ..< 8:
      let
        nx = cx + DirDx[dir]
        ny = cy + DirDy[dir]
      if inside(nx, ny) and not sim.levels[li].seen[idx(nx, ny)]:
        inc unseen
    if unseen == 0:
      continue
    let farther =
      if params.frontierFarthest: scan.dist[i] > bestDistance
      else: scan.dist[i] < bestDistance
    let better =
      best < 0 or unseen > bestScore or
      (unseen == bestScore and farther) or
      (unseen == bestScore and scan.dist[i] == bestDistance and i < best)
    if better:
      best = i
      bestScore = unseen
      bestDistance = scan.dist[i]
  best

proc nearestRememberedItem(
  sim: SimServer, kind: ItemKind, radius: int
): int =
  let li = sim.levelIndex
  let scan = sim.levels[li].bfsFrom(sim.cog.x, sim.cog.y,
                                    sim.monsterBlockMask())
  var best = -1
  var bestDistance = radius + 1
  for i in 0 ..< sim.levels[li].memItem.len:
    if not sim.levels[li].seen[i] or sim.levels[li].memItem[i].kind != kind:
      continue
    let distance = scan.dist[i]
    if distance < 0 or distance > radius:
      continue
    if best < 0 or distance < bestDistance or
        (distance == bestDistance and i < best):
      best = i
      bestDistance = distance
  best

proc trimAtEye*(sim: SimServer, actions: seq[Action]): seq[Action] =
  ## NEVER melee a floating eye. A plan's trailing `move` repeats are blind —
  ## they walk a heading into the dark — so the whole plan is walked here
  ## against the remembered map and CUT at the first step that would land on
  ## a visible `e`. Hitting one freezes the cog for twelve dungeon turns and
  ## hands everything else in the room twelve free attacks.
  let li = sim.levelIndex
  var x = sim.cog.x
  var y = sim.cog.y
  for action in actions:
    if action.verb == vTravel:
      ## `travel` refuses to path onto a visible monster, so it can never end
      ## on the eye; it just moves the virtual cursor.
      x = action.x
      y = action.y
      result.add(action)
      continue
    if action.verb != vMove:
      result.add(action)
      continue
    let
      nx = x + DirDx[action.dir]
      ny = y + DirDy[action.dir]
    if inside(nx, ny) and sim.visible[idx(nx, ny)]:
      let monster = sim.levels[li].monsterAt(nx, ny)
      if monster >= 0 and
          sim.levels[li].monsters[monster].species == spFloatingEye:
        return
    result.add(action)
    if sim.levels[li].memoryTraversable(nx, ny):
      x = nx
      y = ny

proc delverPlanRaw(sim: SimServer, params: BaselineParams): seq[Action] =
  ## A deterministic dungeon crawler and an honest stand-in for the symbolic
  ## bots the idea names, scaled to this sim. First matching rule wins.
  ##
  ## The rule ORDER is the strategy: depth is worth a hundred thousand and
  ## everything else is a tie-break, and monsters do not follow the cog down
  ## a staircase — so a known way down outranks a fight, a loot run and an
  ## exploration sweep. Fighting is only ever what the cog does when
  ## something is already on top of it.
  let li = sim.levelIndex

  # 1. eat if weak
  if sim.cog.hunger in {hWeak, hFainting}:
    let letter = sim.cog.lowestFoodLetter()
    if letter >= 0:
      return @[itemAction(vEat, letter)]

  # 2. descend now
  if sim.levels[li].terrainAt(sim.cog.x, sim.cog.y) == tStairsDown:
    return @[simpleAction(vDown)]

  # 3. take the stairs — dive, do not linger
  let down = sim.rememberedTerrainCell(tStairsDown)
  if down >= 0:
    let path = sim.levels[li].pathTo(sim.cog.x, sim.cog.y,
                                     down mod LevelW, down div LevelW,
                                     sim.config.macroPrimitiveCap,
                                     sim.monsterBlockMask())
    if path.reachable:
      return @[travelAction(down mod LevelW, down div LevelW),
               simpleAction(vDown)]

  let monster = adjacentMonster(sim)
  let hurt = sim.cog.hp * params.fleeHpNumerator <= sim.cog.maxHp

  # 4. flee a LOSING fight. At equal speed, walking away from one monster
  #    only trades a tick of damage for a tick of nothing, so the cog only
  #    breaks contact when it is outnumbered and hurt.
  if hurt and sim.adjacentMonsterCount() >= 2:
    let up = sim.rememberedTerrainCell(tStairsUp)
    if up >= 0:
      return @[travelAction(up mod LevelW, up div LevelW)]

  # 5. fight what is already on top of the cog (never a floating eye)
  if monster >= 0 and
      sim.levels[li].monsters[monster].species != spFloatingEye and
      sim.levels[li].monsters[monster].species != spOracle:
    let dir = sim.directionTo(sim.levels[li].monsters[monster].x,
                              sim.levels[li].monsters[monster].y)
    if dir >= 0:
      ## Three blows, then re-plan: a whole turn spent swinging at a pack is
      ## how a crawler dies without ever noticing it was losing.
      while result.len < 3:
        result.add(moveAction(dir))
      return result

  # 5b. rest. Regeneration is the only healing this game has, and searching
  #     is the authentic way to spend the turns: it costs the hunger clock
  #     and it finds secret doors while it heals.
  if sim.cog.hp * 2 <= sim.cog.maxHp and sim.nearbyMonster(6) < 0 and
      sim.cog.hunger notin {hWeak, hFainting}:
    for i in 0 ..< params.searchBurst:
      result.add(simpleAction(vSearch))
    return result

  # 6. loot what is on the way — food outranks gold, always
  if sim.levels[li].cells[idx(sim.cog.x, sim.cog.y)].item.kind != ikNone:
    return @[simpleAction(vPickup)]
  let food = sim.nearestRememberedItem(ikFood, params.lootRadius)
  if food >= 0:
    return @[travelAction(food mod LevelW, food div LevelW),
             simpleAction(vPickup)]
  let gold = sim.nearestRememberedItem(ikGold, params.lootRadius)
  if gold >= 0:
    return @[travelAction(gold mod LevelW, gold div LevelW),
             simpleAction(vPickup)]

  # 7. open what is merely closed. `travel` refuses to path through a `+`, so
  #    a level whose unexplored half sits behind a closed door has NO frontier
  #    at all until the door is walked into (NetHack's autoopen).
  let closed = sim.reachableDoor(tDoorClosed)
  if closed.found:
    result.add(travelAction(closed.ax, closed.ay))
    while result.len < 10:
      result.add(moveAction(closed.dir))
    return result
  let lockedDoor = sim.reachableDoor(tDoorLocked)
  if lockedDoor.found and sim.cog.hunger notin {hWeak, hFainting}:
    result.add(travelAction(lockedDoor.ax, lockedDoor.ay))
    while result.len < 8:
      result.add(Action(verb: vKick, dir: lockedDoor.dir, item: -1))
    result.add(moveAction(lockedDoor.dir))
    result.add(moveAction(lockedDoor.dir))
    return result

  # 8. explore
  let frontier = sim.frontierCell(params)
  if frontier >= 0:
    let path = sim.levels[li].pathTo(sim.cog.x, sim.cog.y,
                                     frontier mod LevelW, frontier div LevelW,
                                     sim.config.macroPrimitiveCap,
                                     sim.monsterBlockMask())
    if path.reachable and path.dirs.len > 0:
      ## Travel to the frontier, then keep walking the SAME heading for the
      ## rest of the ten-action budget. Crossing into the dark is the one
      ## thing `travel` cannot do — it plans only on remembered cells — so
      ## every step past the frontier has to be an explicit `move`, and a
      ## turn that spends only two of them learns two cells.
      let heading = path.dirs[^1]
      result.add(travelAction(frontier mod LevelW, frontier div LevelW))
      while result.len < 10:
        result.add(moveAction(heading))
      return result

  # 9. search — the authentic move when a level looks closed
  for i in 0 ..< params.searchBurst:
    result.add(simpleAction(vSearch))

proc delverPlan*(sim: SimServer, params: BaselineParams): seq[Action] =
  ## The published plan: the rule ladder above, then the floating-eye trim.
  sim.trimAtEye(delverPlanRaw(sim, params))

proc bumblerPlanRaw(state: var BaselineState, sim: SimServer): seq[Action] =
  ## The reactive control: no BFS, no memory beyond the heading, no hunger
  ## management. It is what answers "did the LLM actually crawl?"
  let li = sim.levelIndex
  if sim.levels[li].terrainAt(sim.cog.x, sim.cog.y) == tStairsDown:
    result.add(simpleAction(vDown))
  elif sim.levels[li].cells[idx(sim.cog.x, sim.cog.y)].item.kind != ikNone:
    result.add(simpleAction(vPickup))
  var x = sim.cog.x
  var y = sim.cog.y
  while result.len < 10:
    var tries = 0
    while tries < 8 and
        not sim.levels[li].memoryTraversable(
          x + DirDx[state.heading], y + DirDy[state.heading]):
      state.heading = (state.heading + 1) mod 8
      inc tries
    result.add(moveAction(state.heading))
    x += DirDx[state.heading]
    y += DirDy[state.heading]

proc bumblerPlan*(state: var BaselineState, sim: SimServer): seq[Action] =
  sim.trimAtEye(bumblerPlanRaw(state, sim))

proc scriptedPlan*(
  state: var BaselineState, sim: SimServer, kind: Baseline,
  params: BaselineParams = DefaultBaselineParams
): seq[Action] =
  case kind
  of blDelver: delverPlan(sim, params)
  of blBumbler: bumblerPlan(state, sim)
