## Monsters: the movement-point clock, the AI of the design note, the exact
## integer combat rolls and the death-cause strings.
##
## Every quantity here is a read of the pure hash `mix64(seed, depth, tick,
## salt)`, never a consumed stream, so nothing the policy does can shift a
## draw out from under a later tick.

import sim_types, dungeon

proc actionsThisTick*(speed, tick: int): int =
  ## A monster acts on tick `t` exactly
  ## `(t * speed) div 12 - ((t - 1) * speed) div 12` times, so speed 12 is one
  ## action a tick, speed 6 every other tick, speed 3 one tick in four and
  ## speed 0 never. NetHack's own movement-point model, integer-exact.
  if speed <= 0 or tick <= 0:
    return 0
  (tick * speed) div 12 - ((tick - 1) * speed) div 12

proc d20*(seed, depth, tick, salt: int): int =
  hashRnd(seed, depth, tick, salt, 20) + 1

const HitThreshold* = 15
  ## The attacker hits iff `d20 + attackBonus + defenderAc >= HitThreshold`.
  ##
  ## DOCUMENTED DIVERGENCE from the design note, which pinned 11. At 11 a
  ## level-0 monster hits a cog in starting leather (AC 7) 85% of the time
  ## and a pack of three jackals kills a 12 hp cog in four dungeon turns: the
  ## scripted baseline died on dungeon level 1 in 30 seeds out of 30, which
  ## makes the depth ladder, the hunger clock and the identification game
  ## unreachable and the whole score a coin flip on the first room. 15 keeps
  ## the note's formula, its armour-class scale and its "lower is better"
  ## reading, and moves a starting cog to 65% incoming / 75-85% outgoing —
  ## which is where NetHack's own early game sits. Measured with
  ## tools/tune_baselines.nim; see docs/PORTING-NETHACK.md.
proc hits*(seed, depth, tick, salt, attackBonus, defenderAc: int): bool =
  d20(seed, depth, tick, salt) + attackBonus + defenderAc >= HitThreshold

proc damageRoll*(seed, depth, tick, salt, die: int): int =
  ## `1 + rnd(die)`; an unarmed blow rolls a die of 2.
  1 + hashRnd(seed, depth, tick, salt, max(1, die))

proc chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc componentMap*(level: Level): seq[int] =
  ## Flood-fill component ids over the CURRENTLY passable cells (a closed
  ## door separates two components until it is opened). One pass per tick,
  ## which is what makes the AI's "same room or corridor component" rule
  ## cheap enough to run for every monster on every tick.
  result = newSeq[int](LevelW * LevelH)
  for i in 0 ..< result.len:
    result[i] = -1
  var next = 0
  for start in 0 ..< result.len:
    if result[start] >= 0:
      continue
    if not passable(level.cells[start].terrain):
      continue
    var queue = @[start]
    result[start] = next
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
        if not inside(nx, ny) or result[idx(nx, ny)] >= 0:
          continue
        if not passable(level.terrainAt(nx, ny)):
          continue
        result[idx(nx, ny)] = next
        queue.add(idx(nx, ny))
    inc next

proc monsterCanEnter*(level: Level, x, y: int): bool =
  ## A monster never enters lava and never opens a door.
  if not inside(x, y):
    return false
  case level.terrainAt(x, y)
  of tFloor, tCorridor, tDoorway, tStairsDown, tStairsUp: true
  else: false

proc chooseMonsterMove*(
  level: Level,
  components: seq[int],
  monsterIndex: int,
  cogX, cogY: int,
  seed, depth, tick, aggroRange: int
): int =
  ## The direction this monster steps, or -1 for "stay put". Rule 1 (attack)
  ## is resolved by the caller, which owns every mutation.
  let monster = level.monsters[monsterIndex]
  let orthogonalOnly = monster.species == spGridBug
  let dirs =
    if orthogonalOnly: @[0, 2, 4, 6]
    else: @[0, 1, 2, 3, 4, 5, 6, 7]

  let
    here = idx(monster.x, monster.y)
    there = idx(cogX, cogY)
  let sameComponent =
    inside(cogX, cogY) and components[here] >= 0 and
    components[here] == components[there]
  if chebyshev(monster.x, monster.y, cogX, cogY) <= aggroRange and
      sameComponent:
    var best = -1
    var bestDistance = chebyshev(monster.x, monster.y, cogX, cogY)
    for dir in dirs:
      let
        nx = monster.x + DirDx[dir]
        ny = monster.y + DirDy[dir]
      if not level.monsterCanEnter(nx, ny):
        continue
      if nx == cogX and ny == cogY:
        continue                       ## it attacks instead of stepping on
      if level.monsterAt(nx, ny) >= 0:
        continue
      let distance = chebyshev(nx, ny, cogX, cogY)
      if distance < bestDistance:
        bestDistance = distance
        best = dir
    return best

  ## Otherwise wander.
  let roll = hashRnd(seed, depth, tick, 900 + monsterIndex, 8)
  let dir = if orthogonalOnly: OrthoDirs[roll mod 4] else: roll
  let
    nx = monster.x + DirDx[dir]
    ny = monster.y + DirDy[dir]
  if not level.monsterCanEnter(nx, ny):
    return -1
  if nx == cogX and ny == cogY:
    return -1
  if level.monsterAt(nx, ny) >= 0:
    return -1
  dir

proc killerName*(species: Species): string =
  SpeciesName[species]
