## The dungeon: the 48x18 integer cell grid, the seeded level generator with
## its connectivity postcondition, 8-adjacency in the fixed order
## `e, se, s, sw, w, nw, n, ne`, the corner-cutting rule, the BFS `travel` and
## `delver` both plan on, the lit-room visibility rule and the per-level
## memory merge.
##
## PURE INTEGER. No float, no pixel query, no pixie: the native build and the
## wasm build must agree bit for bit, and that is what makes the replay's
## per-tick hash chain checkable in the browser.

import std/algorithm

import sim_types

type
  Room* = object
    x*, y*, w*, h*: int      ## interior rectangle (walls sit one cell outside)
    slot*: int
    lit*: bool
    used*: bool

  Monster* = object
    species*: Species
    x*, y*: int
    hp*: int
    alive*: bool

  Cell* = object
    terrain*: Terrain
    trapKind*: int           ## -1 = no trap
    trapFound*: bool
    searchCount*: int
    item*: Item
    room*: int               ## room index, or -1

  Level* = object
    generated*: bool
    depth*: int
    cells*: seq[Cell]
    rooms*: seq[Room]
    monsters*: seq[Monster]
    upX*, upY*: int
    downX*, downY*: int
    arrivalRoom*: int
    ## memory (per level, per episode) — what the cog has ever seen
    seen*: seq[bool]
    memTerrain*: seq[Terrain]
    memItem*: seq[Item]
    memTick*: seq[int]

proc idx*(x, y: int): int {.inline.} = y * LevelW + x

proc inside*(x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < LevelW and y < LevelH

proc at*(level: Level, x, y: int): Cell =
  if inside(x, y): level.cells[idx(x, y)] else: Cell(terrain: tRock, trapKind: -1, room: -1)

proc terrainAt*(level: Level, x, y: int): Terrain =
  if inside(x, y): level.cells[idx(x, y)].terrain else: tRock

proc setTerrain*(level: var Level, x, y: int, terrain: Terrain) =
  if inside(x, y):
    level.cells[idx(x, y)].terrain = terrain

proc newLevel*(depth: int): Level =
  result.depth = depth
  result.cells = newSeq[Cell](LevelW * LevelH)
  for i in 0 ..< result.cells.len:
    result.cells[i] = Cell(terrain: tRock, trapKind: -1, room: -1,
                           item: Item(kind: ikNone))
  result.seen = newSeq[bool](LevelW * LevelH)
  result.memTerrain = newSeq[Terrain](LevelW * LevelH)
  result.memItem = newSeq[Item](LevelW * LevelH)
  result.memTick = newSeq[int](LevelW * LevelH)
  for i in 0 ..< result.memTerrain.len:
    result.memTerrain[i] = tRock
    result.memItem[i] = Item(kind: ikNone)
    result.memTick[i] = -1
  result.upX = 1
  result.upY = 1
  result.downX = 1
  result.downY = 1
  result.arrivalRoom = 0

# ---------------------------------------------------------------------------
#  Passability and sight
# ---------------------------------------------------------------------------

proc passable*(terrain: Terrain): bool {.inline.} = TerrainPassable[terrain]

proc blocksSight*(terrain: Terrain): bool {.inline.} =
  not TerrainClearSight[terrain]

proc monsterAt*(level: Level, x, y: int): int =
  ## Index of the live monster on a cell, or -1.
  for i, monster in level.monsters:
    if monster.alive and monster.x == x and monster.y == y:
      return i
  -1

proc cornerCut*(level: Level, x, y, dir: int): bool =
  ## NetHack's own rule: a DIAGONAL step may not cut a doorway or a wall
  ## corner. Illegal when either orthogonal neighbour the step passes is a
  ## wall or a doorway.
  if dir mod 2 == 0:
    return false                     ## e, s, w, n are orthogonal
  let
    ax = x + DirDx[dir]
    ay = y
    bx = x
    by = y + DirDy[dir]
  for (cx, cy) in [(ax, ay), (bx, by)]:
    let terrain = level.terrainAt(cx, cy)
    if terrain in {tWallH, tWallV, tDoorway, tDoorClosed, tDoorLocked,
                   tSecretDoor}:
      return true
  false

proc memoryTraversable*(level: Level, x, y: int): bool =
  ## What `travel` and `delver` may plan through: only REMEMBERED passable
  ## terrain. Never an unseen cell, never lava, never a closed or locked
  ## door. The driver plans on what is known, not on hope.
  if not inside(x, y):
    return false
  if not level.seen[idx(x, y)]:
    return false
  case level.memTerrain[idx(x, y)]
  of tFloor, tCorridor, tDoorway, tStairsDown, tStairsUp: true
  else: false

# ---------------------------------------------------------------------------
#  BFS
# ---------------------------------------------------------------------------

type PathResult* = object
  reachable*: bool
  dirs*: seq[int]            ## the move directions, in order

proc bfsFrom*(
  level: Level,
  startX, startY: int,
  blocked: seq[bool] = @[]
): tuple[dist: seq[int], cameFrom: seq[int]] =
  ## Breadth-first over remembered traversable cells, neighbours visited in
  ## the fixed order, so the tree — and therefore every path read out of it —
  ## is unique for a given remembered map.
  var dist = newSeq[int](LevelW * LevelH)
  var cameFrom = newSeq[int](LevelW * LevelH)
  for i in 0 ..< dist.len:
    dist[i] = -1
    cameFrom[i] = -1
  if not inside(startX, startY):
    return (dist, cameFrom)
  var queue = @[idx(startX, startY)]
  dist[idx(startX, startY)] = 0
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    let
      cx = node mod LevelW
      cy = node div LevelW
    for dir in 0 ..< 8:
      let
        nx = cx + DirDx[dir]
        ny = cy + DirDy[dir]
      if not inside(nx, ny):
        continue
      if dist[idx(nx, ny)] >= 0:
        continue
      if not level.memoryTraversable(nx, ny):
        continue
      if level.cornerCut(cx, cy, dir):
        continue
      if blocked.len == dist.len and blocked[idx(nx, ny)]:
        continue
      dist[idx(nx, ny)] = dist[node] + 1
      cameFrom[idx(nx, ny)] = dir
      queue.add(idx(nx, ny))
  (dist, cameFrom)

proc pathTo*(
  level: Level,
  startX, startY, targetX, targetY: int,
  cap: int,
  blocked: seq[bool] = @[]
): PathResult =
  ## The `travel` macro's expansion. If the target is traversable the path
  ## ends ON it; if it is not but is 8-adjacent to a reached cell the path
  ## ends on the nearest such cell (so `travel` to a closed door leaves the
  ## cog next to it, ready to open or kick it); otherwise the macro yields
  ## ZERO primitives and counts as `unreachable`.
  result.reachable = false
  if not inside(targetX, targetY):
    return
  let scan = level.bfsFrom(startX, startY, blocked)
  var goal = -1
  if level.memoryTraversable(targetX, targetY) and
      scan.dist[idx(targetX, targetY)] >= 0:
    goal = idx(targetX, targetY)
  else:
    var best = -1
    for dir in 0 ..< 8:
      let
        nx = targetX + DirDx[dir]
        ny = targetY + DirDy[dir]
      if not inside(nx, ny):
        continue
      let d = scan.dist[idx(nx, ny)]
      if d < 0:
        continue
      if best < 0 or d < scan.dist[best] or
          (d == scan.dist[best] and idx(nx, ny) < best):
        best = idx(nx, ny)
    goal = best
  if goal < 0:
    return
  if goal == idx(startX, startY):
    result.reachable = true
    return
  var steps: seq[int] = @[]
  var node = goal
  var guard = 0
  while node != idx(startX, startY) and guard < LevelW * LevelH:
    inc guard
    let dir = scan.cameFrom[node]
    if dir < 0:
      return
    steps.add(dir)
    let
      cx = node mod LevelW
      cy = node div LevelW
    node = idx(cx - DirDx[dir], cy - DirDy[dir])
  if node != idx(startX, startY):
    return
  reverse(steps)
  if steps.len > cap:
    steps.setLen(cap)
  result.reachable = true
  result.dirs = steps

# ---------------------------------------------------------------------------
#  Generator
# ---------------------------------------------------------------------------

proc slotBounds(slot: int): tuple[x0, y0, x1, y1: int] =
  let
    col = slot mod 3
    row = slot div 3
  var
    x0 = col * 16
    y0 = row * 6
    x1 = x0 + 15
    y1 = y0 + 5
  ## The whole border ring is solid rock, so a room's wall ring must stay
  ## strictly inside it.
  if x0 < 1: x0 = 1
  if y0 < 1: y0 = 1
  if x1 > LevelW - 2: x1 = LevelW - 2
  if y1 > LevelH - 2: y1 = LevelH - 2
  (x0, y0, x1, y1)

proc carveRoom*(level: var Level, room: Room, index: int) =
  for y in room.y - 1 .. room.y + room.h:
    for x in room.x - 1 .. room.x + room.w:
      if not inside(x, y):
        continue
      let interior = x >= room.x and x < room.x + room.w and
        y >= room.y and y < room.y + room.h
      if interior:
        level.cells[idx(x, y)].terrain = tFloor
        level.cells[idx(x, y)].room = index
      elif level.cells[idx(x, y)].terrain == tRock:
        level.cells[idx(x, y)].terrain =
          if y == room.y - 1 or y == room.y + room.h: tWallH else: tWallV

proc digCell*(level: var Level, x, y: int, doorKind: Terrain) =
  if not inside(x, y):
    return
  case level.cells[idx(x, y)].terrain
  of tRock:
    level.cells[idx(x, y)].terrain = tCorridor
  of tWallH, tWallV:
    level.cells[idx(x, y)].terrain = doorKind
  else:
    discard

proc doorKindFor(seed, depth, salt: int): Terrain =
  let roll = hashRnd(seed, depth, salt, 71, 100)
  if roll < 55: tDoorway
  elif roll < 85: tDoorClosed
  elif roll < 95: tDoorLocked
  else: tSecretDoor

proc digCorridor(
  level: var Level, seed, depth, edge: int, ax, ay, bx, by: int
) =
  ## One L-shaped corridor between two room centres, with the elbow on a
  ## hash-chosen axis. Every cell on the path ends passable-or-door, which is
  ## what makes the connectivity postcondition hold by construction.
  let horizontalFirst = hashRnd(seed, depth, edge, 41, 2) == 0
  let door = doorKindFor(seed, depth, edge)
  var
    x = ax
    y = ay
  if horizontalFirst:
    while x != bx:
      x += (if bx > x: 1 else: -1)
      level.digCell(x, y, door)
    while y != by:
      y += (if by > y: 1 else: -1)
      level.digCell(x, y, door)
  else:
    while y != by:
      y += (if by > y: 1 else: -1)
      level.digCell(x, y, door)
    while x != bx:
      x += (if bx > x: 1 else: -1)
      level.digCell(x, y, door)

proc connectivityPassable(level: Level, x, y: int): bool =
  ## The postcondition's rule: locked doors and SECRET doors count as
  ## passable, because a cog can kick or search its way through them.
  if not inside(x, y):
    return false
  case level.terrainAt(x, y)
  of tFloor, tCorridor, tDoorway, tDoorClosed, tDoorLocked, tSecretDoor,
     tStairsDown, tStairsUp: true
  else: false

proc reachableMask*(
  level: Level, startX, startY: int, treatSecretAsRock: bool
): seq[bool] =
  result = newSeq[bool](LevelW * LevelH)
  if not inside(startX, startY):
    return
  proc ok(x, y: int): bool =
    if treatSecretAsRock and level.terrainAt(x, y) == tSecretDoor:
      return false
    level.connectivityPassable(x, y)
  if not ok(startX, startY):
    return
  var queue = @[idx(startX, startY)]
  result[idx(startX, startY)] = true
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    let
      cx = node mod LevelW
      cy = node div LevelW
    for dir in 0 ..< 8:
      let
        nx = cx + DirDx[dir]
        ny = cy + DirDy[dir]
      if not inside(nx, ny) or result[idx(nx, ny)]:
        continue
      if not ok(nx, ny):
        continue
      result[idx(nx, ny)] = true
      queue.add(idx(nx, ny))

proc levelConnected*(level: Level, treatSecretAsRock = false): bool =
  ## `<` and `>` mutually reachable, and every placed item reachable from `<`.
  let mask = level.reachableMask(level.upX, level.upY, treatSecretAsRock)
  if not mask[idx(level.downX, level.downY)]:
    return false
  for y in 0 ..< LevelH:
    for x in 0 ..< LevelW:
      if level.cells[idx(x, y)].item.kind != ikNone and not mask[idx(x, y)]:
        return false
  true

proc freeFloorCells(level: Level): seq[int] =
  for y in 0 ..< LevelH:
    for x in 0 ..< LevelW:
      let cell = level.cells[idx(x, y)]
      if cell.terrain == tFloor and cell.item.kind == ikNone and
          cell.trapKind < 0:
        result.add(idx(x, y))

proc pickCell(cells: seq[int], seed, depth, salt: int): int =
  if cells.len == 0: -1 else: cells[hashRnd(seed, depth, salt, 13, cells.len)]

proc placeStairs(level: var Level, seed, depth: int, hops: seq[int]) =
  var upRoom = -1
  for i, room in level.rooms:
    if room.used:
      upRoom = i
      break
  if upRoom < 0:
    return
  var downRoom = upRoom
  var bestHops = -1
  for i, room in level.rooms:
    if not room.used or i == upRoom:
      continue
    if hops[i] > bestHops:
      bestHops = hops[i]
      downRoom = i
  if downRoom == upRoom:
    for i, room in level.rooms:
      if room.used and i != upRoom:
        downRoom = i
        break
  level.arrivalRoom = upRoom
  let
    up = level.rooms[upRoom]
    down = level.rooms[downRoom]
    ux = up.x + hashRnd(seed, depth, 201, 5, up.w)
    uy = up.y + hashRnd(seed, depth, 202, 5, up.h)
    dx = down.x + hashRnd(seed, depth, 203, 5, down.w)
    dy = down.y + hashRnd(seed, depth, 204, 5, down.h)
  level.upX = ux
  level.upY = uy
  level.downX = dx
  level.downY = dy
  level.cells[idx(ux, uy)].terrain = tStairsUp
  level.cells[idx(dx, dy)].terrain = tStairsDown

proc monsterSpeciesFor(depth, roll: int): Species =
  var pool: seq[Species] = @[]
  for species in Species:
    if species == spOracle:
      continue
    if depth >= SpeciesMinDepth[species] and depth <= SpeciesMaxDepth[species]:
      pool.add(species)
  if pool.len == 0:
    return spSewerRat
  pool[roll mod pool.len]

proc addMonster*(level: var Level, species: Species, x, y: int) =
  level.monsters.add(Monster(
    species: species, x: x, y: y, hp: SpeciesHp[species], alive: true))

proc placeContents(level: var Level, seed, depth: int) =
  ## Gold, exactly one food item, a few more items, traps and monsters — all
  ## on hash-chosen free floor cells, never on a staircase, never twice on
  ## one cell, and never a monster in the arrival room.
  var salt = 300
  let goldPiles = 2 + (depth mod 3)
  for i in 0 ..< goldPiles:
    let cells = level.freeFloorCells()
    let cell = pickCell(cells, seed, depth, salt + i)
    if cell >= 0:
      level.cells[cell].item = Item(
        kind: ikGold, count: 1,
        id: 10 + hashRnd(seed, depth, salt + i, 17, 20 * depth + 20))
  salt = 400
  block food:
    let cells = level.freeFloorCells()
    let cell = pickCell(cells, seed, depth, salt)
    if cell >= 0:
      level.cells[cell].item = Item(
        kind: ikFood, count: 1,
        id: hashRnd(seed, depth, salt, 19, FoodNames.len))
  salt = 500
  let extras = 1 + (depth mod 3)
  for i in 0 ..< extras:
    let cells = level.freeFloorCells()
    let cell = pickCell(cells, seed, depth, salt + i)
    if cell < 0:
      continue
    case hashRnd(seed, depth, salt + i, 23, 3)
    of 0:
      level.cells[cell].item = Item(
        kind: ikPotion, count: 1,
        id: hashRnd(seed, depth, salt + i, 29, PotionNames.len))
    of 1:
      level.cells[cell].item = Item(
        kind: ikWeapon, count: 1,
        id: hashRnd(seed, depth, salt + i, 31, WeaponNames.len))
    else:
      level.cells[cell].item = Item(
        kind: ikArmour, count: 1,
        id: hashRnd(seed, depth, salt + i, 37, ArmourNames.len))
  salt = 600
  let trapCount = (depth + 1) div 2
  for i in 0 ..< trapCount:
    let cells = level.freeFloorCells()
    let cell = pickCell(cells, seed, depth, salt + i)
    if cell >= 0:
      level.cells[cell].trapKind = hashRnd(seed, depth, salt + i, 43, 4)
      level.cells[cell].trapFound = false
  salt = 700
  ## DOCUMENTED DIVERGENCE from the design note's `min(12, 3 + depth)`: with
  ## packs on top of it, dungeon level 1 could open with three jackals on a
  ## twelve-hit-point cog, which killed the scripted baseline on level 1 in
  ## every one of thirty measured seeds. `min(10, 2 + depth)` keeps the
  ## note's shape and its depth ramp and leaves the first level survivable.
  let monsterCount = min(MaxMonstersPerLevel - 2, 2 + depth)
  var placed = 0
  var attempt = 0
  while placed < monsterCount and attempt < 200:
    inc attempt
    var candidates: seq[int] = @[]
    for y in 0 ..< LevelH:
      for x in 0 ..< LevelW:
        let cell = level.cells[idx(x, y)]
        if cell.terrain != tFloor:
          continue
        if cell.room == level.arrivalRoom:
          continue
        if level.monsterAt(x, y) >= 0:
          continue
        candidates.add(idx(x, y))
    if candidates.len == 0:
      break
    let cell = candidates[hashRnd(seed, depth, salt + attempt, 47, candidates.len)]
    let species = monsterSpeciesFor(
      depth, hashRnd(seed, depth, salt + attempt, 53, 64))
    level.addMonster(species, cell mod LevelW, cell div LevelW)
    inc placed
    if species == spJackal and depth >= 2:
      ## Jackals spawn in packs of three; hill orcs in pairs.
      for extra in 0 ..< 2:
        if placed >= monsterCount:
          break
        for dir in 0 ..< 8:
          let
            nx = cell mod LevelW + DirDx[dir]
            ny = cell div LevelW + DirDy[dir]
          if inside(nx, ny) and level.terrainAt(nx, ny) == tFloor and
              level.monsterAt(nx, ny) < 0 and
              level.cells[idx(nx, ny)].room != level.arrivalRoom:
            level.addMonster(spJackal, nx, ny)
            inc placed
            break
    elif species == spHillOrc and depth >= 2 and placed < monsterCount:
      for dir in 0 ..< 8:
        let
          nx = cell mod LevelW + DirDx[dir]
          ny = cell div LevelW + DirDy[dir]
        if inside(nx, ny) and level.terrainAt(nx, ny) == tFloor and
            level.monsterAt(nx, ny) < 0 and
            level.cells[idx(nx, ny)].room != level.arrivalRoom:
          level.addMonster(spHillOrc, nx, ny)
          inc placed
          break

proc downgradeUnsafeSecretDoors(level: var Level) =
  ## A secret door is only created when the level stays connected WITHOUT it.
  ## Any conversion that would make the secret door the only route is
  ## downgraded to a closed door; locked doors are exempt (always kickable).
  ## The postcondition is about the WHOLE set, not one door at a time: two
  ## secret doors can each be individually removable and still be the level's
  ## only two routes between the same pair of components. Downgrade one at a
  ## time until the level is connected with EVERY remaining secret door
  ## treated as rock. This terminates: each pass removes one secret door.
  var guard = 0
  while guard < LevelW * LevelH:
    inc guard
    if level.levelConnected(treatSecretAsRock = true):
      break
    var victim = -1
    for i in 0 ..< level.cells.len:
      if level.cells[i].terrain == tSecretDoor:
        victim = i
        break
    if victim < 0:
      break
    level.cells[victim].terrain = tDoorClosed

proc generateLevel*(seed, depth: int, oracleLevel: bool): Level =
  ## The whole `descend` generator, a pure function of (seed, depth).
  result = newLevel(depth)
  let roomCount = 6 + hashRnd(seed, depth, 1, 3, 3)

  ## The nine slot indices ordered by a hash key, ties by slot index.
  var order: seq[int] = @[]
  for slot in 0 ..< 9:
    order.add(slot)
  order.sort(proc (a, b: int): int =
    let
      ka = mix64(seed, depth, 100 + a, 0)
      kb = mix64(seed, depth, 100 + b, 0)
    if ka < kb: -1
    elif ka > kb: 1
    elif a < b: -1
    elif a > b: 1
    else: 0)

  var used = newSeq[bool](9)
  for i in 0 ..< min(roomCount, 9):
    used[order[i]] = true
  if oracleLevel:
    used[4] = true                  ## the Oracle lives in the centre slot

  result.rooms = newSeq[Room](9)
  for slot in 0 ..< 9:
    let bounds = slotBounds(slot)
    let
      availW = bounds.x1 - bounds.x0 + 1
      availH = bounds.y1 - bounds.y0 + 1
    var w = 4 + hashRnd(seed, depth, slot, 61, 9)
    var h = 3 + hashRnd(seed, depth, slot, 67, 2)
    if w + 2 > availW: w = availW - 2
    if h + 2 > availH: h = availH - 2
    if w < 3: w = 3
    if h < 2: h = 2
    let
      spanX = max(0, availW - (w + 2))
      spanY = max(0, availH - (h + 2))
      ox = bounds.x0 + 1 + (if spanX > 0: hashRnd(seed, depth, slot, 73, spanX + 1) else: 0)
      oy = bounds.y0 + 1 + (if spanY > 0: hashRnd(seed, depth, slot, 79, spanY + 1) else: 0)
    result.rooms[slot] = Room(
      x: ox, y: oy, w: w, h: h, slot: slot, used: used[slot],
      lit: hashRnd(seed, depth, slot, 7, 100) < max(20, 100 - 10 * depth))
    if used[slot]:
      result.carveRoom(result.rooms[slot], slot)

  if oracleLevel:
    result.rooms[4].lit = true

  ## Prim over the used slots: 4-adjacency on the 3x3 grid is preferred
  ## (weight 0), any other pair is a fallback edge (weight = grid Manhattan
  ## distance), so the spanning tree is ALWAYS connected even when the used
  ## slots do not induce a connected subgraph.
  var usedSlots: seq[int] = @[]
  for slot in 0 ..< 9:
    if used[slot]:
      usedSlots.add(slot)
  var inTree = newSeq[bool](9)
  var hops = newSeq[int](9)
  for i in 0 ..< 9:
    hops[i] = -1
  if usedSlots.len > 0:
    inTree[usedSlots[0]] = true
    hops[usedSlots[0]] = 0
    var edge = 0
    while true:
      var bestA = -1
      var bestB = -1
      var bestWeight = 0
      for a in usedSlots:
        if not inTree[a]:
          continue
        for b in usedSlots:
          if inTree[b]:
            continue
          let weight =
            abs(a mod 3 - b mod 3) + abs(a div 3 - b div 3)
          if bestB < 0 or weight < bestWeight or
              (weight == bestWeight and (a < bestA or (a == bestA and b < bestB))):
            bestA = a
            bestB = b
            bestWeight = weight
      if bestB < 0:
        break
      inTree[bestB] = true
      hops[bestB] = hops[bestA] + 1
      inc edge
      result.digCorridor(
        seed, depth, edge,
        result.rooms[bestA].x + result.rooms[bestA].w div 2,
        result.rooms[bestA].y + result.rooms[bestA].h div 2,
        result.rooms[bestB].x + result.rooms[bestB].w div 2,
        result.rooms[bestB].y + result.rooms[bestB].h div 2)
    ## plus rnd(2) extra edges, so a level is not always a bare tree
    let extra = hashRnd(seed, depth, 2, 83, 2)
    for i in 0 ..< extra:
      if usedSlots.len < 2:
        break
      let
        a = usedSlots[hashRnd(seed, depth, 3 + i, 89, usedSlots.len)]
        b = usedSlots[hashRnd(seed, depth, 5 + i, 97, usedSlots.len)]
      if a == b:
        continue
      result.digCorridor(
        seed, depth, 100 + i,
        result.rooms[a].x + result.rooms[a].w div 2,
        result.rooms[a].y + result.rooms[a].h div 2,
        result.rooms[b].x + result.rooms[b].w div 2,
        result.rooms[b].y + result.rooms[b].h div 2)

  result.placeStairs(seed, depth, hops)
  result.placeContents(seed, depth)
  if oracleLevel:
    let room = result.rooms[4]
    let
      ox = room.x + room.w div 2
      oy = room.y + room.h div 2
    var kept: seq[Monster] = @[]
    for monster in result.monsters:
      if result.cells[idx(monster.x, monster.y)].room != 4:
        kept.add(monster)
    result.monsters = kept
    if result.terrainAt(ox, oy) == tFloor:
      result.addMonster(spOracle, ox, oy)
  result.downgradeUnsafeSecretDoors()
  result.generated = true

# ---------------------------------------------------------------------------
#  Visibility and memory
# ---------------------------------------------------------------------------

proc roomOf*(level: Level, x, y: int): int =
  if inside(x, y): level.cells[idx(x, y)].room else: -1

proc visibleSet*(level: Level, cogX, cogY: int): seq[bool] =
  ## NetHack's lighting model, restated as integer code, and the ONLY
  ## visibility rule in this game:
  ##   in a LIT room  -> the whole room, its wall ring and its doors
  ##   otherwise      -> the cog's own cell and its eight neighbours
  result = newSeq[bool](LevelW * LevelH)
  let room = level.roomOf(cogX, cogY)
  if room >= 0 and room < level.rooms.len and level.rooms[room].lit and
      level.rooms[room].used:
    let r = level.rooms[room]
    for y in r.y - 1 .. r.y + r.h:
      for x in r.x - 1 .. r.x + r.w:
        if inside(x, y):
          result[idx(x, y)] = true
  for dir in -1 .. 7:
    let
      nx = cogX + (if dir < 0: 0 else: DirDx[dir])
      ny = cogY + (if dir < 0: 0 else: DirDy[dir])
    if inside(nx, ny):
      result[idx(nx, ny)] = true

proc mergeMemory*(level: var Level, visible: seq[bool], tick: int) =
  ## Terrain stays in memory forever, stamped with the tick it was last seen.
  ## Items are remembered where they were last seen and CLEARED when the cell
  ## is visible and the item is gone. Monsters are never remembered.
  for i in 0 ..< visible.len:
    if not visible[i]:
      continue
    level.seen[i] = true
    level.memTick[i] = tick
    level.memTerrain[i] =
      if level.cells[i].terrain == tSecretDoor: tRock
      else: level.cells[i].terrain
    level.memItem[i] = level.cells[i].item

proc glyphAt*(
  level: Level, x, y: int, visible: seq[bool],
  potionKnown: openArray[bool], potionAppearance: openArray[int]
): char =
  ## One cell of the ASCII map the cog reads.
  let i = idx(x, y)
  if visible[i]:
    let monster = level.monsterAt(x, y)
    if monster >= 0:
      return SpeciesGlyph[level.monsters[monster].species]
  if not level.seen[i]:
    return ' '
  if visible[i]:
    if level.cells[i].item.kind != ikNone:
      return ItemGlyph[level.cells[i].item.kind]
    if level.cells[i].trapKind >= 0 and level.cells[i].trapFound:
      return '^'
    if level.cells[i].terrain == tSecretDoor:
      return ' '
    return TerrainGlyph[level.cells[i].terrain]
  if level.memItem[i].kind != ikNone:
    return ItemGlyph[level.memItem[i].kind]
  if level.cells[i].trapKind >= 0 and level.cells[i].trapFound:
    return '^'
  TerrainGlyph[level.memTerrain[i]]
