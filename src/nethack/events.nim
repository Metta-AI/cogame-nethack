## The tier-2 analysis stream (`COGAME_EVENTS_URI`): the starter's JSON-lines
## `eventsJsonl` contract, retargeted.
##
## `Primitive` is the per-tick row that makes this stream a full action trace
## for `cogamer-rl` — up to 2 200 rows an episode, which is what a
## long-horizon RL consumer needs and what the replay deliberately does not
## carry. The mandatory trailing summary row is kept: it is how a reader
## distinguishes "this episode had no events" from "the file was truncated",
## and it carries the GameVersion the events were produced under.

import std/json

import sim

const EventKinds* = [
  "TurnStart", "Directive", "Fallback", "Primitive", "Attack", "Damage",
  "Kill", "Pickup", "Eat", "Quaff", "DoorOpen", "DoorKick", "TrapTrigger",
  "Descend", "Ascend", "LevelUp", "Deed", "Oracle", "Death"]

proc eventKindFor*(kind: string): string =
  ## Maps one derived broadcast event kind onto its tier-2 row name.
  case kind
  of "turn": "TurnStart"
  of "plan": "Directive"
  of "fallback": "Fallback"
  of "kill": "Kill"
  of "hurt": "Damage"
  of "gold", "item": "Pickup"
  of "eat": "Eat"
  of "quaff": "Quaff"
  of "trap": "TrapTrigger"
  of "descend": "Descend"
  of "ascend": "Ascend"
  of "levelup": "LevelUp"
  of "deed": "Deed"
  of "oracle": "Oracle"
  of "death": "Death"
  of "door": "DoorOpen"
  else: ""

proc jsonRow*(event: JsonNode): JsonNode =
  ## One JSON-lines row for a tier-2 sim event.
  result = newJObject()
  result["tick"] = %event{"t"}.getInt()
  result["kind"] = %eventKindFor(event{"k"}.getStr())
  for key, value in event:
    if key == "t" or key == "k":
      continue
    result[key] = value

proc primitiveRow*(tick, depth: int, verb: string): JsonNode =
  %*{"tick": tick, "kind": "Primitive", "depth": depth, "verb": verb}

proc eventsJsonl*(rows: seq[JsonNode], ticks: int): string =
  ## The full JSON-lines stream: one row per event, then the summary.
  var lines: seq[string] = @[]
  for row in rows:
    lines.add($row)
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %rows.len
  summary["gameVersion"] = %GameVersion
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
