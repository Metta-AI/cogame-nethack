## Replay tests: record then re-derive for EVERY end reason, self-sufficiency,
## determinism from the bytes alone, the strict-UTF-8 summary, and the
## committed fixture's GameVersion.

import std/[json, os, osproc, strutils, unicode, unittest]

import bitworld/spriteprotocol

import nethack/[sim, driver, baselines, directives, decide, replays,
                replay_runtime, global]

import helpers

proc replaySim(path: string): tuple[sim: SimServer, player: ReplayPlayer,
                                    config: GameConfig] =
  let data = loadReplay(path)
  var initialised = initReplayRuntime(data, mismatchQuit = false)
  (initialised.sim, initialised.player, initialised.config)

proc runToEnd(sim: var SimServer, player: var ReplayPlayer) =
  var guard = 0
  while not sim.ended and guard < 20_000:
    inc guard
    player.stepReplay(sim)

suite "record then re-derive, every end reason":
  test "the hash chain matches at every tick, including the stop tick":
    for (name, seed, stop, stopTurn) in [
        ("death", 42, "", 0),
        ("turncap", 4242, "", 0),
        ("wallclock", 909, "wallClock", 4),
        ("fault", 5150, "fault", 3)]:
      let path = tempReplayPath(name)
      let episode = recordEpisode(path, seed, forceStop = stop,
                                  forceStopTurn = stopTurn)
      defer: removeFile(path)
      var (sim, player, config) = replaySim(path)
      sim.runToEnd(player)
      check player.checkReplayHash() == -1
      check not player.hashValidationFailed
      check sim.tickCount == episode.sim.tickCount
      check sim.depthReached == episode.sim.depthReached
      check $sim.endRule == $episode.sim.endRule
      check $sim.endReason == $episode.sim.endReason

  test "bottom and escaped re-derive too":
    for ladder in [@["corridor"], @["corridor", "lavacross"]]:
      let path = tempReplayPath("ladder" & $ladder.len)
      let episode = recordEpisode(path, 8080, ladder = ladder)
      defer: removeFile(path)
      var (sim, player, config) = replaySim(path)
      sim.runToEnd(player)
      check player.checkReplayHash() == -1
      check sim.tickCount == episode.sim.tickCount

suite "the policy's own turn records reach the feed":
  test "say, plan and fallback are derived live and re-derived on playback":
    ## The three events that show a spectator the LLM playing. They are
    ## DERIVED from turn state, so they cost no replay bytes — which only
    ## works if the recorded chat records carry enough for playback to derive
    ## exactly the same ones. This asserts both halves against each other.
    let path = tempReplayPath("say")
    var config = defaultGameConfig()
    config.seed = 31337
    var s = initSimServer(config)
    s.phase = Playing
    s.playerName = "loremaster"
    var writer = openReplayWriter(path, config.configJson())
    defer: removeFile(path)
    writer.writeJoin(tickTime(0), 0, s.playerName, 0, "")
    writer.writeChat(tickTime(0), 0,
      registerRecord(0, "Alpha", s.playerName, "llm", ""))
    let remark = "rat first, then the gold, then the closed door west"
    var reply = ParsedReply(
      actions: @[Action(verb: vSearch, item: -1),
                 Action(verb: vWait, item: -1)],
      say: sanitizeSay(remark), source: dsFallback)
    ## the server writes the turn's fallback record BEFORE its directive
    writer.writeChat(tickTime(0), 0,
      fallbackRecord(1, 2, "timeout", "seat fell back to the delver plan"))
    s.lastSay = reply.say
    s.lastFallbackCause = "timeout"
    var runner = s.beginTurn(reply.actions, 0)
    var recorded: seq[JsonNode] = @[]
    for event in s.events:
      recorded.add(event)
    while not s.turnDone(runner):
      s.stepTurn(runner)
      writer.writeHash(tickTime(s.tickCount), s.gameHash())
    s.endTurn()
    writer.writeChat(tickTime(s.tickCount), 0,
      boundedDirectiveRecord(reply, 1, s.cog.depth, 0, "Alpha", s.lastExecuted,
                             s.lastTruncated, s.lastDropped, s.lastUnreachable,
                             s.observationJson(1, includeMap = false)))
    s.endRun(erTurnCap, codNone, "")
    writer.writeChat(tickTime(s.tickCount), 0, resultRecord(s))
    writer.closeReplayWriter()

    proc pick(events: seq[JsonNode], kind: string): JsonNode =
      for event in events:
        if event{"k"}.getStr() == kind:
          return event
      nil

    check pick(recorded, "say"){"text"}.getStr() == remark
    check pick(recorded, "fallback"){"cause"}.getStr() == "timeout"
    check pick(recorded, "plan"){"verbs"}.len == 2
    check pick(recorded, "plan"){"verbs"}[0].getStr() == "search"

    var (sim, player, cfg) = replaySim(path)
    var derived: seq[JsonNode] = @[]
    var guard = 0
    while not sim.ended and guard < 20_000:
      inc guard
      player.stepReplay(sim)
      for event in sim.events:
        derived.add(event)
      sim.events.setLen(0)
    check player.checkReplayHash() == -1
    check pick(derived, "say"){"text"}.getStr() == remark
    check pick(derived, "fallback"){"cause"}.getStr() == "timeout"
    check pick(derived, "plan"){"verbs"}[0].getStr() == "search"

suite "the replay is self-sufficient":
  test "the bytes alone carry the name, the alias, the config and the result":
    let path = tempReplayPath("self")
    let episode = recordEpisode(path, 31337)
    defer: removeFile(path)
    let data = loadReplay(path)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.joins.len == 1
    check data.joins[0].name == "delver"
    let config = parseJson(data.configJson)
    for key in ["seed", "num_agents", "levelW", "levelH", "dungeonLevels",
                "levelLadder", "turnTicks", "maxTurns", "maxTicks", "parDepth",
                "maxActionsPerTurn", "macroPrimitiveCap", "startHp",
                "startNutrition", "consultCost", "searchesToReveal",
                "searchBurst", "aggroRange", "players", "slots", "fastMode",
                "variant"]:
      check config.hasKey(key)
    var player = initReplayPlayer(data)
    check player.plans.len >= 1
    check not player.results.isNil
    check player.results{"scores"}[0].getInt() == episode.sim.score()
    var kinds = 0
    for record in player.records:
      if record{"k"}.getStr() == "register":
        inc kinds
        check record{"policy"}.getStr() == "delver"
        check not record.hasKey("prompt")     ## the prompt is NEVER recorded
    check kinds == 1

  test "re-simulating from the bytes reproduces the map and the status line":
    let path = tempReplayPath("rederive")
    let episode = recordEpisode(path, 5555)
    defer: removeFile(path)
    var (sim, player, config) = replaySim(path)
    sim.runToEnd(player)
    check sim.renderMap().len == LevelH
    for row in sim.renderMap():
      check row.len == LevelW
    check sim.cog.statusLine(sim.tickCount) ==
      episode.sim.cog.statusLine(episode.sim.tickCount)

suite "determinism from the replay alone":
  test "a fresh sim fed the recorded plans lands on the same final state":
    let path = tempReplayPath("determinism")
    let episode = recordEpisode(path, 123456)
    defer: removeFile(path)
    var (sim, player, config) = replaySim(path)
    sim.runToEnd(player)
    check sim.tickCount == episode.sim.tickCount
    check sim.cog.gold == episode.sim.cog.gold
    check sim.cog.xpPoints == episode.sim.cog.xpPoints
    check sim.depthReached == episode.sim.depthReached
    check sim.deedMask() == episode.sim.deedMask()
    check sim.gameHash() == episode.sim.gameHash()

  test "a seek re-simulates to the identical state":
    let path = tempReplayPath("seek")
    discard recordEpisode(path, 24680)
    defer: removeFile(path)
    var (sim, player, config) = replaySim(path)
    var guard = 0
    while sim.tickCount < 30 and not sim.ended and guard < 200:
      inc guard
      player.stepReplay(sim)
    let (tick, hash) = (sim.tickCount, sim.gameHash())
    player.seekReplay(sim, config, 0)
    check sim.tickCount == 0
    player.seekReplay(sim, config, tick)
    check sim.tickCount == tick
    check sim.gameHash() == hash

suite "the viewer packet is well formed":
  test "the board sprite and the chrome label ride the same binary channel":
    let path = tempReplayPath("packet")
    discard recordEpisode(path, 97531)
    defer: removeFile(path)
    var (sim, player, config) = replaySim(path)
    var state = initGlobalViewerState()
    var nextState: GlobalViewerState
    let packet = sim.buildReplayViewerPacket(player, state, nextState,
                                             newJArray())
    check packet.len > 0
    var chrome = ""
    var boardSprites = 0
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite:
        if message.sprite.id == BroadcastChromeSpriteId:
          chrome = message.sprite.label
        else:
          inc boardSprites
          check message.sprite.width == BoardW
          check message.sprite.height == BoardH
    check boardSprites == 1
    check chrome.len > 0
    check chrome.len < 60_000       ## the sprite label length is a U16
    let frame = parseJson(chrome)
    check frame{"nh"}{"map"}.len == LevelH
    check frame{"teams"}.hasKey("red")
    check frame{"roster"}.len == 1
    check frame{"nh"}{"ladder"}.len == config.dungeonLevels

suite "replay_summary is strict UTF-8 JSON":
  test "a replay whose capped fields are full of 4-byte emoji summarises clean":
    let path = tempReplayPath("utf8")
    var config = defaultGameConfig()
    config.seed = 60606
    var s = initSimServer(config)
    s.phase = Playing
    s.playerName = "daveey"
    var writer = openReplayWriter(path, config.configJson())
    defer: removeFile(path)
    writer.writeJoin(tickTime(0), 0, s.playerName, 0, "")
    var emoji = ""
    for i in 0 ..< 900:
      emoji.add("\u{1F480}")
    var reply = ParsedReply(
      actions: @[Action(verb: vWait, item: -1)],
      say: sanitizeSay(emoji & "abc"),
      notes: sanitizeNote(emoji),
      source: dsLlm)
    check reply.notes.runeLen == MaxNoteRunes
    writer.writeChat(tickTime(0), 0,
      registerRecord(0, "Alpha", sanitizeNote(emoji), "llm", ""))
    var runner = s.beginTurn(reply.actions, 0)
    while not s.turnDone(runner):
      s.stepTurn(runner)
      writer.writeHash(tickTime(s.tickCount), s.gameHash())
    s.endTurn()
    writer.writeChat(tickTime(s.tickCount), 0,
      boundedDirectiveRecord(reply, 1, 1, 0, "Alpha", s.lastExecuted,
                             s.lastTruncated, 0, 0,
                             s.observationJson(1, includeMap = false)))
    s.endRun(erTurnCap, codNone, "")
    writer.writeChat(tickTime(s.tickCount), 0, resultRecord(s))
    writer.closeReplayWriter()

    let summary = execProcess("python3",
      args = ["tools/replay_summary.py", path], options = {poUsePath})
    check summary.len > 0
    check summary.validateUtf8() == -1
    let node = parseJson(summary)
    check node{"protocol"}.getStr() == "nethack/v1"
    check node{"gameVersion"}.getStr() == GameVersion
    check node{"seed"}.getInt() == config.seed
    check node{"names"}[0].getStr() == "daveey"
    check node{"tickCount"}.getInt() > 0
    check node{"results"}{"reason"}.getStr() == "complete"

suite "the 1/2x replay speed is a frame-parity crawl":
  test "'5' selects it, the chrome reads 0.5, and a tick lands every other frame":
    ## The fleet-wide 1/2x speed. It is a REPLAY speed: the engine keeps an
    ## integer tick budget (the live loop has no fractional pace), and the
    ## halved rate comes from spending that budget on alternate frames only.
    var config = defaultGameConfig()
    var sim = initSimServer(config)
    var player = initReplayPlayer(ReplayData())

    player.applyReplayCommand(sim, config, '5')
    check player.speedIndex == ReplayHalfSpeedIndex
    check player.replayDisplaySpeed() == 0.5
    check player.replaySpeed() == 1

    player.skipLulls = false
    player.halfPhase = false
    check player.replayStepBudget(0) == 0
    player.halfPhase = true
    check player.replayStepBudget(0) == 1

    ## a lull is still skipped at 1/2x: the boost wins over the parity
    player.skipLulls = true
    player.lullSpans = @[[0, 10]]
    player.halfPhase = false
    check player.replayStepBudget(0) == LullSpeedBoost

    ## the chips' neighbours: '-' from 1x lands on 1/2x and floors there,
    ## '+' climbs back out to 1x
    player.speedIndex = 0
    player.applyReplayCommand(sim, config, '-')
    check player.speedIndex == ReplayHalfSpeedIndex
    player.applyReplayCommand(sim, config, '-')
    check player.speedIndex == ReplayHalfSpeedIndex
    player.applyReplayCommand(sim, config, '+')
    check player.speedIndex == 0

  test "a played frame flips the parity, so playback halves end to end":
    ## Through the real frame entry point: eight frames at 1/2x advance the
    ## sim exactly half as far as eight frames at 1x.
    let path = tempReplayPath("halfspeed")
    discard recordEpisode(path, 42)
    defer: removeFile(path)

    proc ticksOverFrames(speedCommand: char): int =
      var (sim, player, config) = replaySim(path)
      player.skipLulls = false
      discard player.advanceReplayFrame(sim, config, newSeq[int](), [speedCommand])
      let before = sim.tickCount
      for _ in 0 ..< 8:
        discard player.advanceReplayFrame(sim, config, newSeq[int](), newSeq[char]())
      sim.tickCount - before

    let full = ticksOverFrames('1')
    let half = ticksOverFrames('5')
    check full == 4
    check half == 2

suite "every committed fixture carries the current GameVersion":
  test "the fixture replays load under this build's spec":
    for path in walkFiles("tests/fixtures/*.replay"):
      let data = loadReplay(path)
      check data.gameVersion == GameVersion
      check data.gameName == GameName
