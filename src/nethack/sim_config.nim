## The episode config: defaults, `update` from the runner's JSON, the
## validators, and the resolved config JSON that goes into the replay header.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_config.nim`. The validators it
## carried are kept, because §Decisions' numbers were chosen to satisfy them:
## `attempt1Ms` / `retryMs` must be whole seconds (curl's CURLOPT_TIMEOUT has
## whole-second granularity, so a 4500 ms deadline really runs as 4 s),
## `attempt1Ms + retryMs <= turnBudgetMs`, `turnSpacingMs >= 0` and
## `wallClockBudgetSeconds > 0`.

import std/[json, strutils]

import sim_types

type
  PlayerSlot* = object
    name*: string

  GameConfig* = object
    seed*: int
    numAgents*: int
    minPlayers*: int
    players*: seq[PlayerSlot]
    slots*: seq[int]
    tokens*: seq[string]

    levelW*, levelH*: int
    dungeonLevels*: int
    levelLadder*: seq[string]

    turnTicks*: int
    maxTurns*: int
    maxTicks*: int
    parDepth*: int
    maxActionsPerTurn*: int
    macroPrimitiveCap*: int

    startHp*: int
    regenTicks*: int
    startNutrition*: int
    consultCost*: int
    searchesToReveal*: int
    searchBurst*: int
    aggroRange*: int

    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int

    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int

    speed*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: 1,
    minPlayers: 1,
    players: @[PlayerSlot(name: "Alpha")],
    slots: @[],
    tokens: @[],
    levelW: LevelW,
    levelH: LevelH,
    dungeonLevels: 8,
    levelLadder: @[],
    turnTicks: 40,
    maxTurns: 55,
    maxTicks: 2200,
    parDepth: 4,
    maxActionsPerTurn: 10,
    macroPrimitiveCap: 40,
    startHp: 16,
    regenTicks: 12,
    startNutrition: 900,
    consultCost: ConsultCostDefault,
    searchesToReveal: 3,
    searchBurst: 8,
    aggroRange: 10,
    attempt1Ms: 6000,
    retryMs: 3000,
    turnBudgetMs: 9500,
    turnSpacingMs: 2600,
    wallClockBudgetSeconds: 660,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 48,
    fastMode: true,
    showPlayerLabels: false,
    model: "claude-haiku-4-5-20251001",
    maxOutputTokens: 900,
    speed: 1
  )

proc readInt(node: JsonNode, key: string, current: int): int =
  let value = node{key}
  if value.isNil:
    return current
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: value.getStr().strip().parseInt()
    except CatchableError: current
  else: current

proc readBool(node: JsonNode, key: string, current: bool): bool =
  let value = node{key}
  if value.isNil:
    return current
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else: current

proc readStr(node: JsonNode, key: string, current: string): string =
  let value = node{key}
  if value.isNil or value.kind != JString:
    return current
  value.getStr()

proc validate*(config: GameConfig) =
  ## The starter's validator set, kept.
  if config.numAgents != 1:
    raise newException(NethackError,
      "num_agents must be 1 in every nethack variant, got " & $config.numAgents)
  if config.levelW != LevelW or config.levelH != LevelH:
    raise newException(NethackError,
      "levelW/levelH are fixed at " & $LevelW & "x" & $LevelH)
  if config.dungeonLevels < 1 or config.dungeonLevels > MaxDungeonLevels:
    raise newException(NethackError,
      "dungeonLevels must be 1.." & $MaxDungeonLevels)
  if config.levelLadder.len > 0 and
      config.levelLadder.len != config.dungeonLevels:
    raise newException(NethackError,
      "levelLadder must be empty or exactly dungeonLevels long")
  if config.turnTicks <= 0 or config.maxTurns <= 0:
    raise newException(NethackError, "turnTicks and maxTurns must be positive")
  if config.maxTicks != config.turnTicks * config.maxTurns:
    raise newException(NethackError,
      "maxTicks must equal turnTicks * maxTurns")
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(NethackError,
      "attempt1Ms and retryMs must be whole seconds (curl's timeout floors)")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(NethackError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs")
  if config.turnSpacingMs < 0:
    raise newException(NethackError, "turnSpacingMs must be >= 0")
  if config.wallClockBudgetSeconds <= 0 or
      config.wallClockBudgetSeconds > 660:
    raise newException(NethackError,
      "wallClockBudgetSeconds must be in 1..660 (60% of episodeTimeoutSeconds)")
  if config.maxActionsPerTurn <= 0 or config.macroPrimitiveCap <= 0:
    raise newException(NethackError,
      "maxActionsPerTurn and macroPrimitiveCap must be positive")

proc update*(config: var GameConfig, configJson: string) =
  ## Merges the runner's config document over the defaults, then validates.
  if configJson.len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(NethackError, "config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(NethackError, "config must be a JSON object")

  config.seed = node.readInt("seed", config.seed)
  config.numAgents = node.readInt("num_agents", config.numAgents)
  config.minPlayers = node.readInt("minPlayers", config.minPlayers)
  config.levelW = node.readInt("levelW", config.levelW)
  config.levelH = node.readInt("levelH", config.levelH)
  config.dungeonLevels = node.readInt("dungeonLevels", config.dungeonLevels)
  config.turnTicks = node.readInt("turnTicks", config.turnTicks)
  config.maxTurns = node.readInt("maxTurns", config.maxTurns)
  config.maxTicks = node.readInt("maxTicks", config.maxTicks)
  config.parDepth = node.readInt("parDepth", config.parDepth)
  config.maxActionsPerTurn =
    node.readInt("maxActionsPerTurn", config.maxActionsPerTurn)
  config.macroPrimitiveCap =
    node.readInt("macroPrimitiveCap", config.macroPrimitiveCap)
  config.startHp = node.readInt("startHp", config.startHp)
  config.regenTicks = node.readInt("regenTicks", config.regenTicks)
  config.startNutrition = node.readInt("startNutrition", config.startNutrition)
  config.consultCost = node.readInt("consultCost", config.consultCost)
  config.searchesToReveal =
    node.readInt("searchesToReveal", config.searchesToReveal)
  config.searchBurst = node.readInt("searchBurst", config.searchBurst)
  config.aggroRange = node.readInt("aggroRange", config.aggroRange)
  config.attempt1Ms = node.readInt("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.readInt("retryMs", config.retryMs)
  config.turnBudgetMs = node.readInt("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = node.readInt("turnSpacingMs", config.turnSpacingMs)
  config.wallClockBudgetSeconds =
    node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks =
    node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = node.readInt("gameOverTicks", config.gameOverTicks)
  config.fastMode = node.readBool("fastMode", config.fastMode)
  config.showPlayerLabels =
    node.readBool("showPlayerLabels", config.showPlayerLabels)
  config.model = node.readStr("model", config.model)
  config.maxOutputTokens = node.readInt("maxOutputTokens", config.maxOutputTokens)
  config.speed = node.readInt("speed", config.speed)

  let ladder = node{"levelLadder"}
  if not ladder.isNil and ladder.kind == JArray:
    config.levelLadder = @[]
    for item in ladder:
      if item.kind == JString:
        config.levelLadder.add(item.getStr())

  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerSlot(name: item{"name"}.getStr("Alpha")))
      elif item.kind == JString:
        config.players.add(PlayerSlot(name: item.getStr()))

  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for item in slots:
      if item.kind == JInt:
        config.slots.add(int(item.getBiggestInt()))

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      if item.kind == JString:
        config.tokens.add(item.getStr())

  if config.players.len == 0:
    config.players = @[PlayerSlot(name: "Alpha")]
  config.validate()

proc configJson*(config: GameConfig): string =
  ## The RESOLVED config, written into the replay header. Everything the
  ## viewer needs to reconstruct the episode from the seed and the plan
  ## records is in here; nothing secret is (no tokens, no prompts).
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  var ladder = newJArray()
  for name in config.levelLadder:
    ladder.add(%name)
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  $(%*{
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "players": players,
    "slots": slots,
    "levelW": config.levelW,
    "levelH": config.levelH,
    "dungeonLevels": config.dungeonLevels,
    "levelLadder": ladder,
    "turnTicks": config.turnTicks,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "parDepth": config.parDepth,
    "maxActionsPerTurn": config.maxActionsPerTurn,
    "macroPrimitiveCap": config.macroPrimitiveCap,
    "startHp": config.startHp,
    "regenTicks": config.regenTicks,
    "startNutrition": config.startNutrition,
    "consultCost": config.consultCost,
    "searchesToReveal": config.searchesToReveal,
    "searchBurst": config.searchBurst,
    "aggroRange": config.aggroRange,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "variant": (if config.levelLadder.len > 0: "minihack" else: "descend")
  })
