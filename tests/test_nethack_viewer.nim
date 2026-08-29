## Viewer tests, static over the shipped chrome files: the byte-identical
## chrome_common.js, the inherited-page-plus-appended-block shape, the alias
## discipline, the beat CSS, the transport rules and the 360 px rules.

import std/[os, osproc, strutils, unittest]

const ChromeCommonSha256 =
  "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"

let
  page = readFile("client/replay_broadcast.html")
  core = readFile("client/broadcast_core.js")
  chrome = readFile("client/chrome_common.js")
  starterMarker = "NETHACK additions to the inherited coworld-ctf chrome"
  blockStart = page.find(starterMarker)
  inherited = page[0 ..< blockStart]
  appended = page[blockStart .. ^1]

proc sha256Hex(path: string): string =
  ## Nim's stdlib ships SHA-1 only, so the byte pin is checked with the
  ## system's sha256sum — the same digest the design note records.
  try:
    let raw = execProcess("sha256sum", args = [path], options = {poUsePath})
    result = raw.strip().split(' ')[0]
  except CatchableError:
    result = ""

suite "chrome_common is byte-identical to the starter's":
  test "the file is 40 022 bytes and hashes to the pinned sha256":
    check chrome.len == 40_022
    let hashed = sha256Hex("client/chrome_common.js")
    if hashed.len > 0:
      check hashed == ChromeCommonSha256
    else:
      ## no sha256sum on this host: the length pin still catches an edit
      check chrome.len == 40_022
    check "window.ChromeCommon" in chrome

suite "the broadcast page is the starter's plus an appended block":
  test "the inherited half still carries the starter's structure":
    check blockStart > 200_000
    for id in ["viewport", "stage", "board", "lightpool", "grain",
               "lockerroom", "lk-bg", "lk-art", "lk-sprites", "lk-cap",
               "chrome", "scorebug", "plates-l", "plates-r", "clock",
               "clock-time", "clock-caption", "ffwd-mini", "viewpanel",
               "minimap", "minimap-canvas", "zoombar", "zoom-in", "zoom-out",
               "zoom-slider", "zoom-read", "fpv", "fpv-canvas", "fpv-hud",
               "fpv-name", "fpv-cap", "fpv-grip", "bannerlane", "killfeed",
               "mmwarn", "transport", "btn-restart", "btn-back", "btn-play",
               "btn-fwd", "btn-end", "btn-loop", "btn-skip", "btn-spoilers",
               "ffwd-chip", "win-chip", "tick-clock", "speedchips", "scrub",
               "momentum", "scrub-fill", "lulls", "scrub-win", "scrub-head",
               "endcard", "ec-headline", "ec-wincond", "ec-how", "ec-teams",
               "ec-replay", "status"]:
      check ("id=\"" & id & "\"") in inherited
    check "core.attachMinimap($('minimap-canvas'))" in inherited
    check "window.NethackChrome.install(PB_CTX)" in inherited

  test "the removed elements appear nowhere in the page":
    for id in ["povBadge", "fpv-hp", "fpv-gear", "fpv-map", "fpv-map-canvas"]:
      check ("id=\"" & id & "\"") notin page

  test "the appended block only appends":
    check appended.startsWith(starterMarker)
    check "window.NethackChrome = {" in appended
    check "install: function (ctx)" in appended

suite "no shadowed chrome aliases":
  test "the beat builder is nhBeat and the block never declares markBeat":
    check "function nhBeat(" in appended
    check "function markBeat(" notin appended
    check "var markBeat" notin appended
    for alias in ["renderClock", "renderTransport", "ingestBeats",
                  "ingestLullSpans", "recordMomentum", "setVerdict",
                  "pushFeed", "banner", "activeTeams", "teamCol"]:
      check ("function " & alias & "(") notin appended

suite "beat CSS matches the emitted kinds exactly":
  test "there is one .beat-marker rule per kind and no others":
    const kinds = ["descend", "ascend", "levelup", "deed", "oracle", "death",
                   "bottom", "escaped", "fallback", "end"]
    for kind in kinds:
      check (".beat-marker." & kind & " ") in appended or
        (".beat-marker." & kind & "\n") in appended or
        (".beat-marker." & kind & "{") in appended
    for stale in ["kill", "steal", "return", "capture", "gamestart",
                  "hillflip", "tagout", "gameover"]:
      check (".beat-marker." & stale) notin page
    check "el.setAttribute('aria-label', label)" in appended
    check "document.createElement('button')" in appended

suite "transport, endcard, viewpanel and the 360 px rules":
  test "relayout owns --band, --topband and --hudscale on :root":
    check "root.style.setProperty('--hudscale'" in inherited
    check "root.style.setProperty('--topband'" in inherited
    check "root.style.setProperty('--band'" in inherited
    check "stage.classList.toggle('tiny', boardW <= 620)" in inherited

  test "the endcard stops at the band and every seek dismisses it":
    check "bottom: var(--band, 0px)" in inherited
    check "$('endcard').classList.remove('on')" in inherited

  test "no game-block overlay is positioned inside the transport band":
    ## every addition is anchored to the top band or to the board region
    check "top: calc(var(--topband, 0px)" in appended
    check "bottom: 0" notin appended
    check "bottom:0" notin appended

  test "the plate name survives a 360 px iframe":
    check ".plate-name {" in appended
    check "flex: 1 1 auto;" in appended
    check "min-width: 3.2em;" in appended
    check "text-overflow: ellipsis" in appended

  test "the five .tiny rules exist":
    check "#stage.tiny .plate .nh-stats" in appended
    check "#stage.tiny #nh-deeds .deed" in appended
    check "#stage.tiny #nh-ladder .rung i" in appended
    check "#stage.tiny #nh-term" in appended
    check "#stage.tiny #fpv-grip" in appended

suite "broadcast_core keeps the starter's draw layer":
  test "the kept procs are the starter's, with only the wire rename":
    for name in ["function BroadcastCore(", "function attachMinimap(",
                 "function drawMinimap(", "function relayout",
                 "function pushFeed", "function composite(",
                 "function computeFit(", "function zoomAt(",
                 "function setViewportSize(", "function ingest("]:
      if name == "function relayout" or name == "function pushFeed":
        continue      ## those two live in the page / the shared chrome
      check name in core
    check "window.NETHACK_WIRE" in core
    check "window.CTF_WIRE" notin core
    check "window.BroadcastCore = { create: BroadcastCore };" in core

suite "the static shell signals load and failure on <html>":
  test "static_replay.js sets data-replay-loaded and data-replay-error":
    let shell = readFile("replay-viewer/static_replay.js")
    check "setAttribute('data-replay-loaded', 'true')" in shell
    check "'data-replay-error'" in shell
    check "static_replay_worker.js" in shell
    check "window.NethackStaticReplay" in shell

  test "the worker waits for onRuntimeInitialized and imports in order":
    let worker = readFile("replay-viewer/static_replay_worker.js")
    check "Module.onRuntimeInitialized" in worker
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./nethack_replay.js')" in worker
    check "_nethack_load_replay" in worker
    check "_nethack_frame" in worker

  test "the emscripten link flags match the shell that starts the module":
    let config = readFile("replay-viewer/config.nims")
    check "-s ABORTING_MALLOC=1" in config
    check "-s ALLOW_MEMORY_GROWTH" in config
    check "-s ENVIRONMENT=web,worker,node" in config
    check "_nethack_load_replay" in config
    check "MODULARIZE" notin config      ## the paintbot lineage does not
    check "EXPORT_NAME" notin config     ## use the factory bootstrap
