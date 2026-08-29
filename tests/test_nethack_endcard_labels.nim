## Endcard and chrome label re-mapping. A forked ctf endcard silently ships
## paintbot's vocabulary — nothing in the starter's tests, in
## `viewer_smoke.mjs` or in the label manifest covers spectator chrome
## strings. This test is what stops a rename from reintroducing it.
##
## `kill` is deliberately NOT forbidden: killing monsters is this game's own
## vocabulary and `#killfeed` is a kept starter id.

import std/[strutils, unittest]

const Forbidden = [
  "Lives", "LIVES", "Clstr", "flag", "heart", "paint", "hopper", "hill",
  "Hill", "POV", "EYES", "spray", "grenade", "med kit", "team", "squad"]
  ## Swept over the APPENDED GAME BLOCK, which is the only spectator surface
  ## this game writes. The inherited page keeps its classic-mode code paths
  ## (never entered here — every frame carries `regime`, which latches the
  ## game block on), and re-writing dead inherited code would be the rewrite
  ## the starter-chrome pin exists to forbid.

const RetiredStarterStrings = [
  "Lives left", "Hill time", "LIVES LEAD", "Hill coverage",
  "<span>Player</span><span>K</span><span>D</span>",
  "<span>Cog</span><span>Tags</span><span>Out</span><span>Paint</span>",
  ">EYES<", "In the locker room", "Filling hoppers with fresh paint",
  "showing recorded inputs",
  "Spoilers: kills / flag story / winner on the timeline",
  "id=\"povBadge\"", "id=\"fpv-hp\"", "id=\"fpv-gear\"",
  "id=\"fpv-map\"", ".beat-marker.capture"]

const Replacements = [
  "<span>Dlvl</span><span>Turns</span><span>Kills</span><span>Gold</span><span>Seen</span>",
  "<span>Cog</span><span>Depth</span><span>Gold</span><span>Score</span>",
  "<span class=\"fl-cap\">Deepest level</span>",
  "<span class=\"fl-cap\">Experience</span>",
  "<span class=\"momentum-label\">DEPTH</span>",
  "TERMINAL 48\u00d718",
  "Waiting for the cog",
  "Rolling up the dungeon\u2026",
  "Replay hash mismatch \u2014 showing recorded actions",
  "Spoilers: descents and the death on the timeline ahead of the playhead (o)"
]

let page = readFile("client/replay_broadcast.html")

proc codeLines(text: string): seq[string] =
  ## Strip the obvious comment forms so the vocabulary sweep only reads live
  ## markup, CSS and JS.
  var inBlockComment = false
  for raw in text.splitLines():
    let line = raw.strip()
    if line.startsWith("<!--"):
      inBlockComment = true
    if inBlockComment:
      if "-->" in line:
        inBlockComment = false
      continue
    if line.startsWith("//") or line.startsWith("/*") or line.startsWith("*"):
      continue
    if line.startsWith("##") or line.startsWith("#"):
      continue
    result.add(raw)

let appended = page[page.find("NETHACK additions") .. ^1]

suite "endcard labels":
  test "the forbidden vocabulary appears nowhere in the appended game block":
    let lines = appended.codeLines()
    for word in Forbidden:
      for line in lines:
        if word in line:
          checkpoint("forbidden vocabulary: " & word & " in: " & line.strip())
          check false

  test "every starter string the design note retires is gone from the page":
    for text in RetiredStarterStrings:
      if text in page:
        checkpoint("retired starter string still present: " & text)
        check false

  test "each re-mapped string is present":
    for text in Replacements:
      check text in page

  test "the plate reads the seat's alias and its real policy name":
    check "ALPHA THE DIGGER" in page
    check "plate-name" in page
    check "nh-alias" in page
