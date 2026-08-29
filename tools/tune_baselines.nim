## The baseline sweep. `delver`'s tunables are a parameter object CHOSEN by
## this sweep, not guessed: it plays every combination over a fixed seed set
## and keeps the one that plays the game best (total depth reached, then
## total score). `tools/ci/baseline_tuning.json` records the pick and
## `tests/test_nethack_tuning.nim` asserts the shipped defaults still equal
## it.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check    # assert the pick
##
## Forked from `coworld-ctf`'s `tools/tune_baselines.nim`.

import std/[json, os, strformat, strutils]

import nethack/[sim, driver, baselines]

const
  SweepSeeds = 40
  TuningPath = "tools/ci/baseline_tuning.json"

proc playEpisode(params: BaselineParams, seed: int): tuple[depth, score: int] =
  var config = defaultGameConfig()
  config.seed = seed
  var s = initSimServer(config)
  s.phase = Playing
  var turn = 0
  while not s.ended and turn < config.maxTurns:
    inc turn
    s.playTurn(delverPlan(s, params), 0)
  (s.depthReached, s.score())

proc sweep(): tuple[best: BaselineParams, depth, score: int] =
  var bestDepth = -1
  var bestScore = -1
  for fleeHpNumerator in [1, 2, 3, 4]:
    for lootRadius in [8, 15, 25]:
      for searchBurst in [4, 8]:
        for farthest in [false, true]:
          let params = BaselineParams(
            fleeHpNumerator: fleeHpNumerator,
            lootRadius: lootRadius,
            searchBurst: searchBurst,
            frontierFarthest: farthest)
          var depth = 0
          var score = 0
          for seed in 1 .. SweepSeeds:
            let outcome = playEpisode(params, seed * 7919)
            depth += outcome.depth
            score += outcome.score
          if depth > bestDepth or (depth == bestDepth and score > bestScore):
            bestDepth = depth
            bestScore = score
            result.best = params
  result.depth = bestDepth
  result.score = bestScore

proc paramsJson(params: BaselineParams): JsonNode =
  %*{
    "fleeHpNumerator": params.fleeHpNumerator,
    "lootRadius": params.lootRadius,
    "searchBurst": params.searchBurst,
    "frontierFarthest": params.frontierFarthest
  }

when isMainModule:
  let check = paramStr(0).len >= 0 and commandLineParams().contains("--check")
  if check:
    let recorded = parseJson(readFile(TuningPath))
    let shipped = paramsJson(DefaultBaselineParams)
    if recorded{"params"} != shipped:
      echo "::error::the shipped delver params are not the swept pick"
      echo "  recorded: ", recorded{"params"}
      echo "  shipped:  ", shipped
      quit(1)
    echo "delver params match ", TuningPath
    quit(0)
  let outcome = sweep()
  echo &"best total depth {outcome.depth} score {outcome.score}"
  echo paramsJson(outcome.best).pretty()
  writeFile(TuningPath, ($(%*{
    "seeds": SweepSeeds,
    "totalDepth": outcome.depth,
    "totalScore": outcome.score,
    "params": paramsJson(outcome.best)
  })).parseJson().pretty() & "\n")
