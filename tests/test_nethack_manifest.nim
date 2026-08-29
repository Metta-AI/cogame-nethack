## Manifest pins. Every one of these is a thing that has broken a real
## upload: `num_agents` at the wrong level, a literal `tokens` array in a
## game_config, an array property with no minItems/maxItems, a bare-string
## protocol, a missing readme, `game.tags`, a `limits.cpu` under 1, a variant
## the engine cannot actually construct.

import std/[json, os, strutils, unittest]

import nethack/[sim, driver, baselines]

let manifest = parseJson(readFile("coworld_manifest_template.json"))

proc gameConfigOf(node: JsonNode): GameConfig =
  result = defaultGameConfig()
  var text = node
  ## The runner injects tokens; the template must not carry them.
  result.update($text)

suite "manifest pins":
  test "num_agents is 1 inside every game_config and nowhere else":
    for variant in manifest{"variants"}:
      check not variant.hasKey("num_agents")
      check variant{"game_config"}{"num_agents"}.getInt() == 1
    check manifest{"certification"}{"game_config"}{"num_agents"}.getInt() == 1

  test "no game_config carries a literal tokens array":
    for variant in manifest{"variants"}:
      check not variant{"game_config"}.hasKey("tokens")
    check not manifest{"certification"}{"game_config"}.hasKey("tokens")

  test "the certification fixture seats exactly the one declared player":
    check manifest{"player"}.len == 1
    check manifest{"player"}[0]{"id"}.getStr() == "delver"
    check manifest{"certification"}{"players"}.len == 1
    check manifest{"certification"}{"players"}[0]{"player_id"}.getStr() ==
      "delver"
    check manifest{"certification"}{"game_config"}{"players"}.len == 1

  test "every array in config_schema carries minItems and maxItems":
    let properties = manifest{"game"}{"config_schema"}{"properties"}
    for key, value in properties:
      if value{"type"}.getStr() == "array":
        check value.hasKey("minItems")
        check value.hasKey("maxItems")
    check manifest{"game"}{"config_schema"}{"additionalProperties"}.getBool() ==
      false
    var required: seq[string] = @[]
    for item in manifest{"game"}{"config_schema"}{"required"}:
      required.add(item.getStr())
    check "tokens" in required
    check "players" in required

  test "episode_timeout_minutes is top level and there are three or more tags":
    check manifest.hasKey("episode_timeout_minutes")
    check not manifest{"game"}.hasKey("episode_timeout_minutes")
    check manifest{"tags"}.len >= 3
    check not manifest{"game"}.hasKey("tags")
    check manifest{"game"}{"description"}.getStr().len > 0

  test "both protocols are objects and the docs carry a readme plus pages":
    for key in ["player", "global"]:
      let node = manifest{"game"}{"protocols"}{key}
      check node.kind == JObject
      check node{"type"}.getStr().len > 0
      check node{"value"}.getStr().len > 0
    check manifest{"game"}{"docs"}{"readme"}{"value"}.getStr().len > 0
    check manifest{"game"}{"docs"}{"pages"}.len == 3
    for page in manifest{"game"}{"docs"}{"pages"}:
      check page{"id"}.getStr().len > 0
      check page{"title"}.getStr().len > 0
      check page{"content"}{"value"}.getStr().len > 0

  test "the replay viewer is the static bundle, under game":
    check manifest{"game"}{"replay_viewer"}{"bundle"}.getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check not manifest.hasKey("version")
    check not manifest{"game"}.hasKey("display_name")
    check manifest{"game"}{"owner"}.getStr().len > 0

  test "game.name equals the slug and the secret URI's namespace":
    check manifest{"game"}{"name"}.getStr() == "nethack"
    check manifest{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
      "secret://coworld/nethack/anthropic_api_key"
    check manifest{"game"}{"runnable"}{"run"}[0].getStr() == "/bin/nethack"

  test "the declared player asks for at least one whole cpu":
    let limits = manifest{"player"}[0]{"resources"}{"limits"}{"cpu"}.getStr()
    check limits.len > 0
    check limits != "0"
    check parseFloat(limits) >= 1.0

  test "every shipped wallClockBudgetSeconds fits inside 60% of the timeout":
    for variant in manifest{"variants"}:
      check variant{"game_config"}{"wallClockBudgetSeconds"}.getInt() <= 660
    check manifest{"certification"}{"game_config"}{
      "wallClockBudgetSeconds"}.getInt() <= 660

  test "the deadlines are whole seconds and fit inside the turn budget":
    for variant in manifest{"variants"}:
      let config = variant{"game_config"}
      check config{"attempt1Ms"}.getInt() mod 1000 == 0
      check config{"retryMs"}.getInt() mod 1000 == 0
      check config{"attempt1Ms"}.getInt() + config{"retryMs"}.getInt() <=
        config{"turnBudgetMs"}.getInt()
      check config{"maxTicks"}.getInt() ==
        config{"maxTurns"}.getInt() * config{"turnTicks"}.getInt()

  test "levelLadder is empty for descend and exactly five for minihack":
    for variant in manifest{"variants"}:
      let config = variant{"game_config"}
      if variant{"id"}.getStr() == "descend":
        check config{"levelLadder"}.len == 0
        check config{"dungeonLevels"}.getInt() == 8
      else:
        check config{"levelLadder"}.len == 5
        check config{"levelLadder"}.len == config{"dungeonLevels"}.getInt()

  test "the results schema is closed and names the closed enums":
    let schema = manifest{"game"}{"results_schema"}
    check schema{"additionalProperties"}.getBool() == false
    var reasons: seq[string] = @[]
    for item in schema{"properties"}{"reason"}{"enum"}:
      reasons.add(item.getStr())
    check reasons == @["complete", "deadline", "fault"]
    var rules: seq[string] = @[]
    for item in schema{"properties"}{"endRule"}{"enum"}:
      rules.add(item.getStr())
    check rules == @["death", "bottom", "escaped", "turnCap", "wallClock",
                     "fault"]
    var causes: seq[string] = @[]
    for item in schema{"properties"}{"causeOfDeath"}{"enum"}:
      causes.add(item.getStr())
    check causes == @["killed", "starved", "burned", "none"]
    var deeds: seq[string] = @[]
    for item in schema{"properties"}{"deeds"}{"items"}{"enum"}:
      deeds.add(item.getStr())
    check deeds == @["fed", "hoard", "oracle"]

suite "every variant actually constructs and plays":
  test "each variant's game_config builds a GameConfig and a full ladder":
    for variant in manifest{"variants"}:
      var config = gameConfigOf(variant{"game_config"})
      config.validate()
      var s = initSimServer(config)
      s.phase = Playing
      for depth in 1 .. config.dungeonLevels:
        s.ensureLevel(depth)
        check s.levels[depth - 1].generated
        check s.levels[depth - 1].levelConnected()
      var turn = 0
      while not s.ended and turn < config.maxTurns:
        inc turn
        s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
      check s.turnsPlayed <= config.maxTurns
      check s.tickCount <= config.maxTicks
      check s.score() >= 0

  test "the certification fixture builds and plays too":
    var config = gameConfigOf(manifest{"certification"}{"game_config"})
    config.validate()
    check config.seed == 42
    var s = initSimServer(config)
    s.phase = Playing
    var turn = 0
    while not s.ended and turn < config.maxTurns:
      inc turn
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
    check s.depthReached >= 2

suite "the policy set":
  test "two prompt champions, two scripted fillers, one image":
    let policies = parseJson(readFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owned = 0
    for policy in policies:
      check policy{"run"}.getStr() == "/bin/nethack-player"
      check policy{"name"}.getStr().startsWith("nethack-")
      if policy{"env"}.hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
      if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["delver", "bumbler"]
      if policy.hasKey("player"):
        inc owned
        check policy{"player"}.getStr() == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check prompts == 2
    check scripted == 2
    check owned == 1
