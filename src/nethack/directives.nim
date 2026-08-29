## The reply schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and what happens to an entry that does not validate.
##
## Forked from `coworld-ctf`'s `src/ctf/directives.nim`. Its rune discipline
## is kept verbatim in spirit: every cap here is measured in RUNES and every
## truncation lands on a rune boundary. Slicing a recorded string by BYTE
## index anywhere on the path to the replay is forbidden — a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict
## UTF-8 parser.
##
## INVALID ACTIONS ARE DROPPED, NEVER REWRITTEN. A mis-specified move in a
## permadeath game has no meaningful repair: turning an invalid `travel` into
## a `move` could walk the cog into lava on the game's own initiative. The
## entry is removed, counted, and reported back as `dropped` next turn.

import std/[json, strutils, unicode]

import sim_types

export truncateRunes

type
  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  ParsedReply* = object
    actions*: seq[Action]
    say*: string
    notes*: string
    dropped*: int
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc sanitizeSay*(text: string): string =
  ## The cog thinking out loud: capped at MaxSayRunes on a rune boundary
  ## FIRST, then filtered of CONTROL characters only. Every printable rune
  ## survives, whatever script it is written in — a `say` is a sentence a
  ## spectator reads, and deleting every non-ASCII rune silently emptied the
  ## line for any policy that did not write in English. Braces are excluded
  ## deliberately — the replay chat stream tells a control record from a
  ## cog's line by a leading '{'.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value < 32 or (value >= 127 and value < 160):
      continue                      ## C0 / DEL / C1 control characters
    if value == ord('{') or value == ord('}'):
      continue
    result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The private scratchpad, echoed back to this seat only. Newlines collapse
  ## to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc parseVerb(text: string): tuple[ok: bool, verb: Verb] =
  let key = text.strip().toLowerAscii().truncateRunes(8)
  for verb in Verb:
    if $verb == key:
      return (true, verb)
  (false, vWait)

proc readInt(node: JsonNode): tuple[ok: bool, value: int] =
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let value = node.getFloat()
    if value != value or value > 1.0e9 or value < -1.0e9: (false, 0)
    else: (true, int(value))
  of JString:
    try: (true, node.getStr().strip().parseInt())
    except CatchableError: (false, 0)
  else: (false, 0)

proc parseReply*(
  payload: JsonNode,
  inventoryLetters: set[char],
  maxActions: int
): ParsedReply =
  ## Turns one parsed reply into a legal action list. A reply that is not a
  ## JSON object is a parse failure; a reply with a valid `say` and no
  ## `actions` is USABLE (the turn is spent waiting and the narration is
  ## delivered).
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())
  let actions = payload{"actions"}
  if actions.isNil or actions.kind != JArray:
    return
  var index = 0
  for entry in actions:
    inc index
    if index > maxActions:
      inc result.dropped
      continue
    if entry.kind != JObject:
      inc result.dropped
      continue
    let verb = parseVerb(entry{"do"}.getStr())
    if not verb.ok:
      inc result.dropped
      continue
    var action = Action(verb: verb.verb, dir: 0, x: 0, y: 0, item: -1)
    case verb.verb
    of vMove, vKick, vChat:
      let dir = dirIndex(entry{"dir"}.getStr())
      if dir < 0:
        inc result.dropped
        continue
      action.dir = dir
    of vTravel:
      let
        x = readInt(entry{"x"})
        y = readInt(entry{"y"})
      if not x.ok or not y.ok:
        inc result.dropped
        continue
      action.x = clamp(x.value, 0, LevelW - 1)
      action.y = clamp(y.value, 0, LevelH - 1)
    of vEat, vQuaff, vWield, vWear:
      let letter = entry{"item"}.getStr().strip().toLowerAscii()
      if letter.runeLen != 1 or letter.len != 1 or
          letter[0] < 'a' or letter[0] > 'z' or letter[0] notin inventoryLetters:
        inc result.dropped
        continue
      action.item = ord(letter[0]) - ord('a')
    else:
      discard
    result.actions.add(action)

proc actionsJson*(actions: seq[Action]): JsonNode =
  result = newJArray()
  for action in actions:
    var node = %*{"do": $action.verb}
    case action.verb
    of vMove, vKick, vChat: node["dir"] = %DirNames[action.dir]
    of vTravel:
      node["x"] = %action.x
      node["y"] = %action.y
    of vEat, vQuaff, vWield, vWear:
      node["item"] = %($chr(ord('a') + max(0, action.item)))
    else: discard
    result.add(node)

proc directiveRecord*(
  reply: ParsedReply,
  turn, depth, slot: int,
  alias: string,
  executed: seq[string],
  truncated: bool,
  dropped, unreachable: int,
  observation: JsonNode
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  var executedJson = newJArray()
  for verb in executed:
    executedJson.add(%verb)
  %*{
    "k": "directive",
    "turn": turn,
    "depth": depth,
    "slot": slot,
    "alias": alias,
    "source": $reply.source,
    "latency_ms": reply.latencyMs,
    "actions": actionsJson(reply.actions),
    "executed": executedJson,
    "truncated": truncated,
    "dropped": dropped,
    "unreachable": unreachable,
    "say": reply.say.truncateRunes(MaxSayRunes),
    "obs": (if observation.isNil: newJObject() else: observation)
  }

proc boundedDirectiveRecord*(
  reply: ParsedReply,
  turn, depth, slot: int,
  alias: string,
  executed: seq[string],
  truncated: bool,
  dropped, unreachable: int,
  observation: JsonNode
): string =
  ## The serialised record, guaranteed <= MaxDirectiveRunes. The `say` line
  ## is the only field that can push it over, so it is the one that shrinks;
  ## the cut still lands on a rune boundary. Never cut the SERIALISED string:
  ## that would emit broken JSON, which is the exact failure the rune rule
  ## exists to prevent.
  var trimmed = reply
  result = $directiveRecord(trimmed, turn, depth, slot, alias, executed,
                            truncated, dropped, unreachable, observation)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(
      max(0, trimmed.say.runeLen - max(8, trimmed.say.runeLen div 2)))
    result = $directiveRecord(trimmed, turn, depth, slot, alias, executed,
                              truncated, dropped, unreachable,
                              (if guard >= 6: newJObject() else: observation))

proc parseActionsRecord*(node: JsonNode): seq[Action] =
  ## Reads an accepted action list back OUT of a replay record. The plans are
  ## this game's entire input log, so this is the proc the wasm viewer
  ## re-simulates from.
  if node.isNil or node.kind != JArray:
    return
  var letters: set[char] = {}
  for ch in 'a' .. 'z':
    letters.incl(ch)
  for entry in node:
    if entry.kind != JObject:
      continue
    let verb = parseVerb(entry{"do"}.getStr())
    if not verb.ok:
      continue
    var action = Action(verb: verb.verb, dir: 0, x: 0, y: 0, item: -1)
    case verb.verb
    of vMove, vKick, vChat:
      let dir = dirIndex(entry{"dir"}.getStr())
      if dir < 0:
        continue
      action.dir = dir
    of vTravel:
      action.x = clamp(entry{"x"}.getInt(), 0, LevelW - 1)
      action.y = clamp(entry{"y"}.getInt(), 0, LevelH - 1)
    of vEat, vQuaff, vWield, vWear:
      let letter = entry{"item"}.getStr()
      if letter.len != 1 or letter[0] notin letters:
        continue
      action.item = ord(letter[0]) - ord('a')
    else: discard
    result.add(action)
