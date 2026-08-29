## Claude-backed dungeon play. A policy is just a prompt: the game server
## composes the seat's own observation plus that seat's PLAYER_PROMPT and
## asks Claude what the cog does for the next forty dungeon turns.
##
## Forked from `coworld-ctf`'s `src/ctf/llm.nim`, behaviour for behaviour —
## the credential ladder, the Bedrock model rotation, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait — which is what lets
## offline certification finish in seconds.

import std/[json, os, strutils]

import bitworld/runtime
import curly

import sim_types, sim_config, directives

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "nethack llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate:
  ## it timed out on every sidecar call (cogame-raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "nethack llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "nethack llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "nethack llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "nethack llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " &
      detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  var body = response.body
  if body.len > MaxReplyBytes * 8:
    body = body[0 ..< MaxReplyBytes * 8]
  let payload = parseJson(body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  let content = payload{"content"}
  if not content.isNil and content.kind == JArray:
    for contentBlock in content:
      if contentBlock{"type"}.getStr() == "text":
        result.add(contentBlock{"text"}.getStr())
  if result.len > MaxReplyBytes:
    result = result.truncateRunes(MaxReplyBytes)
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are Alpha the Digger, alone in a randomly generated dungeon. It is NetHack
in miniature: rooms, corridors, monsters, hunger, traps, permadeath. You have
ONE life. If you die the run is over.

WHAT YOU GET EACH TURN
- "map": 18 rows of 48 characters, the level as YOU REMEMBER IT. A space is a
  cell you have never seen - it may be rock, or a room, or the way down.
- "messages": what just happened, in order, like NetHack's message line.
- "status_line": Dlvl / gold / HP / AC / experience / turn / hunger.
- "visible": monsters and items you can see RIGHT NOW. Monsters are NOT
  remembered: if one is not in this list, you do not know where it is.
- "inventory": your pack, by letter. Unidentified potions show a colour only.

GLYPHS
  @ you        . floor      # corridor    - | wall      ' open doorway
  + door (closed OR locked - the message line tells you which)
  < stairs up  > stairs DOWN (this is what you are looking for)
  } LAVA - entering it kills you instantly
  ^ a trap you have already found
  $ gold  % food  ! potion  ) weapon  [ armour
  O the Oracle
  letters are monsters: x grid bug, r sewer rat, F lichen, d jackal, k kobold,
  G gnome, Z gnome zombie, e floating eye, o hill orc, h dwarf, M gnome mummy

WHAT YOU SEND
One JSON object with up to 10 actions. They run one per dungeon turn, in order,
up to 40 turns, and then you are asked again. Anything past 40 turns of
movement is CUT OFF - re-issue it next turn.
  {"do":"move","dir":"ne"}   step one cell (n s e w ne nw se sw). Moving INTO a
                    monster attacks it. Moving into a closed door opens it.
  {"do":"travel","x":31,"y":8}  WALK THERE. Your main action. Shortest path
                    through cells you have ALREADY SEEN. It refuses to path
                    through unseen cells, lava, locked doors and monsters. If
                    it says "unreachable" you have not found a route yet.
  {"do":"down"}     take > down a level. You must be standing on it.
  {"do":"up"}       take < up. On level 1 this ENDS the run.
  {"do":"pickup"}   pick up what is under you
  {"do":"eat","item":"b"}    eat a food item from your pack
  {"do":"quaff","item":"d"}  drink a potion (you find out what it was)
  {"do":"wield","item":"a"}  {"do":"wear","item":"c"}
  {"do":"kick","dir":"n"}    kick a LOCKED door open. May take several kicks.
  {"do":"search"}   search the 8 cells around you for secret doors and traps.
                    Three searches next to a hidden thing finds it.
  {"do":"chat","dir":"e"}    talk to the Oracle (O). Costs 50 gold, tells you
                    which way the stairs down are.
  {"do":"wait"}     waste a turn

THINGS THAT KILL YOU
Hit points reaching 0. Stepping into lava (}). Starving: your nutrition falls
by 1 every turn, and at -200 you die. Eat before you are Weak.
NEVER melee a floating eye (e). Hitting one freezes you for 12 turns and
everything else in the room gets 12 free attacks. Walk around it.

HOW YOU ARE SCORED
Depth, overwhelmingly. Every dungeon level you reach is worth more than all the
gold, experience and deeds you could possibly collect. Gold, experience, and
three deeds (eat once, carry 500 gold, consult the Oracle) are tie-breaks.
Dying does not subtract anything - but it stops you going deeper.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"actions":[{"do":"travel","x":31,"y":8},{"do":"down"}],"say":"<=140 chars","notes":"<=400 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, observationJson: string): string =
  operatorBlock(operatorPrompt) & observationJson
