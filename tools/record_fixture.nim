## Re-records a committed replay fixture with the CURRENT rules.
##
## A fixture is bytes cut against one GameVersion; the moment a rule changes
## and the number is bumped, the old bytes no longer identify the rules that
## produced them and `tests/test_nethack_replay.nim`'s fixture sweep refuses
## them. This is the one-line way to cut them again, through exactly the
## writer `src/nethack/server.nim` uses (`tests/helpers.recordEpisode`), so a
## fixture can never be a hand-made file that drifted from the server.
##
##   nim r --path:src tools/record_fixture.nim            # the cert seed
##   nim r --path:src tools/record_fixture.nim <path> <seed>

import std/[os, strutils]

import ../tests/helpers

when isMainModule:
  let
    path = if paramCount() >= 1: paramStr(1)
           else: "tests/fixtures/descend-seed42.replay"
    seed = if paramCount() >= 2: parseInt(paramStr(2)) else: 42
  createDir(path.parentDir())
  removeFile(path)
  let episode = recordEpisode(path, seed)
  echo "recorded ", path, ": seed=", seed,
    " ticks=", episode.sim.tickCount,
    " turns=", episode.turns,
    " depth=", episode.sim.depthReached,
    " endRule=", $episode.sim.endRule
