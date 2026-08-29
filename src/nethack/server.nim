## The game server: the mummy HTTP/websocket server implementing the Coworld
## contract, the lobby, the per-turn decision loop, the tick loop, the replay
## writer, the artifact writes and the wall-clock stop.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with its three named
## edits:
##
##  1. TURN BOUNDARY — unchanged in shape, with a variable turn length (the
##     tick loop breaks early when the run ends or the cog changes level) and
##     ONE seat in the batch.
##  2. REGISTRATION INTERCEPTION — the seat's Sprite v1 chat message whose
##     text parses as a registration object is consumed as registration, not
##     applied as speech and not written to the replay chat stream; the
##     server writes a REDACTED `register` record instead, and it logs loudly
##     and refuses to start the game when the joined seat never registered.
##  3. WALL-CLOCK STOP — the starter's `wallClockBudgetSeconds` check at the
##     top of every loop iteration, kept, forcing `reason = deadline`,
##     `endRule = wallClock`, and written as a LOAD-BEARING stop record.

import std/[json, locks, monotimes, os, strutils, tables, times]

import bitworld/runtime, bitworld/spriteprotocol
import mummy

import sim, driver, decide, directives, baselines, replays, replay_runtime,
  broadcast, global, events, wire_constants

type
  AppState = object
    lock: Lock
    playerSlots: Table[WebSocket, int]
    playerChat: Table[WebSocket, string]
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]
    joinedSlot: int
    config: GameConfig
    replayMode: bool
    replayBytes: string

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  PlayerWebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  ReplayWebSocketPath = "/replay"
  ReplayClientPath = "/client/replay"
  GlobalClientPath = "/client/global"
  PlayerClientPath = "/client/player"
  ReplayDataPath = "/replay-data"
  BroadcastFontPath = "/client/font.ttf"
  MaxWsFrameBytes = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (1009). The board
    ## sprite is one message, so it is kept comfortably under the cap.

  EmbeddedBroadcastHtml = staticRead("../../client/replay_broadcast.html")
    .replace("<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
    .spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")

var appState: AppState

proc initAppState() =
  initLock(appState.lock)
  appState.joinedSlot = -1

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc queryValue(request: Request, name: string): string =
  request.queryParams.getOrDefault(name, "")

proc tokenMatches(config: GameConfig, slot: int, token: string): bool =
  ## The player websocket handler CLOSES unless the token matches the seat:
  ## the certifier probes with a bad token, and a server that accepted it
  ## would seat the probe (cogame-flatland 0.1.1).
  if slot < 0 or slot >= max(1, config.numAgents):
    return false
  if config.tokens.len == 0:
    return true
  slot < config.tokens.len and config.tokens[slot] == token

proc respondText(request: Request, status: int, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(status, headers, body)

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, body)

proc httpHandler(request: Request) {.gcsafe.} =
  if request.path == HealthPath and request.httpMethod == "GET":
    request.respondText(200, "healthy")
  elif request.path == PlayerWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = try: parseInt(request.queryValue("slot")) except ValueError: -1
      token = request.queryValue("token")
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = appState.config.tokenMatches(slot, token) and
          not appState.replayMode
    if not allowed:
      request.respondText(403, "forbidden\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerSlots[websocket] = slot
        appState.joinedSlot = slot
    echo "player connected: slot ", slot
  elif (request.path == GlobalWebSocketPath or
        request.path == ReplayWebSocketPath) and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.queryValue("token").len > 0 or
        request.queryValue("slot").len > 0:
      request.respondText(403, "viewer sockets take no player credentials\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == PlayerClientPath and request.httpMethod == "GET":
    ## Served for real and token-checked, and it must NOT open the player
    ## socket: this is a browser probe, not a seat.
    let
      slot = try: parseInt(request.queryValue("slot")) except ValueError: 0
      token = request.queryValue("token")
    var ok = false
    {.gcsafe.}:
      withLock appState.lock:
        ok = appState.config.tokenMatches(slot, token)
    if not ok:
      request.respondText(403, "forbidden\n")
      return
    request.respondHtml(EmbeddedBroadcastHtml)
  elif (request.path == ReplayClientPath or request.path == GlobalClientPath) and
      request.httpMethod == "GET":
    request.respondHtml(EmbeddedBroadcastHtml)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var bytes = ""
    {.gcsafe.}:
      withLock appState.lock:
        bytes = appState.replayBytes
    if bytes.len == 0:
      request.respondText(404, "no replay loaded\n")
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    request.respond(200, headers, bytes)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  else:
    request.respondText(200, "nethack server")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) {.gcsafe.} =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerSlots:
            let text = message.data.readSpriteInputText()
            if text.len > 0:
              appState.playerChat[websocket] = text
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"delver"|null,"policy":"…"}
  ## Anything that is not that object is not a registration; any other chat
  ## text from the seat is dropped — the cog speaks through `say`.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly {"message","failed_policy_index"},
  ## nothing else. Best-effort: a declaration write failure must never mask
  ## the episode's own outcome.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "player-failure declaration failed: ", error.msg

proc broadcastPacket(packet: seq[uint8]) =
  ## Global broadcasts are fire-and-forget, so a slow viewer can never stall
  ## the episode.
  if packet.len == 0 or packet.len > MaxWsFrameBytes:
    if packet.len > MaxWsFrameBytes:
      echo "nethack: dropping an oversized viewer packet (", packet.len, " B)"
    return
  let blob = blobFromBytes(packet)
  var sockets: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for socket in appState.globalViewers.keys:
        sockets.add(socket)
  for socket in sockets:
    try:
      socket.send(blob, BinaryMessage)
    except CatchableError:
      discard

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  var config = initialConfig
  let replayMode = loadReplayPath.len > 0

  var
    sim: SimServer
    replay: ReplayPlayer
    replayLoaded = false

  if replayMode:
    try:
      let data = loadReplay(loadReplayPath)
      var initialised = initReplayRuntime(data, runtimeConfig.mismatchQuit)
      config = initialised.config
      sim = initialised.sim
      replay = initialised.player
      replayLoaded = true
    except CatchableError as error:
      echo "replay load failed (serving without replay): ", error.msg
      sim = initSimServer(config)
  else:
    sim = initSimServer(config)

  {.gcsafe.}:
    withLock appState.lock:
      appState.config = config
      appState.replayMode = replayLoaded
      if replayLoaded:
        try:
          appState.replayBytes = readFile(loadReplayPath)
        except CatchableError:
          discard

  var replayWriter =
    if replayMode: ReplayWriter()
    else: openReplayWriter(saveReplayPath, config.configJson())
  defer: replayWriter.closeReplayWriter()

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)

  loadArt()

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 2)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
               ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()
  echo "nethack listening on ", host, ":", port

  var
    engine = initDecisionEngine(sim)
    episodeStart = getMonoTime()
    lobbyTicks = 0
    started = replayLoaded
    registered = false
    artifactsWritten = false
    gameOverHeld = 0
    eventRows: seq[JsonNode] = @[]
    turnIndex = 0

  if not replayLoaded:
    sim.phase = Lobby

  proc elapsedSeconds(): int = (getMonoTime() - episodeStart).inSeconds.int

  proc writeArtifacts() =
    if artifactsWritten:
      return
    artifactsWritten = true
    let results = sim.runResultsJson()
    try:
      if not replayMode:
        replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
        replayWriter.closeReplayWriter()
    except CatchableError as error:
      echo "replay close failed: ", error.msg
    try:
      runtimeConfig.writeResults(results)
    except CatchableError as error:
      echo "results write failed: ", error.msg
    if not replayMode and saveReplayPath.len > 0:
      try:
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      except CatchableError as error:
        echo "replay upload failed: ", error.msg
    if eventsPath.len > 0:
      try:
        createDir(eventsPath.parentDir())
        writeFile(eventsPath, eventsJsonl(eventRows, sim.tickCount))
      except CatchableError as error:
        echo "events write failed: ", error.msg
    echo "nethack results: ", results

  while true:
    # --- the engine's own hard stop, checked before anything else ----------
    if not replayLoaded and sim.phase == Playing and
        elapsedSeconds() >= config.wallClockBudgetSeconds:
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode at this tick"
      replayWriter.writeChat(tickTime(sim.tickCount), 0,
                             stopRecord(sim.tickCount, "wallClock"))
      sim.endRun(erWallClock, codNone, "")

    var
      closed: seq[WebSocket] = @[]
      chatTexts: seq[string] = @[]
      seekTicks: seq[int] = @[]
      commands: seq[char] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        closed = appState.closedSockets
        appState.closedSockets.setLen(0)
        for socket, text in appState.playerChat.pairs:
          chatTexts.add(text)
        appState.playerChat.clear()
        for socket, state in appState.globalViewers.mpairs:
          if state.replaySeekTick >= 0:
            seekTicks.add(state.replaySeekTick)
            state.replaySeekTick = -1
          for command in state.replayCommands:
            commands.add(command)
          state.replayCommands.setLen(0)
    for socket in closed:
      {.gcsafe.}:
        withLock appState.lock:
          if socket in appState.playerSlots:
            appState.playerSlots.del(socket)
            sim.deadSeat = true
          if socket in appState.globalViewers:
            appState.globalViewers.del(socket)
          if socket in appState.playerChat:
            appState.playerChat.del(socket)

    for text in chatTexts:
      let registration = parseRegistration(text)
      if not registration.ok:
        continue
      if registration.prompt.len > 0:
        engine.seat.isLlm = true
        engine.seat.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
      else:
        engine.seat.isLlm = false
        engine.seat.baseline = parseBaseline(registration.scripted)
      engine.seat.label = registration.policy.truncateRunes(MaxPolicyLabelRunes)
      engine.seat.registered = true
      if engine.seat.label.len > 0:
        ## The seat's REAL policy name is spectator-side only: it lives in
        ## results.names, in the replay's join record and on the scorebug
        ## plate, and never in an observation, a prompt or a board label.
        sim.playerName = engine.seat.label
      if not registered:
        registered = true
        sim.policyKind = engine.policyKind()
        sim.registered = true
        echo "nethack: seat registered kind=", sim.policyKind,
          " baseline=", $engine.seat.baseline, " label=", engine.seat.label
        replayWriter.writeChat(tickTime(sim.tickCount), 0, registerRecord(
          0, "Alpha", engine.seat.label, sim.policyKind,
          (if engine.seat.isLlm: "" else: $engine.seat.baseline)))

    if replayLoaded:
      let events = advanceReplayFrame(replay, sim, config, seekTicks, commands)
      var packets: seq[seq[uint8]] = @[]
      {.gcsafe.}:
        withLock appState.lock:
          for socket, state in appState.globalViewers.mpairs:
            var nextState = state
            packets.add(sim.buildReplayViewerPacket(replay, state, nextState,
                                                    events))
            state = nextState
      for packet in packets:
        broadcastPacket(packet)
      sleep(1000 div TargetFps)
      continue

    ## FAULT — an unexpected exception in the sim or in this loop is
    ## CAUGHT: the episode is settled from the last completed tick with
    ## endRule = fault, the stop is written as the same load-bearing
    ## record the wall-clock stop uses so playback settles on the same
    ## tick, the artifacts are still written, and the process exits 0. A
    ## crash out of this loop would leave no results.json at all.
    try:
      case sim.phase
      of Lobby:
        var joined = false
        {.gcsafe.}:
          withLock appState.lock:
            joined = appState.playerSlots.len > 0
        inc lobbyTicks
        if joined and registered:
          replayWriter.writeJoin(tickTime(0), 0, sim.playerName, 0, "")
          sim.phase = Playing
          started = true
          echo "nethack: the descent begins"
        elif lobbyTicks > config.lobbyJoinTimeoutTicks:
          if joined and not registered:
            ## The grf-football 2026-08-27 scar: never silently default a
            ## joined-but-unregistered seat into a scripted policy.
            echo "::error::the joined seat never sent a registration record; ",
              "refusing to start it as a silent default"
          declarePlayerFailure(0,
            "the seat never joined and registered inside the lobby budget")
          sim.deadSeat = true
          replayWriter.writeJoin(tickTime(0), 0, sim.playerName, 0, "")
          sim.phase = Playing
          started = true
        else:
          var packets: seq[seq[uint8]] = @[]
          {.gcsafe.}:
            withLock appState.lock:
              for socket, state in appState.globalViewers.mpairs:
                var nextState = state
                var packet = sim.buildBoardPacket(state, nextState)
                packet.addChrome(sim.buildStateJson(
                  newJArray(), false, 1.0, max(1, config.maxTicks), false,
                  false, -1, 0, 0, false, false))
                packets.add(packet)
                state = nextState
          for packet in packets:
            broadcastPacket(packet)
          ## Keep a frame flowing to the seat so its registration re-send has
          ## something to key on (the paintball 2026-08-25 slot-sequential-join
          ## scar); the seat sends no inputs, so this is purely a heartbeat.
          var seats: seq[WebSocket] = @[]
          {.gcsafe.}:
            withLock appState.lock:
              for socket in appState.playerSlots.keys:
                seats.add(socket)
          for socket in seats:
            try:
              socket.send(blobFromSpriteChat("tick"), BinaryMessage)
            except CatchableError:
              discard
          sleep(1000 div TargetFps)
      of Playing:
        inc turnIndex
        let outcome = engine.turn(sim, turnIndex, elapsedSeconds())
        for record in outcome.records:
          replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        let observation = sim.observationJson(turnIndex, includeMap = false)
        sim.lastSay = outcome.reply.say
        ## Read by beginTurn when it derives this turn's `fallback` event;
        ## only a turn whose plan actually came from the fallback path
        ## carries one.
        sim.lastFallbackCause =
          if outcome.reply.source == dsFallback: outcome.cause else: ""
        var runner = sim.beginTurn(outcome.reply.actions, outcome.reply.dropped)
        while not sim.turnDone(runner):
          sim.stepTurn(runner)
          replayWriter.writeHash(tickTime(sim.tickCount), sim.gameHash())
          if eventsPath.len > 0:
            if sim.executedVerb.len > 0:
              eventRows.add(primitiveRow(sim.tickCount, sim.cog.depth,
                                         sim.executedVerb))
            for event in sim.events:
              let row = jsonRow(event)
              if row{"kind"}.getStr().len > 0:
                eventRows.add(row)
        sim.endTurn()
        replayWriter.writeChat(tickTime(sim.tickCount), 0,
          boundedDirectiveRecord(outcome.reply, turnIndex, sim.cog.depth, 0,
                                 "Alpha", sim.lastExecuted, sim.lastTruncated,
                                 sim.lastDropped, sim.lastUnreachable,
                                 observation))
        let events = sim.drainEvents()
        var packets: seq[seq[uint8]] = @[]
        {.gcsafe.}:
          withLock appState.lock:
            for socket, state in appState.globalViewers.mpairs:
              var nextState = state
              var packet = sim.buildBoardPacket(state, nextState)
              packet.addChrome(sim.buildStateJson(
                events, true, 1.0, max(1, sim.tickCount), false, true, -1, 0,
                0, false, false))
              packets.add(packet)
              state = nextState
        for packet in packets:
          broadcastPacket(packet)
      of GameOver:
        if not artifactsWritten:
          writeArtifacts()
        inc gameOverHeld
        if gameOverHeld > config.gameOverTicks:
          break
        sleep(1000 div TargetFps)
    except CatchableError as error:
      echo "::error::nethack: fault — ", error.msg
      if not sim.ended:
        try:
          replayWriter.writeChat(tickTime(sim.tickCount), 0,
                                 stopRecord(sim.tickCount, "fault"))
        except CatchableError as writeError:
          echo "fault stop record failed: ", writeError.msg
        sim.settleFault(error.msg)
      writeArtifacts()
      break

  echo "nethack: episode complete (reason=", $sim.endReason, " endRule=",
    $sim.endRule, " depth=", sim.depthReached, " score=", sim.score(), ")"
  quit(0)
