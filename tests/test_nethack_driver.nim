## Bounded orders and legality on the scripted baselines, on the driver, and
## on the reply validator. A baseline that ever proposes an illegal or
## unbounded action fails the build.

import std/[json, strutils, unicode, unittest]

import nethack/[sim, driver, baselines, directives, decide]

proc scatteredStates(count: int): seq[SimServer] =
  ## Pseudo-random game states across every depth, both variants, varied
  ## memories, full and empty packs, and adjacency to monsters, doors, lava
  ## and the Oracle.
  for i in 0 ..< count:
    var config = defaultGameConfig()
    config.seed = 1000 + i * 7919
    if i mod 3 == 0:
      config.levelLadder = @["corridor", "lavacross", "monsterroom",
                             "lockedvault", "oracle"]
      config.dungeonLevels = 5
      config.parDepth = 3
    var s = initSimServer(config)
    s.phase = Playing
    var turn = 0
    while not s.ended and turn < (i mod 9):
      inc turn
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
    if s.ended:
      continue
    if i mod 5 == 0:
      s.cog.hp = 1
    if i mod 7 == 0:
      s.cog.nutrition = 20
      s.cog.hunger = hungerOf(s.cog.nutrition)
    if i mod 4 == 0:
      for letter in 0 ..< MaxInventory:
        s.cog.inv[letter] = Item(kind: ikPotion, id: letter mod 4, count: 1)
    let li = s.levelIndex
    if i mod 6 == 0:
      s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
      s.levels[li].addMonster(spFloatingEye, s.cog.x + 1, s.cog.y)
    if i mod 8 == 0:
      s.levels[li].setTerrain(s.cog.x, s.cog.y + 1, tLava)
    if i mod 11 == 0:
      s.levels[li].setTerrain(s.cog.x - 1, s.cog.y, tDoorLocked)
    if i mod 13 == 0:
      s.levels[li].setTerrain(s.cog.x + 1, s.cog.y, tFloor)
      s.levels[li].addMonster(spOracle, s.cog.x + 1, s.cog.y)
    s.recomputeVisibility()
    result.add(s)

proc checkBounded(s: SimServer, actions: seq[Action]) =
  check actions.len <= s.config.maxActionsPerTurn
  for action in actions:
    check ord(action.verb) >= ord(vMove)
    case action.verb
    of vMove, vKick, vChat:
      check action.dir >= 0 and action.dir < 8
    of vTravel:
      check action.x >= 0 and action.x < LevelW
      check action.y >= 0 and action.y < LevelH
    of vEat, vQuaff, vWield, vWear:
      check action.item >= 0 and action.item < MaxInventory
      check s.cog.inv[action.item].kind != ikNone
    else:
      discard

suite "baselines are bounded":
  test "delver and bumbler always emit a legal, capped, silent plan":
    var state = BaselineState()
    for s in scatteredStates(300):
      let delver = delverPlan(s, DefaultBaselineParams)
      s.checkBounded(delver)
      var mutableSim = s
      let bumbler = bumblerPlan(state, mutableSim)
      s.checkBounded(bumbler)
      ## a baseline that narrated would make the feed lie about which seats
      ## are LLMs
      var reply = ParsedReply(actions: delver, source: dsScripted)
      check reply.say.len == 0
      check reply.notes.len == 0
      check ($actionsJson(delver)).len <= 1024
      check ($actionsJson(bumbler)).len <= 1024

suite "baselines never suicide":
  test "no baseline plan steps into a KNOWN lava cell":
    var state = BaselineState()
    for s in scatteredStates(300):
      for actions in [delverPlan(s, DefaultBaselineParams),
                      (block:
                        var mutableSim = s
                        bumblerPlan(state, mutableSim))]:
        let plan = s.expandPlan(actions)
        var x = s.cog.x
        var y = s.cog.y
        let li = s.levelIndex
        for primitive in plan.queue:
          if primitive.verb != vMove:
            continue
          let
            nx = x + DirDx[primitive.dir]
            ny = y + DirDy[primitive.dir]
          if not inside(nx, ny):
            continue
          if s.levels[li].seen[idx(nx, ny)] and
              s.levels[li].memTerrain[idx(nx, ny)] == tLava:
            check false
          if passable(s.levels[li].terrainAt(nx, ny)) and
              s.levels[li].terrainAt(nx, ny) != tLava:
            x = nx
            y = ny

  test "delver never melees a floating eye and never travels through the dark":
    for s in scatteredStates(300):
      let li = s.levelIndex
      let actions = delverPlan(s, DefaultBaselineParams)
      for action in actions:
        if action.verb == vTravel:
          check s.levels[li].seen[idx(action.x, action.y)] or
            s.levels[li].monsterAt(action.x, action.y) >= 0 or
            s.levels[li].terrainAt(action.x, action.y) in
              {tDoorClosed, tDoorLocked}
      ## walk the plan against the remembered map, exactly as trimAtEye does
      var x = s.cog.x
      var y = s.cog.y
      for action in actions:
        if action.verb == vTravel:
          x = action.x
          y = action.y
          continue
        if action.verb != vMove:
          continue
        let
          nx = x + DirDx[action.dir]
          ny = y + DirDy[action.dir]
        if not inside(nx, ny):
          continue
        let monster = s.levels[li].monsterAt(nx, ny)
        if monster >= 0 and s.visible[idx(nx, ny)]:
          check s.levels[li].monsters[monster].species != spFloatingEye
        if s.levels[li].memoryTraversable(nx, ny):
          x = nx
          y = ny

suite "the driver never produces an illegal primitive":
  test "every expanded queue is bounded, legal and corner-cut clean":
    for s in scatteredStates(200):
      let plan = s.expandPlan(delverPlan(s, DefaultBaselineParams))
      check plan.queue.len <= s.config.turnTicks
      var travelCount = 0
      for primitive in plan.queue:
        check primitive.verb != vTravel
        if primitive.verb == vMove:
          inc travelCount
      check travelCount <= s.config.turnTicks

  test "an empty plan yields a wait, never nothing":
    var s = scatteredStates(4)[0]
    let before = s.tickCount
    s.playTurn(@[], 0)
    check s.tickCount > before

suite "fallback is the delver proc":
  test "the engine's fallback plan equals the delver baseline's plan":
    for s in scatteredStates(40):
      var engine = DecisionEngine(params: DefaultBaselineParams)
      var mutableSim = s
      let fallback = engine.delverReply(mutableSim)
      check $actionsJson(fallback.actions) ==
        $actionsJson(delverPlan(s, DefaultBaselineParams))
      check fallback.source == dsFallback

suite "reply validation":
  test "the schema is accepted and every bound is enforced":
    var letters: set[char] = {'a', 'b', 'c'}
    let payload = parseJson("""
      {"actions": [{"do": "MOVE", "dir": "NE"},
                   {"do": "travel", "x": 999, "y": -4},
                   {"do": "eat", "item": "B"},
                   {"do": "quaff", "item": "zz"},
                   {"do": "move", "dir": "up"},
                   {"do": "nonsense"},
                   {"do": "pickup"}],
       "say": "rat first", "notes": "DL1"}""")
    let reply = parseReply(payload, letters, 10)
    check reply.actions.len == 4
    check reply.actions[0].verb == vMove
    check reply.actions[0].dir == 7
    check reply.actions[1].verb == vTravel
    check reply.actions[1].x == LevelW - 1
    check reply.actions[1].y == 0
    check reply.actions[2].verb == vEat
    check reply.actions[2].item == 1
    check reply.actions[3].verb == vPickup
    ## three entries failed the schema: they are REPAIRED-counted, and
    ## nothing overflowed the cap, so `dropped` stays 0. The two counters are
    ## disjoint (results.repliesRepaired vs results.actionsDropped).
    check reply.repaired == 3
    check reply.dropped == 0
    check reply.say == "rat first"
    check reply.notes == "DL1"

  test "actions past the cap are dropped and counted":
    var letters: set[char] = {'a'}
    var text = "{\"actions\":["
    for i in 0 ..< 25:
      if i > 0: text.add(",")
      text.add("{\"do\":\"wait\"}")
    text.add("]}")
    let reply = parseReply(parseJson(text), letters, 10)
    check reply.actions.len == 10
    check reply.dropped == 15
    check reply.repaired == 0

  test "a say-only reply is usable and a non-object is a parse failure":
    var letters: set[char] = {}
    let reply = parseReply(parseJson("""{"say": "hello"}"""), letters, 10)
    check reply.actions.len == 0
    check reply.say == "hello"
    expect DirectiveError:
      discard parseReply(parseJson("[1,2,3]"), letters, 10)

  test "say and notes truncate on RUNE boundaries with 4-byte emoji on the cap":
    var emoji = ""
    for i in 0 ..< 600:
      emoji.add("\u{1F600}")
    let capped = sanitizeNote(emoji)
    check capped.runeLen == MaxNoteRunes
    check capped.validateUtf8() == -1
    var mixed = "ok "
    for i in 0 ..< 500:
      mixed.add("\u{1F480}")
    check sanitizeNote(mixed).runeLen == MaxNoteRunes
    check sanitizeNote(mixed).validateUtf8() == -1
    ## `say` is cut on a RUNE boundary at its own cap FIRST, with a 4-byte
    ## emoji sitting exactly on the boundary, and only CONTROL characters are
    ## filtered afterwards — every printable rune survives, whatever script
    ## it is written in.
    let said = sanitizeSay(mixed)
    check said.runeLen == MaxSayRunes
    check said.validateUtf8() == -1
    check said.startsWith("ok ")
    check "\u{1F480}" in said
    check sanitizeSay("wei\u00DF \u4F60\u597D {json}") == "wei\u00DF \u4F60\u597D json"
    check sanitizeSay("a\x01b\x7Fc") == "abc"
    check truncateRunes(emoji, MaxSayRunes).runeLen == MaxSayRunes

  test "tolerant extraction survives fences and trailing prose":
    let node = extractJsonObject(
      "Sure!\n```json\n{\"actions\":[{\"do\":\"down\"}]}\n```\nHope that helps.")
    check node{"actions"}.len == 1
    expect DirectiveError:
      discard extractJsonObject("no object here at all")

  test "truncated / dropped / unreachable are reported back accurately":
    var config = defaultGameConfig()
    config.seed = 4242
    var s = initSimServer(config)
    s.phase = Playing
    s.playTurn(@[Action(verb: vTravel, x: 47, y: 17, item: -1)], 3)
    check s.lastDropped == 3
    check s.lastUnreachable == 1
    check s.macrosUnreachable == 1
    check s.actionsDropped == 3

suite "baseline tuning is the swept pick":
  test "the shipped delver params equal tools/ci/baseline_tuning.json":
    let recorded = parseJson(readFile("tools/ci/baseline_tuning.json"))
    check recorded{"params"}{"fleeHpNumerator"}.getInt() ==
      DefaultBaselineParams.fleeHpNumerator
    check recorded{"params"}{"lootRadius"}.getInt() ==
      DefaultBaselineParams.lootRadius
    check recorded{"params"}{"searchBurst"}.getInt() ==
      DefaultBaselineParams.searchBurst
    check recorded{"params"}{"frontierFarthest"}.getBool() ==
      DefaultBaselineParams.frontierFarthest

suite "delver beats bumbler":
  test "the two controls are genuinely different controllers":
    var delverDepth = 0
    var bumblerDepth = 0
    var delverBest = 0
    var bumblerBest = 0
    for seed in 1 .. 60:
      block:
        var config = defaultGameConfig()
        config.seed = seed * 15485867
        var s = initSimServer(config)
        s.phase = Playing
        var turn = 0
        while not s.ended and turn < config.maxTurns:
          inc turn
          s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
        delverDepth += s.depthReached
        delverBest = max(delverBest, s.depthReached)
      block:
        var config = defaultGameConfig()
        config.seed = seed * 15485867
        var s = initSimServer(config)
        s.phase = Playing
        var state = BaselineState()
        var turn = 0
        while not s.ended and turn < config.maxTurns:
          inc turn
          s.playTurn(bumblerPlan(state, s), 0)
        bumblerDepth += s.depthReached
        bumblerBest = max(bumblerBest, s.depthReached)
    check delverDepth > bumblerDepth
    check delverBest >= 3
    check bumblerBest >= 1
