## The driver: directive -> per-tick actuation. It is the ONLY producer of
## primitives and it contains no randomness.
##
## Forked from `coworld-ctf`'s `src/ctf/control.nim`, retargeted from pixel
## steering to a primitive queue. It never invents an action the reply schema
## does not express, and it makes no promise about a cell the cog has never
## seen — which is why crossing into the dark costs an explicit `move` from
## the policy.

import std/json

import sim

type
  ExpandedPlan* = object
    queue*: seq[Primitive]
    truncated*: bool
    unreachable*: int

proc expandPlan*(sim: SimServer, actions: seq[Action]): ExpandedPlan =
  ## Macros expand against the REMEMBERED map as of turn start. `travel`
  ## becomes the BFS path's move primitives, bounded by `macroPrimitiveCap`;
  ## a target that is not reachable through remembered passable cells yields
  ## ZERO primitives and counts as `unreachable`. The whole queue is then
  ## truncated to `turnTicks`.
  let li = sim.levelIndex
  let blocked = sim.monsterBlockMask()
  var x = sim.cog.x
  var y = sim.cog.y
  for action in actions:
    if action.verb == vTravel:
      let path = sim.levels[li].pathTo(
        x, y, action.x, action.y, sim.config.macroPrimitiveCap, blocked)
      if not path.reachable or path.dirs.len == 0:
        inc result.unreachable
        continue
      for dir in path.dirs:
        result.queue.add(Primitive(verb: vMove, dir: dir, item: -1))
        x += DirDx[dir]
        y += DirDy[dir]
    else:
      result.queue.add(Primitive(
        verb: action.verb, dir: action.dir, item: action.item))
      if action.verb == vMove:
        x += DirDx[action.dir]
        y += DirDy[action.dir]
  if result.queue.len > sim.config.turnTicks:
    result.queue.setLen(sim.config.turnTicks)
    result.truncated = true

type TurnRunner* = object
  ## The turn's tick budget, shared by the live server (which runs a whole
  ## turn at once in fastMode) and the replay player (which runs ONE tick per
  ## presentation frame). One implementation, so live and replay can never
  ## produce different tick sequences.
  ticksLeft*: int
  beforeDepth*: int
  active*: bool
  emptyPlan*: bool
    ## A reply with no usable actions spends the WHOLE turn waiting (the
    ## reply-schema row: "absent or empty = the turn is forty wait ticks"),
    ## so an unusable reply always costs the clock. A turn whose queue
    ## EMPTIES, by contrast, ends there: the hunger clock runs on dungeon
    ## turns, and charging 36 idle turns for a four-step plan would make the
    ## interface unplayable rather than demanding.
  ticksRun*: int

proc beginTurn*(sim: var SimServer, actions: seq[Action], dropped: int): TurnRunner =
  ## Expand, install the queue, and open the turn. Nothing carries over from
  ## the previous turn.
  if sim.ended:
    return
  sim.messages.setLen(0)
  let plan = sim.expandPlan(actions)
  sim.queue = plan.queue
  sim.lastTruncated = plan.truncated
  sim.lastUnreachable = plan.unreachable
  sim.lastDropped = dropped
  sim.actionsDropped += dropped
  sim.macrosUnreachable += plan.unreachable
  sim.lastExecuted = @[]
  inc sim.turnsPlayed
  let li = sim.levelIndex
  if li < sim.levelTurns.len:
    inc sim.levelTurns[li]
  sim.emit("turn", %*{"n": sim.turnsPlayed, "depth": sim.cog.depth})
  result = TurnRunner(ticksLeft: sim.config.turnTicks,
                      beforeDepth: sim.cog.depth, active: true,
                      emptyPlan: plan.queue.len == 0)

proc turnDone*(sim: SimServer, runner: TurnRunner): bool =
  if not runner.active or runner.ticksLeft <= 0 or sim.ended or
      sim.cog.depth != runner.beforeDepth:
    return true
  not runner.emptyPlan and runner.ticksRun > 0 and sim.queue.len == 0 and
    sim.cog.paralysed <= 0 and sim.cog.trapped <= 0

proc stepTurn*(sim: var SimServer, runner: var TurnRunner) =
  ## One dungeon turn inside the current command turn.
  if sim.turnDone(runner):
    runner.active = false
    return
  dec runner.ticksLeft
  inc runner.ticksRun
  sim.stepTick()
  if sim.executedVerb.len > 0 and sim.lastExecuted.len < 40:
    sim.lastExecuted.add(sim.executedVerb)
  if sim.turnDone(runner):
    runner.active = false

proc endTurn*(sim: var SimServer) =
  sim.queue.setLen(0)
  if not sim.ended and sim.turnsPlayed >= sim.config.maxTurns:
    sim.endRun(erTurnCap, codNone, "")

proc playTurn*(sim: var SimServer, actions: seq[Action], dropped: int) =
  ## One command turn, run to completion — the live server's path.
  if sim.ended:
    return
  var runner = sim.beginTurn(actions, dropped)
  while not sim.turnDone(runner):
    sim.stepTurn(runner)
  sim.endTurn()
