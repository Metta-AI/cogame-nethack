## Export complete native dungeon games as hosted command conversations.

import std/[json, os, osproc, strutils]
import nethack/[sim, baselines, directives, driver, llm, decide]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: nethack-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSimServer(config)
    var state = BaselineState()
    let baseline = if seed mod 2 == 0: blDelver else: blBumbler
    var rows: seq[string]
    for turn in 1 .. config.maxTurns:
      if game.ended: break
      let observation = game.observationJson(turn, includeMap = true)
      let plan = scriptedPlan(state, game, baseline)
      let completion = %*{"actions": plan.actionsJson(), "say": "", "notes": ""}
      let accepted = parseReply(completion, game.inventoryLetters(), config.maxActionsPerTurn)
      doAssert accepted.dropped == 0 and accepted.repaired == 0
      doAssert accepted.actions.actionsJson() == plan.actionsJson()
      rows.add($(%*{
        "episode_id": "nethack-" & variant & "-" & $seed,
        "seed": "nethack-" & variant & "-" & $seed,
        "decision_id": rows.len,
        "prompt": [
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage("", $observation)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "nethack", "action_schema_revision": "nethack-actions-v1"
      }))
      game.playTurn(accepted.actions, accepted.dropped)
    doAssert game.ended, "seed " & $seed & " did not terminate"
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = parseJson(game.runResultsJson())
    runs.add(%*{"seed": seed, "ticks": game.tickCount,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "nethack", "variant": variant,
    "source_revision": revision, "teacher": "delver-and-bumbler",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
