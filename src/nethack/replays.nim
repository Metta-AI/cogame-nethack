## The binary `COWLDNET` replay: the starter's codec with this game's magic,
## plus the player that re-simulates an episode from its recorded PLANS and
## checks the per-tick hash chain.
##
## This game's entire input log is the per-turn accepted action list, carried
## in the `directive` chat records — so the bytes are self-sufficient: the
## dungeon generator, the monster table, the item tables and the message
## strings are CODE, compiled into both the binary and the wasm module, and
## the replay carries the seed, the variant and every rule constant. The
## viewer therefore reconstructs every level, every monster, every item and
## every message line with no fetch.

import std/[json, strutils]

import bitworld/replays as replayCodec

import sim, driver, directives

export replayCodec

const
  NethackReplayMagic* = "COWLDNET"
  NethackReplayFormatVersion* = 1'u16
  NethackReplaySpec* = ReplaySpec(
    magic: NethackReplayMagic,
    formatVersion: NethackReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )
  ReplayEndHoldSeconds* = 3
  MinLullTicks* = 60
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64

type
  TurnPlan* = object
    turn*: int
    actions*: seq[Action]
    dropped*: int
    say*: string
    source*: string

  ReplayPlayer* = object
    data*: ReplayData
    plans*: seq[TurnPlan]
    records*: seq[JsonNode]
    results*: JsonNode
    stopTick*: int
    stopRule*: string

    turnIndex*: int
    runner*: TurnRunner
    hashIndex*: int
    hashMismatchTick*: int
    hashValidationFailed*: bool
    mismatchQuit*: bool

    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    startTick*: int
    maxTick*: int
    endHoldFrames*: int
    tickAccumulator*: int

    depthSeries*: seq[seq[int]]
    beatEvents*: JsonNode
    lullSpans*: seq[array[2, int]]
    scanDone*: bool

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, NethackReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, NethackReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, NethackReplaySpec)

proc decodeRecords*(data: ReplayData): seq[JsonNode] =
  ## The chat stream, decoded in order. Anything that is not a JSON object is
  ## dropped: a control record is always one.
  for chat in data.chats:
    if chat.message.len == 0 or chat.message[0] != '{':
      continue
    try:
      let node = parseJson(chat.message)
      if node.kind == JObject:
        result.add(node)
    except CatchableError:
      discard

proc planFor*(record: JsonNode): TurnPlan =
  result.turn = record{"turn"}.getInt()
  result.actions = parseActionsRecord(record{"actions"})
  result.dropped = record{"dropped"}.getInt()
  result.say = record{"say"}.getStr()
  result.source = record{"source"}.getStr()

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.records = decodeRecords(data)
  result.beatEvents = newJArray()
  result.hashMismatchTick = -1
  result.stopTick = -1
  result.speedIndex = 0
  result.playing = true
  result.looping = true
  result.skipLulls = true
  result.startTick = 0
  for record in result.records:
    case record{"k"}.getStr()
    of "directive": result.plans.add(planFor(record))
    of "stop":
      result.stopTick = record{"tick"}.getInt()
      result.stopRule = record{"endRule"}.getStr()
    of "result": result.results = record{"results"}
    else: discard
  result.maxTick = data.hashes.len

proc replayMaxTick*(replay: ReplayPlayer): int = max(1, replay.maxTick)
proc replayStartTick*(replay: ReplayPlayer): int = max(0, replay.startTick)
proc replaySpeed*(replay: ReplayPlayer): int =
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.len - 1)]

proc applyStop(replay: ReplayPlayer, sim: var SimServer) =
  ## The wall-clock / fault stop is a LOAD-BEARING record, not an inference:
  ## a wall-clock fact cannot be re-derived from sim state, so it is applied
  ## by this one proc on record and on playback alike.
  if replay.stopTick < 0 or sim.tickCount < replay.stopTick or sim.ended:
    return
  case replay.stopRule
  of "wallClock": sim.endRun(erWallClock, codNone, "")
  of "fault": sim.endRun(erFault, codNone, "")
  else: discard

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## One dungeon tick of playback, driven by the recorded plans through the
  ## SAME driver the live server used.
  if sim.ended:
    return
  if sim.turnDone(replay.runner):
    if replay.runner.active:
      sim.endTurn()
      replay.runner.active = false
    if sim.ended:
      return
    if replay.turnIndex >= replay.plans.len:
      sim.endRun(erTurnCap, codNone, "")
      return
    let plan = replay.plans[replay.turnIndex]
    inc replay.turnIndex
    replay.runner = sim.beginTurn(plan.actions, plan.dropped)
    sim.lastSay = plan.say
  sim.stepTurn(replay.runner)
  replay.applyStop(sim)
  if replay.hashIndex < replay.data.hashes.len:
    let recorded = replay.data.hashes[replay.hashIndex].hash
    inc replay.hashIndex
    if recorded != sim.gameHash() and not replay.hashValidationFailed:
      replay.hashValidationFailed = true
      replay.hashMismatchTick = sim.tickCount
      if replay.mismatchQuit:
        raise newException(NethackError,
          "replay hash mismatch at tick " & $sim.tickCount)

proc checkReplayHash*(replay: ReplayPlayer): int = replay.hashMismatchTick

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer,
                 config: GameConfig, tick: int) =
  ## Seeks by RE-SIMULATING from tick 0. A whole episode is 2 200 ticks of
  ## integer work over 864-cell levels — a few milliseconds — so a keyframe
  ## table would be complexity with nothing to buy.
  let target = max(0, tick)
  replay.turnIndex = 0
  replay.runner = TurnRunner()
  replay.hashIndex = 0
  let failed = replay.hashValidationFailed
  let mismatch = replay.hashMismatchTick
  sim = initSimServer(config)
  if replay.data.joins.len > 0:
    sim.playerName = replay.data.joins[0].name
  var guard = 0
  while sim.tickCount < target and not sim.ended and guard < 20_000:
    inc guard
    replay.stepReplay(sim)
  replay.hashValidationFailed = failed or replay.hashValidationFailed
  if mismatch >= 0:
    replay.hashMismatchTick = mismatch
  replay.endHoldFrames = 0

proc applySpeedCommand(speedIndex: var int, command: char) =
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.len - 1)
  of '-', '_': speedIndex = max(speedIndex - 1, 0)
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '4': speedIndex = 2
  of '8': speedIndex = 3
  else: discard

proc applyReplayCommand*(replay: var ReplayPlayer, sim: var SimServer,
                         config: GameConfig, command: char) =
  ## One global viewer transport command.
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '4', '8': applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, config, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, config, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, config, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, config, sim.tickCount + ReplayFps * 5)
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + TargetFps - 1) div TargetFps

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick >= span[0] and tick <= span[1]:
      return true
  false
