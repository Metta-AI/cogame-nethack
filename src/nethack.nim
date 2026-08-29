import
  std/[json, os, sysrand],
  bitworld/runtime,
  nethack/sim,
  nethack/server

const LegacyFixedSeed = 0xA6019
  ## The "nobody chose a seed" sentinel, inherited from the starter: a config
  ## carrying it (or no seed at all) gets a fresh random seed. With a public
  ## fixed seed every dungeon would be pre-computable by a policy author,
  ## which is exactly what the idea's "seeded dungeons per round" forbids.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the
  ## sentinel (the certification fixture, forensic re-runs, test batteries).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(NethackError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("nethack-replay-" & $getCurrentProcessId() & ".replay")
      else:
        ""

  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    ## Randomise BEFORE config.update: every level is a pure function of
    ## (seed, depth), so the seed must already be in place or every process
    ## would draw the same dungeon.
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "seed not pinned; randomized"

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("nethack-load-replay-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "nethack config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " variant=", config.variantName(),
    " num_agents=", config.numAgents,
    " dungeonLevels=", config.dungeonLevels,
    " maxTurns=", config.maxTurns,
    " maxTicks=", config.maxTicks,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds

  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    runtimeConfig
  )
