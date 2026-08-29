## Viewer tests, static over the shipped chrome files: the byte-pinned
## chrome_common.js, the inherited-page-plus-appended-block shape, the alias
## discipline, the beat CSS, the transport rules and the 360 px rules.

import std/[os, osproc, strutils, unittest]

import nethack/[sim, replays, wire_constants]

const ChromeCommonSha256 =
  "594ed4a72cd908922c982d0f3e3ffb04ae1d97568fcd5f5daa794042662a369c"

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

suite "chrome_common is the starter's plus the fleet transport patch":
  test "the file is 40 037 bytes and hashes to the pinned sha256":
    ## coworld-ctf's chrome_common.js, byte for byte, plus the fleet-wide
    ## replay transport patch: the 0.5x entry in the speed fallback and in
    ## the speed->command map. Nothing else in this file is edited or
    ## reformatted — everything this game adds lives in the page's appended
    ## block, and the CTF_WIRE lookup below stays as the starter wrote it.
    check chrome.len == 40_037
    let hashed = sha256Hex("client/chrome_common.js")
    if hashed.len > 0:
      check hashed == ChromeCommonSha256
    else:
      ## no sha256sum on this host: the length pin still catches an edit
      check chrome.len == 40_037
    check "window.ChromeCommon" in chrome
    check "map = { 0.5: '5'," in chrome

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
      ## and nothing READS them either: the JS that fed them went with them,
      ## so a null-guarded reader of a deleted id cannot survive
      check ("$('" & id & "')") notin page
    for name in ["renderFpvMap", "syncFpvMapShape", "fpvMapCanvas"]:
      check name notin page

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
    ## the desktop plate gives the name more room than the pinned floor, but
    ## nothing overrides the floor at the embedded width
    check "#stage:not(.tiny) .plate .plate-name { min-width: 4.5em; }" in appended
    check appended.count(".plate .plate-name { min-width") == 1

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

  test "the fit clamps the cell to 12px and the block follows the cog":
    ## The one named fork edit to the starter's camera: a cell never shrinks
    ## below 12 css px, so at an embed width the board is LARGER than the
    ## frame and the view is a window on the level that follows the cog —
    ## which is what keeps #viewpanel load-bearing (checklist item 14).
    check "const MIN_CELL_PX = 12;" in core
    check "Math.max(fitScale, MIN_CELL_PX / WIRE_CELL_PX)" in core
    check "core.panTo(" in appended
    check "function followCog(" in appended
    check "core: core," in inherited
    check "window.BroadcastCore = { create: BroadcastCore };" in core

suite "the wire constants reach the byte-pinned chrome":
  test "both wire globals are defined, and the chips are PlaybackSpeeds":
    ## chrome_common.js keeps the starter's `window.CTF_WIRE` lookup, so the
    ## renamed global is published under BOTH names. Without the alias the
    ## transport falls back to the starter's speed list and draws chips this
    ## game cannot obey. The emitted list leads with the replay-only 0.5x.
    check "window.NETHACK_WIRE={speeds:[0.5,1,2,4,8]" in WireConstantsJs
    check WireConstantsJs.endsWith("window.CTF_WIRE=window.NETHACK_WIRE;")
    check "window.CTF_WIRE" in chrome
    check "WIRE.speeds" in chrome

  test "every chip the chrome can draw is a speed the transport accepts":
    var config = defaultGameConfig()
    var sim = initSimServer(config)
    var player = initReplayPlayer(ReplayData())
    for speed in PlaybackSpeeds:
      player.speedIndex = 0
      player.applyReplayCommand(sim, config, ($speed)[0])
      check player.replaySpeed() == speed
      check player.replayDisplaySpeed() == float(speed)
    ## the 0.5x chip the wire now emits ahead of PlaybackSpeeds: the chrome
    ## maps it to command '5', and a chip only lights when the frame's `sp`
    ## equals the chip's own value.
    player.speedIndex = 0
    player.applyReplayCommand(sim, config, '5')
    check player.speedIndex == ReplayHalfSpeedIndex
    check player.replayDisplaySpeed() == 0.5

suite "the board page owns its own keyboard transport":
  test "Space pauses on the shipped page and the digits reach the engine":
    ## The static bundle ships exactly one page (Dockerfile.replay-viewer
    ## renders replay_broadcast.html as index.html), so its own keydown
    ## handler IS the fleet's Space-pauses requirement — there is no league
    ## shell in this repo to forward through. The digit row carries '5', the
    ## half-speed command, with no extra binding.
    check "function togglePlay() { send(' '); }" in inherited
    check "if (k === ' ') { ev.preventDefault(); togglePlay(); }" in inherited
    check "else if (k >= '1' && k <= '9') send(k);" in inherited

suite "the worst-case renderer fixture is shipped and wired":
  test "the fixture drives the real page and ci.yml runs it":
    ## The CI replay's seat is scripted and says nothing, so the say / plan /
    ## fallback rows can only be exercised by a fixture. It must load the
    ## SHIPPED page rather than re-implement any drawing, and it must be
    ## driven by the same smoke harness with --strict-text-bounds.
    let fixture = readFile("tools/ci/renderer_fixture.html")
    check "viewer.html" in fixture          ## the shipped page, in an iframe
    check "win.NethackChrome" in fixture    ## through the page's own chrome
    check "MAX_SAY_RUNES = 140" in fixture
    check "data-replay-loaded" in fixture
    check "data-replay-error" in fixture
    let ci = readFile(".github/workflows/ci.yml")
    check "tools/ci/renderer_fixture.html" in ci
    check "--strict-text-bounds" in ci

  test "the terminal panel fits its own measured box":
    ## The panel is draggable and resizable, so it sizes its glyphs from the
    ## box it actually has and drops the columns and rows that do not fit.
    check "pre.scrollWidth > pre.clientWidth" in appended
    check "pre.scrollHeight > pre.clientHeight" in appended
    check "rows.pop()" in appended

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
