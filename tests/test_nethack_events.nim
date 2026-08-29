## The event vocabulary is a closed enum, and the appended game block only
## uses kinds the sim can emit.

import std/[json, os, strutils, unittest]

import nethack/[sim, driver, baselines, broadcast, events]

const EmittedKinds = [
  "turn", "plan", "say", "fallback", "descend", "ascend", "kill", "hurt",
  "gold", "item", "eat", "quaff", "trap", "door", "oracle", "levelup",
  "deed", "hunger", "death", "bottom", "escaped", "end"]

proc collectKinds(seeds: int): seq[string] =
  for seed in 1 .. seeds:
    var config = defaultGameConfig()
    config.seed = seed * 7919
    if seed mod 4 == 0:
      config.levelLadder = @["corridor", "lavacross", "monsterroom",
                             "lockedvault", "oracle"]
      config.dungeonLevels = 5
      config.parDepth = 3
    var s = initSimServer(config)
    s.phase = Playing
    var turn = 0
    while not s.ended and turn < config.maxTurns:
      inc turn
      s.playTurn(delverPlan(s, DefaultBaselineParams), 0)
      for event in s.events:
        let kind = event{"k"}.getStr()
        if kind notin result:
          result.add(kind)
      s.events.setLen(0)

suite "events are the closed enum":
  test "every kind the sim emits is in the declared set":
    for kind in collectKinds(30):
      check kind in EmittedKinds

  test "the beat kinds are exactly the ten the scrubber styles":
    check BeatKinds.len == 10
    for kind in BeatKinds:
      check kind in EmittedKinds
    for kind in FeedKinds:
      check kind in EmittedKinds
      check not isBeatKind(kind)

  test "the appended game block only routes kinds the sim can emit":
    let page = readFile("client/replay_broadcast.html")
    let appended = page[page.find("NETHACK additions") .. ^1]
    for line in appended.splitLines():
      let code = line.strip()
      if not code.startsWith("case '"):
        continue
      let kind = code.split('\'')[1]
      check kind in EmittedKinds

suite "the tier-2 stream keeps the starter's contract":
  test "every kind maps to a declared row name and the summary row is last":
    for kind in EmittedKinds:
      let row = eventKindFor(kind)
      if row.len > 0:
        check row in EventKinds
    let rows = @[
      primitiveRow(1, 1, "move"),
      jsonRow(%*{"t": 2, "k": "kill", "monster": "sewer rat"})]
    let stream = eventsJsonl(rows, 2)
    let lines = stream.strip().splitLines()
    check lines.len == 3
    let summary = parseJson(lines[^1])
    check summary{"type"}.getStr() == "summary"
    check summary{"ticks"}.getInt() == 2
    check summary{"events"}.getInt() == 2
    check summary{"gameVersion"}.getStr() == GameVersion
    check parseJson(lines[0]){"kind"}.getStr() == "Primitive"
    check parseJson(lines[1]){"kind"}.getStr() == "Kill"
