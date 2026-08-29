## Scoring: the formula, the dominance bound, the maximum, the minimum, the
## win flag and the winner — analytically and over 500 randomised end states.

import std/[strutils, unittest]

import nethack/[sim, driver, baselines]

proc scoreOf(depthReached, gold, xp, deeds: int): int =
  100_000 * (depthReached - 1) + 10 * min(gold, 2_000) +
    50 * min(xp, 1_000) + 5_000 * deeds

suite "scoring":
  test "the formula holds over 500 randomised end states":
    for i in 0 ..< 500:
      var config = defaultGameConfig()
      config.seed = i * 65537
      var s = initSimServer(config)
      s.depthReached = 1 + hashRnd(i, 0, 1, 11, 8)
      s.cog.gold = hashRnd(i, 0, 2, 13, 4000)
      s.cog.xpPoints = hashRnd(i, 0, 3, 17, 2000)
      for d in 0 .. 2:
        s.deeds[d] = hashRnd(i, 0, 4 + d, 19, 2) == 1
      check s.score() == scoreOf(s.depthReached, s.cog.gold, s.cog.xpPoints,
                                 s.deedCount())
      check s.score() >= 0

  test "one more dungeon level always beats every other term put together":
    let mostNonDepth = 10 * 2_000 + 50 * 1_000 + 5_000 * 3
    check mostNonDepth == 85_000
    check mostNonDepth < 100_000

  test "the maximum is 785 000 in descend and 485 000 in minihack":
    check scoreOf(8, 2_000, 1_000, 3) == 785_000
    check scoreOf(5, 2_000, 1_000, 3) == 485_000

  test "the minimum is zero and death subtracts nothing":
    var config = defaultGameConfig()
    config.seed = 5
    var s = initSimServer(config)
    check s.score() == 0
    let before = s.score()
    s.endRun(erDeath, codKilled, "sewer rat")
    check s.score() == before

  test "win is depthReached >= parDepth and winner is 0 or null":
    var config = defaultGameConfig()
    config.seed = 7
    var s = initSimServer(config)
    s.depthReached = config.parDepth - 1
    check not s.winFlag()
    check "\"winner\":null" in s.runResultsJson()
    s.depthReached = config.parDepth
    check s.winFlag()
    check "\"winner\":0" in s.runResultsJson()

  test "experience outranks gold in the limit":
    ## a full experience haul dominates a full gold haul: killing things is
    ## worth more than picking things up.
    check 50 * 1_000 > 10 * 2_000

  test "cellsTotal is derived from dungeonLevels, never hard-coded":
    for levels in [1, 5, 8]:
      var config = defaultGameConfig()
      config.seed = 11
      config.dungeonLevels = levels
      config.parDepth = min(config.parDepth, levels)
      if levels == 5:
        config.levelLadder = @["corridor", "lavacross", "monsterroom",
                               "lockedvault", "oracle"]
      var s = initSimServer(config)
      check ($(LevelW * LevelH * levels)) in s.runResultsJson()
