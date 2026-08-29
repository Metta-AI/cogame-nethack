import
  std/json,
  nethack/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  config: GameConfig
  game: SimServer
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable
## from JS after the abort (aborting kills the call stack, not the linear
## memory), so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc nethackLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "nethack_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    ## The load-time PRE-SCAN lives in initReplayRuntime: it re-simulates the
    ## whole episode once headlessly (2 200 ticks over 864-cell levels — a
    ## few milliseconds in wasm) and records the depth series, the beat ticks
    ## and the lull spans, so the depth ladder, the sparkline and the
    ## scrubber beats draw at FULL WIDTH on the first frame.
    var initialised = initReplayRuntime(replayData, mismatchQuit = false)
    config = initialised.config
    game = move(initialised.sim)
    replay = move(initialised.player)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    frameStage = "advance replay"
    stampStage("render first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc nethackInput(data: ptr uint8, length: cint)
    {.exportc: "nethack_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc nethackFrame(): cint {.exportc: "nethack_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game, config, seekTicks, viewer.replayCommands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc nethackPacketPointer(): ptr uint8
    {.exportc: "nethack_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc nethackPacketLength(): cint {.exportc: "nethack_packet_len", cdecl.} =
  cint(packet.len)

proc nethackMismatchTick(): cint {.exportc: "nethack_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(replay.checkReplayHash()) else: -1

proc nethackErrorPointer(): ptr uint8 {.exportc: "nethack_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc nethackErrorLength(): cint {.exportc: "nethack_error_len", cdecl.} =
  cint(lastError.len)

proc nethackStagePointer(): ptr uint8 {.exportc: "nethack_stage_ptr", cdecl.} =
  ## The progress note. Unlike nethack_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc nethackStageLength(): cint {.exportc: "nethack_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the sim, the art chips and the replay — everything — while the
  # wasm module stays alive and JS keeps calling nethack_load_replay /
  # nethack_frame. Unwinding main through emscripten's live-runtime exit
  # skips the destructor epilogue entirely, so globals stay valid for the
  # life of the page.
  emscriptenExitWithLiveRuntime()
