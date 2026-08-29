## Deterministic replay playback, shared by the native replay server and the
## wasm viewer: the same sim module, stepped from the same recorded plans,
## with the per-tick hash chain checked every tick.

import std/json

import sim, driver, broadcast, replays, global

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer

proc runPreScan(player: var ReplayPlayer, config: GameConfig) =
  ## The load-time pre-scan: re-simulate the whole episode once, headlessly,
  ## and record the depth series, the beat ticks and the lull spans. That is
  ## what lets the depth ladder, the sparkline and the scrubber beats draw at
  ## FULL WIDTH on the first frame instead of growing in.
  var scan = initSimServer(config)
  var walker = player
  walker.turnIndex = 0
  walker.runner = TurnRunner()
  walker.hashIndex = 0
  walker.hashValidationFailed = false
  walker.hashMismatchTick = -1
  var lastDepth = -1
  var lastBeatTick = 0
  var guard = 0
  player.depthSeries = @[]
  player.beatEvents = newJArray()
  player.lullSpans = @[]
  while not scan.ended and guard < 20_000:
    inc guard
    walker.stepReplay(scan)
    if scan.cog.depth != lastDepth:
      lastDepth = scan.cog.depth
      player.depthSeries.add(@[scan.tickCount, scan.depthReached])
    for event in scan.events:
      let kind = event{"k"}.getStr()
      if isBeatKind(kind):
        player.beatEvents.add(event)
      if kind in ["kill", "hurt", "gold", "item", "door", "trap", "descend",
                  "deed"]:
        if scan.tickCount - lastBeatTick >= MinLullTicks:
          player.lullSpans.add([lastBeatTick + 1, scan.tickCount - 1])
        lastBeatTick = scan.tickCount
    scan.events.setLen(0)
  player.depthSeries.add(@[scan.tickCount, scan.depthReached])
  player.scanDone = true

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit: bool
): InitializedReplay =
  ## Constructs and starts replay playback from the recorded game config.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  if data.joins.len > 0:
    result.sim.playerName = data.joins[0].name
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  result.player.runPreScan(result.config)
  for record in result.player.records:
    if record{"k"}.getStr() == "register":
      result.sim.policyKind = record{"kind"}.getStr("scripted")

proc advanceReplayFrame*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  config: GameConfig,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.seekReplay(sim, config, seekTick)
    didSeek = true
  for command in commands:
    let before = sim.tickCount
    replay.applyReplayCommand(sim, config, command)
    if sim.tickCount != before:
      didSeek = true
  if didSeek:
    replay.cancelEndHold()
    sim.events.setLen(0)

  if replay.playing and not sim.ended:
    ## ONE TICK PER TWO ANIMATION FRAMES at 1x, so a dungeon step glides
    ## rather than snapping and a short run is still watchable: a 2 200-tick
    ## episode plays for ~183 s at 1x and 23 s at 8x.
    var speed = replay.replaySpeed()
    if replay.skipLulls and replay.isLullTick(sim.tickCount):
      speed = min(MaxLullTicksPerFrame, speed * LullSpeedBoost)
    replay.tickAccumulator += speed
    let ticks = replay.tickAccumulator div 2
    replay.tickAccumulator = replay.tickAccumulator mod 2
    for _ in 0 ..< ticks:
      if sim.ended:
        break
      replay.stepReplay(sim)
  elif replay.playing and sim.ended:
    if replay.looping:
      if replay.endHoldFrames <= 0:
        replay.endHoldFrames = ReplayEndHoldSeconds * TargetFps
      else:
        dec replay.endHoldFrames
        if replay.endHoldFrames <= 0:
          replay.seekReplay(sim, config, replay.replayStartTick())
  sim.drainEvents()

proc buildReplayViewerPacket*(
  sim: var SimServer,
  replay: ReplayPlayer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## The shared replay board and chrome packet for one viewer.
  result = sim.buildBoardPacket(state, nextState)
  let sendLead = not state.momentumSent and replay.scanDone
  result.addChrome(sim.buildStateJson(
    events,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.checkReplayHash(),
    replay.replayStartTick(),
    replay.endHoldSecondsLeft(),
    replay.skipLulls,
    replay.skipLulls and replay.playing and
      replay.isLullTick(sim.tickCount),
    (if sendLead: replay.depthSeries else: @[]),
    (if sendLead: replay.lullSpans else: @[]),
    (if sendLead: replay.beatEvents else: nil)
  ))
  if sendLead:
    nextState.momentumSent = true
