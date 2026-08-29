## Shared test helpers: record one real episode to a replay file exactly the
## way `src/nethack/server.nim` does, so the replay tests exercise the writer
## the server actually uses rather than a second copy of it.

import std/[json, os]

import nethack/[sim, driver, baselines, directives, decide, replays]

type RecordedEpisode* = object
  path*: string
  sim*: SimServer
  results*: string
  turns*: int

proc recordEpisode*(
  path: string,
  seed: int,
  maxTurns = 0,
  ladder: seq[string] = @[],
  forceStop = "",
  forceStopTurn = 0
): RecordedEpisode =
  var config = defaultGameConfig()
  config.seed = seed
  if ladder.len > 0:
    config.levelLadder = ladder
    config.dungeonLevels = ladder.len
    config.parDepth = 3
  var s = initSimServer(config)
  s.phase = Playing
  s.policyKind = "scripted"
  s.playerName = "delver"
  var writer = openReplayWriter(path, config.configJson())
  writer.writeJoin(tickTime(0), 0, s.playerName, 0, "")
  writer.writeChat(tickTime(0), 0,
    registerRecord(0, "Alpha", "delver", "scripted", "delver"))
  var turn = 0
  let cap = if maxTurns > 0: maxTurns else: config.maxTurns
  while not s.ended and turn < cap:
    inc turn
    if forceStop.len > 0 and turn == forceStopTurn:
      writer.writeChat(tickTime(s.tickCount), 0,
                       stopRecord(s.tickCount, forceStop))
      case forceStop
      of "wallClock": s.endRun(erWallClock, codNone, "")
      of "fault": s.endRun(erFault, codNone, "")
      else: discard
      break
    let actions = delverPlan(s, DefaultBaselineParams)
    var reply = ParsedReply(actions: actions, source: dsScripted)
    let observation = s.observationJson(turn, includeMap = false)
    var runner = s.beginTurn(reply.actions, reply.dropped)
    while not s.turnDone(runner):
      s.stepTurn(runner)
      writer.writeHash(tickTime(s.tickCount), s.gameHash())
    s.endTurn()
    writer.writeChat(tickTime(s.tickCount), 0,
      boundedDirectiveRecord(reply, turn, s.cog.depth, 0, "Alpha",
                             s.lastExecuted, s.lastTruncated, s.lastDropped,
                             s.lastUnreachable, observation))
    s.events.setLen(0)
  if not s.ended:
    s.endRun(erTurnCap, codNone, "")
  writer.writeChat(tickTime(s.tickCount), 0, resultRecord(s))
  writer.closeReplayWriter()
  result.path = path
  result.sim = s
  result.results = s.runResultsJson()
  result.turns = turn

proc tempReplayPath*(name: string): string =
  result = getTempDir() / ("nethack-test-" & name & "-" &
    $getCurrentProcessId() & ".replay")
