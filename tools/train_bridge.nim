## Persistent numeric plans over the native Nethack simulator.

import std/[json, os]
import nethack/[sim, baselines, directives, driver, llm, decide]

const
  Variants = ["descend", "minihack"]
  Slots = 10
  ValueCount = 904

var
  game: SimServer
  variant: string
  decisionId: int

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc acts(): JsonNode =
  result = newJArray()
  result.add(%"none")
  for verb in Verb: result.add(%($verb))

proc letters(): JsonNode =
  result = newJArray()
  for i in 0 ..< MaxInventory:
    result.add(%($chr(ord('a') + i)))

proc heads(): JsonNode =
  result = newJArray()
  for i in 0 ..< Slots:
    result.add(%*{"name": "do_" & $i, "choices": acts()})
    result.add(%*{"name": "dir_" & $i, "choices": DirNames})
    result.add(%*{"name": "x_" & $i, "choices": options(LevelW)})
    result.add(%*{"name": "y_" & $i, "choices": options(LevelH)})
    result.add(%*{"name": "item_" & $i, "choices": letters()})

proc currentDecision(): JsonNode =
  let observation = game.observationJson(game.turnsPlayed + 1, includeMap = true)
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "nethack",
    "decision_id": decisionId, "seat": 0, "engine_seat": 0,
    "turn": game.turnsPlayed + 1, "semantic_view": observation,
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage("", $observation)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  let observation = game.observationJson(game.turnsPlayed + 1, includeMap = true)
  let you = observation["you"]
  var values = newJArray()
  for name in Variants: values.add(%(if variant == name: 1 else: 0))
  for (name, scale) in [
    ("x", float(LevelW)), ("y", float(LevelH)),
    ("depth", 8.0), ("hp", 32.0), ("ac", 20.0),
    ("xlevel", 20.0), ("xp", 1000.0), ("gold", 2000.0),
    ("nutrition", 1000.0)]:
    values.add(%(float(you[name].getInt()) / scale))
  values.add(%(float(observation["turns_left"].getInt()) /
    float(game.config.maxTurns)))
  values.add(%(float(observation["ticks_left"].getInt()) /
    float(game.config.maxTicks)))
  values.add(%(float(observation["depth_reached"].getInt()) / 8.0))
  let available = game.inventoryLetters()
  for i in 0 ..< MaxInventory:
    values.add(%(if chr(ord('a') + i) in available: 1 else: 0))
  for row in observation["map"]:
    let line = row.getStr()
    doAssert line.len == LevelW
    for ch in line: values.add(%(float(ord(ch)) / 127.0))
  doAssert values.len == ValueCount
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads()}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == 1
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSimServer(config)
  decisionId = 0
  currentDecision()

proc teacher(): JsonNode =
  let entries = game.delverPlan(DefaultBaselineParams).actionsJson()
  doAssert entries.len <= Slots
  var action = newJObject()
  for i in 0 ..< Slots:
    let entry = if i < entries.len: entries[i] else: newJNull()
    action["do_" & $i] = if i < entries.len: entry["do"] else: %"none"
    action["dir_" & $i] = if i < entries.len and entry.hasKey("dir"):
      entry["dir"] else: %DirNames[0]
    action["x_" & $i] = if i < entries.len and entry.hasKey("x"):
      entry["x"] else: %0
    action["y_" & $i] = if i < entries.len and entry.hasKey("y"):
      entry["y"] else: %0
    action["item_" & $i] = if i < entries.len and entry.hasKey("item"):
      entry["item"] else: %"a"
  %*{"response": $action}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads():
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  var entries = newJArray()
  for i in 0 ..< Slots:
    if action["do_" & $i].getStr() == "none": continue
    entries.add(%*{
      "do": action["do_" & $i],
      "dir": action["dir_" & $i],
      "x": action["x_" & $i],
      "y": action["y_" & $i],
      "item": action["item_" & $i]
    })
  let plan = parseReply(%*{"actions": entries, "say": "", "notes": ""},
    game.inventoryLetters(), game.config.maxActionsPerTurn)
  game.playTurn(plan.actions, plan.dropped)
  inc decisionId
  let observation = if game.ended:
    doAssert game.endReason == reasonComplete
    let score = min(1.0, float(game.score()) / 785_000.0)
    %*{"kind": "terminal", "scores": {"0": score},
      "utilities": {"0": 2.0 * score - 1.0}}
  else:
    currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: nethack-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
