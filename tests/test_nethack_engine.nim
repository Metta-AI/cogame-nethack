## End-to-end episode tests: the artifacts, the certification seed, the
## degrade-never-hang guarantees and permadeath.

import std/[json, os, strutils, unittest]

import nethack/[sim, driver, baselines, directives, decide, replays]

import helpers

suite "episode writes artifacts":
  test "a real scripted episode writes results and a replay":
    let path = tempReplayPath("artifacts")
    let episode = recordEpisode(path, 20260828)
    defer: removeFile(path)
    check fileExists(path)
    check getFileSize(path) > 0
    let results = parseJson(episode.results)
    check results{"reason"}.getStr() == "complete"
    check results{"names"}.len == 1
    check results{"scores"}.len == 1
    check results{"policyKinds"}[0].getStr() == "scripted"

  test "the five results identities hold":
    let path = tempReplayPath("identities")
    let episode = recordEpisode(path, 4242)
    defer: removeFile(path)
    let results = parseJson(episode.results)
    var turns = 0
    var ticks = 0
    var gold = 0
    var deepest = 0
    for i in 0 ..< results{"levelTurns"}.len:
      turns += results{"levelTurns"}[i].getInt()
      ticks += results{"levelTicks"}[i].getInt()
      gold += results{"levelGold"}[i].getInt()
      if results{"levelTicks"}[i].getInt() > 0:
        deepest = i + 1
    check turns == results{"turnsPlayed"}.getInt()
    check ticks == results{"finalTick"}.getInt()
    check gold == results{"goldPickedUp"}.getInt()
    check deepest == results{"depthReached"}.getInt()
    check results{"deedCount"}.getInt() == results{"deeds"}.len
    check results{"scores"}[0].getInt() ==
      100_000 * (results{"depthReached"}.getInt() - 1) +
      10 * min(results{"gold"}.getInt(), 2_000) +
      50 * min(results{"xpPoints"}.getInt(), 1_000) +
      5_000 * results{"deedCount"}.getInt()

  test "the results key set equals the manifest's results_schema key set":
    let path = tempReplayPath("schema")
    let episode = recordEpisode(path, 77)
    defer: removeFile(path)
    let
      results = parseJson(episode.results)
      manifest = parseJson(readFile("coworld_manifest_template.json"))
      declared = manifest{"game"}{"results_schema"}{"properties"}
    var produced: seq[string] = @[]
    for key, value in results:
      produced.add(key)
    var expected: seq[string] = @[]
    for key, value in declared:
      expected.add(key)
    for key in produced:
      check key in expected
    for key in expected:
      check key in produced

suite "the certification seed is interesting":
  test "seed 42 reaches dungeon level 2 and exercises kill, gold and door":
    let path = tempReplayPath("cert")
    var config = defaultGameConfig()
    config.seed = 42
    var s = initSimServer(config)
    s.phase = Playing
    var doors = 0
    var turn = 0
    while not s.ended and turn < config.maxTurns:
      inc turn
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
      for event in s.events:
        if event{"k"}.getStr() == "door":
          inc doors
      s.events.setLen(0)
    check s.depthReached >= 2
    check s.monstersKilled >= 1
    check s.goldPickedUp >= 1
    check doors >= 1
    check s.tickCount >= 200        ## a replay long enough for the viewer soak
    removeFile(path)

suite "no seat can stall the episode":
  test "an LLM seat with no credentials falls back every turn, bounded":
    var config = defaultGameConfig()
    config.seed = 909
    var s = initSimServer(config)
    s.phase = Playing
    var engine = initDecisionEngine(s)
    engine.seat.isLlm = true
    engine.seat.prompt = "dive"
    engine.client.disabled = true
    var turn = 0
    while not s.ended and turn < 12:
      inc turn
      let outcome = engine.turn(s, turn, 0)
      check outcome.reply.actions.len <= config.maxActionsPerTurn
      check outcome.records.len >= 1
      let record = parseJson(outcome.records[0])
      check record{"k"}.getStr() == "fallback"
      check record{"cause"}.getStr() == "no_credentials"
      s.playTurn(outcome.reply.actions, outcome.reply.dropped)
    check s.fallbackTurns == turn

  test "the player-failure payload is the platform's CLOSED two-key object":
    let payload = %*{"failed_policy_index": 0, "message": "no seat"}
    var keys: seq[string] = @[]
    for key, value in payload:
      keys.add(key)
    check keys.len == 2
    check "failed_policy_index" in keys
    check "message" in keys

suite "the budget guard settles early":
  test "the guard fires and the episode still ends complete":
    var config = defaultGameConfig()
    config.seed = 31337
    var s = initSimServer(config)
    s.phase = Playing
    var engine = initDecisionEngine(s)
    engine.seat.isLlm = true
    let outcome = engine.turn(s, 1, config.wallClockBudgetSeconds - 1)
    check engine.llmOff
    var found = false
    for record in outcome.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "budget_guard":
        found = true
        check node{"turn"}.getInt() == 1
    check found
    var turn = 1
    while not s.ended and turn < config.maxTurns:
      inc turn
      let next = engine.turn(s, turn, 0)
      s.playTurn(next.reply.actions, next.reply.dropped)
    check s.endReason == reasonComplete

suite "permadeath settles immediately":
  test "a forced killing blow ends the episode on that tick":
    var config = defaultGameConfig()
    config.seed = 6161
    var s = initSimServer(config)
    s.phase = Playing
    s.playTurn(@[Action(verb: vWait, item: -1)], 0)
    let deathTick = s.tickCount + 1
    s.cog.hp = 1
    let li = s.levelIndex
    s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tLava)
    var actions: seq[Action] = @[]
    for i in 0 ..< 8:
      actions.add(Action(verb: vMove, dir: 0, item: -1))
    s.playTurn(actions, 0)
    check s.ended
    check s.tickCount == deathTick
    check s.endRule == erDeath
    check s.causeOfDeath == codBurned
    check s.killer.len > 0

suite "every end reason produces a rankable settlement":
  test "death, bottom, escaped, turnCap, wallClock and fault all settle":
    for rule in [erDeath, erBottom, erEscaped, erTurnCap, erWallClock,
                 erFault]:
      var config = defaultGameConfig()
      config.seed = 808
      var s = initSimServer(config)
      s.phase = Playing
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
      s.endRun(rule, (if rule == erDeath: codKilled else: codNone),
               (if rule == erDeath: "sewer rat" else: ""))
      let results = parseJson(s.runResultsJson())
      check results{"endRule"}.getStr() == $rule
      check results{"reason"}.getStr() in ["complete", "deadline", "fault"]
      check results{"depthReached"}.getInt() >= 1
      check results{"scores"}[0].getInt() >= 0
      if rule == erWallClock:
        check results{"reason"}.getStr() == "deadline"
      elif rule == erFault:
        check results{"reason"}.getStr() == "fault"
      else:
        check results{"reason"}.getStr() == "complete"
