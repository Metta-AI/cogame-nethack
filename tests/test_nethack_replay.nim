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

suite "every committed fixture carries the current GameVersion":
  test "the fixture replays load under this build's spec":
    for path in walkFiles("tests/fixtures/*.replay"):
      let data = loadReplay(path)
      check data.gameVersion == GameVersion
      check data.gameName == GameName
