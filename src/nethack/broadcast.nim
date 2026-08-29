## The broadcast chrome: the JSON frame the viewer page reads, and the beat
## timeline the scrubber draws.
##
## Forked from `coworld-ctf`'s `src/ctf/broadcast.nim`: the same structure and
## the same field names where the inherited chrome reads them (so the
## starter's scorebug, clock, transport, scrubber and endcard keep working
## unchanged), with this game's own readouts carried under `nh`.

import std/[json, strutils]

import sim, replays

const BeatKinds* = [
  "descend", "ascend", "levelup", "deed", "oracle", "death", "bottom",
  "escaped", "fallback", "end"]

const FeedKinds* = [
  "turn", "plan", "say", "kill", "hurt", "gold", "item", "eat", "quaff",
  "trap", "door", "hunger"]

proc isBeatKind*(kind: string): bool =
  for name in BeatKinds:
    if name == kind:
      return true
  false

proc drainEvents*(sim: var SimServer): JsonNode =
  ## The events accumulated since the last frame. Derived from state during
  ## the tick, identical live and in replay, and costing no replay bytes.
  result = newJArray()
  for event in sim.events:
    result.add(event)
  sim.events.setLen(0)

proc hungerPercent(sim: SimServer): int =
  clamp(sim.cog.nutrition * 100 div max(1, sim.config.startNutrition), 0, 100)

proc teamsJson(sim: SimServer): JsonNode =
  ## One "team" — the seat. The inherited chrome keys its plates off this
  ## object, so the shape is the starter's; the meanings are this game's.
  var policies = newJArray()
  policies.add(%sim.playerName)
  %*{
    "red": {
      "lives": sim.score(),
      "held": sim.score(),
      "cov": hungerPercent(sim),
      "own": sim.cog.hunger in {hSatiated, hNotHungry},
      "tags": sim.monstersKilled,
      "cogs": 1,
      "paint": sim.cellsSeen(),
      "policies": policies,
      "flag": "home",
      "carrier": -1,
      "prog": sim.depthReached
    }
  }

proc rosterJson(sim: SimServer): JsonNode =
  result = newJArray()
  result.add(%*{
    "s": 0,
    "team": "red",
    "name": sim.playerName,
    "alias": "Alpha",
    "pol": sim.playerName,
    "col": 0,
    "alive": not sim.ended or sim.causeOfDeath == codNone,
    "lives": max(0, sim.cog.hp),
    "hp": max(0, sim.cog.hp),
    "carry": false,
    "k": sim.monstersKilled,
    "d": (if sim.causeOfDeath == codNone: 0 else: 1),
    "cap": sim.deedCount(),
    "tk": 0
  })

proc ladderJson(sim: SimServer): JsonNode =
  ## The depth ladder: one rung per dungeon level, filled when visited,
  ## ringed when current, marked where the run ended.
  result = newJArray()
  for depth in 1 .. sim.config.dungeonLevels:
    let index = depth - 1
    result.add(%*{
      "d": depth,
      "visited": index < sim.levelTicks.len and sim.levelTicks[index] > 0,
      "current": depth == sim.cog.depth,
      "deepest": depth == sim.depthReached,
      "ticks": (if index < sim.levelTicks.len: sim.levelTicks[index] else: 0),
      "kills": (if index < sim.levelKills.len: sim.levelKills[index] else: 0),
      "gold": (if index < sim.levelGold.len: sim.levelGold[index] else: 0),
      "turns": (if index < sim.levelTurns.len: sim.levelTurns[index] else: 0),
      "grave": sim.ended and sim.endRule == erDeath and depth == sim.cog.depth
    })

proc nethackJson(sim: SimServer): JsonNode =
  var deeds = newJArray()
  for i, deed in AllDeeds:
    deeds.add(%*{"name": $deed, "earned": sim.deeds[i]})
  var lines = newJArray()
  for line in sim.observedMessages():
    lines.add(%line)
  var rows = newJArray()
  for row in sim.renderMap():
    rows.add(%row)
  %*{
    "depth": sim.cog.depth,
    "deepest": sim.depthReached,
    # The cog's CELL, so the page can keep the camera on it when the board
    # is larger than the frame (the 12px cell floor in broadcast_core.js).
    "cx": sim.cog.x,
    "cy": sim.cog.y,
    "levels": sim.config.dungeonLevels,
    "hp": max(0, sim.cog.hp),
    "maxhp": sim.cog.maxHp,
    "ac": sim.cog.ac,
    "gold": sim.cog.gold,
    "xp": sim.cog.xpPoints,
    "xlevel": sim.cog.xlevel,
    "hunger": $sim.cog.hunger,
    "nutrition": sim.cog.nutrition,
    "score": sim.score(),
    "turn": sim.turnsPlayed,
    "turns": sim.config.maxTurns,
    "kills": sim.monstersKilled,
    "meals": sim.timesAte,
    "kicks": sim.doorsKicked,
    "traps": sim.trapsTriggered,
    "seen": sim.cellsSeen(),
    "cells": LevelW * LevelH * sim.config.dungeonLevels,
    "fallbacks": sim.fallbackTurns,
    "alias": "Alpha the Digger",
    "status": sim.cog.statusLine(sim.tickCount),
    "messages": lines,
    "map": rows,
    "deeds": deeds,
    "ladder": ladderJson(sim),
    "say": sim.lastSay,
    "endRule": (if sim.endRule == erNone: "" else: $sim.endRule),
    "cause": $sim.causeOfDeath,
    "killer": sim.killer
  }

proc overJson(sim: SimServer): JsonNode =
  %*{
    "winner": "red",
    "draw": not sim.winFlag(),
    "timeLimit": sim.endRule == erTurnCap,
    "teams": {"red": {"lives": sim.score(), "prog": sim.depthReached}},
    "endRule": (if sim.endRule == erNone: "turnCap" else: $sim.endRule),
    "reason": $sim.endReason,
    "game": 1,
    "games": 1,
    "regime": sim.config.variantName()
  }

proc buildStateJson*(
  sim: var SimServer,
  events: JsonNode,
  playing: bool,
  speed, maxTick: int,
  looping, transportEnabled: bool,
  mismatchTick, startTick, endHoldSeconds: int,
  skipLulls, fastForwarding: bool,
  depthSeries: seq[seq[int]] = @[],
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE is always
  ## present, so even a frame reached by a seek hydrates the scorebug, the
  ## terminal panel and the endcard with no events.
  var state = %*{
    "t": sim.tickCount,
    "mt": max(1, sim.config.maxTicks),
    "ph": ($sim.phase).toLowerAscii,
    "lob": 0,
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "game": 1,
    "games": 1,
    "regime": sim.config.variantName(),
    "turnTicks": sim.config.turnTicks,
    "teams": teamsJson(sim),
    "roster": rosterJson(sim),
    "nh": nethackJson(sim),
    "events": (if events.isNil: newJArray() else: events)
  }
  if depthSeries.len > 0:
    var teamNames = newJArray()
    teamNames.add(%"red")
    var pts = newJArray()
    for point in depthSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": pts}
  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans
  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents
  if sim.phase == GameOver:
    state["over"] = overJson(sim)
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  $state
