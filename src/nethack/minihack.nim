## The MiniHack ladder: five small authored levels in a fixed order, each a
## 48x18 template whose details are seeded. Each still has a `>` so the depth
## ladder and the scoring formula are shared with `descend`; each asks one
## clean question.

import sim_types, dungeon

proc mkRoom(level: var Level, index, x, y, w, h: int, lit: bool) =
  level.rooms[index] = Room(x: x, y: y, w: w, h: h, slot: index, used: true,
                            lit: lit)
  level.carveRoom(level.rooms[index], index)

proc digRow(level: var Level, y, x0, x1: int, door: Terrain) =
  let
    lo = min(x0, x1)
    hi = max(x0, x1)
  for x in lo .. hi:
    level.digCell(x, y, door)

proc digCol(level: var Level, x, y0, y1: int, door: Terrain) =
  let
    lo = min(y0, y1)
    hi = max(y0, y1)
  for y in lo .. hi:
    level.digCell(x, y, door)

proc placeItem(level: var Level, x, y: int, item: Item) =
  if inside(x, y) and level.terrainAt(x, y) == tFloor:
    level.cells[idx(x, y)].item = item

proc setStairs(level: var Level, ux, uy, dx, dy: int) =
  level.upX = ux
  level.upY = uy
  level.downX = dx
  level.downY = dy
  level.setTerrain(ux, uy, tStairsUp)
  level.setTerrain(dx, dy, tStairsDown)

proc buildCorridorLevel(level: var Level, seed, depth: int) =
  ## Pure navigation: two rooms at opposite ends joined by a serpentine
  ## corridor with three hash-placed bends, and two grid bugs in it.
  level.mkRoom(0, 3, 7, 9, 4, true)
  level.mkRoom(1, 36, 7, 9, 4, true)
  level.arrivalRoom = 0
  let
    c1 = 15 + hashRnd(seed, depth, 1, 11, 4)
    c2 = 23 + hashRnd(seed, depth, 2, 11, 4)
    c3 = 30 + hashRnd(seed, depth, 3, 11, 4)
    r1 = 2 + hashRnd(seed, depth, 4, 11, 3)
    r2 = 13 + hashRnd(seed, depth, 5, 11, 3)
  level.digRow(9, 12, c1, tDoorway)
  level.digCol(c1, 9, r1, tDoorway)
  level.digRow(r1, c1, c2, tDoorway)
  level.digCol(c2, r1, r2, tDoorway)
  level.digRow(r2, c2, c3, tDoorway)
  level.digCol(c3, r2, 9, tDoorway)
  level.digRow(9, c3, 36, tDoorway)
  level.setStairs(4, 8, 43, 8)
  level.addMonster(spGridBug, c1, r1)
  level.addMonster(spGridBug, c2, r2)

proc buildLavacrossLevel(level: var Level, seed, depth: int) =
  ## Reading the map before moving: one wide hall bisected north-to-south by
  ## a three-cell-wide lava river with a single one-cell floor bridge.
  level.mkRoom(0, 2, 2, 44, 14, true)
  level.arrivalRoom = 0
  let
    river = 20 + hashRnd(seed, depth, 6, 13, 8)
    bridge = 3 + hashRnd(seed, depth, 7, 13, 12)
  for y in 2 .. 15:
    for dx in -1 .. 1:
      if y != bridge:
        level.setTerrain(river + dx, y, tLava)
  level.setStairs(4, bridge, 43, bridge)
  level.placeItem(river - 4, bridge, Item(kind: ikFood, id: 2, count: 1))
  level.placeItem(river + 6, bridge, Item(kind: ikGold, id: 120, count: 1))

proc buildMonsterRoomLevel(level: var Level, seed, depth: int) =
  ## One big lit room with `>` at the far end and four monsters between the
  ## cog and it, plus a mace on the floor.
  level.mkRoom(0, 3, 4, 42, 10, true)
  level.arrivalRoom = 0
  level.setStairs(4, 8, 44, 8)
  let jitter = hashRnd(seed, depth, 8, 17, 3)
  level.addMonster(spJackal, 18, 6 + jitter)
  level.addMonster(spJackal, 20, 9 + jitter)
  level.addMonster(spSewerRat, 28, 6 + jitter)
  level.addMonster(spSewerRat, 30, 10)
  level.placeItem(14, 8, Item(kind: ikWeapon, id: 2, count: 1))
  level.placeItem(24, 5, Item(kind: ikGold, id: 90, count: 1))
  level.placeItem(35, 12, Item(kind: ikFood, id: 1, count: 1))

proc buildLockedVaultLevel(level: var Level, seed, depth: int) =
  ## The skill task: a small vault holding `>` and a large gold pile, its only
  ## door LOCKED. The only way in is `kick`.
  level.mkRoom(0, 3, 6, 16, 6, true)
  level.mkRoom(1, 31, 7, 7, 5, true)
  level.arrivalRoom = 0
  let row = 8 + hashRnd(seed, depth, 9, 19, 3)
  level.digRow(row, 19, 30, tDoorway)
  ## The vault's west wall cell the corridor meets becomes the LOCKED door,
  ## and it is the vault's only opening.
  level.setTerrain(30, row, tDoorLocked)
  level.setStairs(4, 8, 34, 9)
  level.placeItem(33, 8, Item(kind: ikGold, id: 520, count: 1))
  level.placeItem(35, 10, Item(kind: ikGold, id: 240, count: 1))
  level.placeItem(10, 9, Item(kind: ikFood, id: 0, count: 1))
  level.addMonster(spSewerRat, 24, row)

proc buildOracleLevel(level: var Level, seed, depth: int) =
  ## Four rooms and the Oracle in the middle. Descending needs nothing from
  ## her; the `oracle` deed needs a consultation.
  level.mkRoom(0, 3, 2, 9, 4, true)
  level.mkRoom(1, 36, 2, 9, 4, true)
  level.mkRoom(2, 3, 12, 9, 4, true)
  level.mkRoom(3, 36, 12, 9, 4, true)
  level.mkRoom(4, 19, 7, 10, 5, true)
  level.arrivalRoom = 0
  level.digRow(4, 12, 17, tDoorway)
  level.digCol(17, 4, 9, tDoorway)
  level.digRow(9, 17, 18, tDoorway)
  level.digRow(4, 30, 35, tDoorway)
  level.digCol(30, 4, 9, tDoorway)
  level.digRow(9, 29, 30, tDoorway)
  level.digRow(13, 12, 17, tDoorway)
  level.digCol(17, 10, 13, tDoorway)
  level.digRow(10, 17, 18, tDoorway)
  level.digRow(13, 30, 35, tDoorway)
  level.digCol(30, 10, 13, tDoorway)
  level.digRow(10, 29, 30, tDoorway)
  level.setStairs(5, 3, 43, 14)
  level.addMonster(spOracle, 23 + hashRnd(seed, depth, 10, 23, 2), 9)
  level.placeItem(38, 3, Item(kind: ikGold, id: 140, count: 1))
  level.placeItem(5, 13, Item(kind: ikGold, id: 160, count: 1))
  level.placeItem(39, 13, Item(kind: ikFood, id: 0, count: 1))
  level.placeItem(10, 3, Item(kind: ikPotion, id: 0, count: 1))

proc generateMinihackLevel*(name: string, seed, depth: int): Level =
  ## One authored template, seeded. An unknown name falls back to `corridor`.
  result = newLevel(depth)
  result.rooms = newSeq[Room](9)
  case name
  of "lavacross": result.buildLavacrossLevel(seed, depth)
  of "monsterroom": result.buildMonsterRoomLevel(seed, depth)
  of "lockedvault": result.buildLockedVaultLevel(seed, depth)
  of "oracle": result.buildOracleLevel(seed, depth)
  else: result.buildCorridorLevel(seed, depth)
  result.generated = true
