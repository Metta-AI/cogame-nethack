## The documented private scratchpad must survive from one decision to the next.
import std/[json, strutils, unicode, unittest]
import nethack/[sim, driver, directives]

suite "private policy memory":
  test "accepted notes reach the next observation, not the current record":
    var config = defaultGameConfig()
    config.seed = 42
    var game = initSimServer(config)
    let current = game.observationJson(1, false)
    var reply = parseReply(%*{
      "actions": [{"do": "wait"}],
      "notes": "DL1 target east; blocked 7,15 south\n" & repeat("界", 450)
    }, {}, config.maxActionsPerTurn)
    reply.source = dsLlm
    game.applyReplyMetadata(reply)
    game.playTurn(reply.actions, reply.dropped)
    let next = game.observationJson(2, false)
    check current["notes"].getStr() == ""
    check next["notes"].getStr() == reply.notes
    check next["notes"].getStr().runeLen == 400
    check '\n' notin next["notes"].getStr()

  test "fallback and scripted turns preserve the last accepted scratchpad":
    var game = initSimServer(defaultGameConfig())
    game.applyReplyMetadata(ParsedReply(source: dsLlm, notes: "DL1 east door"))
    for source in [dsFallback, dsScripted]:
      game.applyReplyMetadata(ParsedReply(source: source, notes: "discard this"))
      game.playTurn(@[Action(verb: vWait, item: -1)], 0)
      check game.observationJson(2, false)["notes"].getStr() == "DL1 east door"

  test "a valid model reply can clear memory without changing core state":
    var game = initSimServer(defaultGameConfig())
    game.applyReplyMetadata(ParsedReply(source: dsLlm, notes: "old target"))
    let before = game.gameHash()
    game.applyReplyMetadata(ParsedReply(source: dsLlm, notes: "", say: "descend"))
    check game.observationJson(2, false)["notes"].getStr() == ""
    check game.lastSay == "descend"
    check game.gameHash() == before
