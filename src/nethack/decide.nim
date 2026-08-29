## The decision layer: the per-turn loop that asks the seat what the cog does
## next, and always has an answer.
##
## Cadence: one command turn every `turnTicks` (40 dungeon turns), at most 55
## turns per episode. There is exactly ONE seat, so the starter's
## one-parallel-batch-per-turn machinery (`curly.makeRequests`) carries a
## batch of one and is otherwise untouched: at most `55 x 2 = 110` provider
## calls per episode, and never more than one in flight.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`,
## the single retry gets `retryMs`, the whole turn is wrapped in a monotonic
## `turnBudgetMs` deadline, a rolling 60 s request counter refuses a call
## that would breach the sidecar's per-episode cap, and the budget guard
## switches the LLM off entirely when two more full turns would not fit. On a
## second failure the turn's plan becomes the `delver` scripted plan computed
## inside the game — the SAME proc the `delver` baseline uses, imported and
## never duplicated — and a `fallback` record names the cause.

import std/[json, monotimes, os, strutils, times]

import curly

import sim, driver, directives, baselines, llm

type
  SeatPolicy* = object
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seat*: SeatPolicy
    state*: BaselineState
    params*: BaselineParams
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool
    requestTicks*: seq[MonoTime]

const
  FallbackCauses* = [
    "timeout", "parse_error", "transport_error", "no_credentials",
    "rate_guard", "budget_guard", "disconnected"]
    ## The CLOSED cause vocabulary of the design note's fallback record. A
    ## provider 429 is a `rate_guard` cause like the engine's own trailing-60s
    ## refusal is: both mean "the rate cap said no". `disconnected` is
    ## declared here because the note declares it; with one seat whose socket
    ## carries nothing but its registration, nothing in this fork can produce
    ## it, and inventing a cause outside this list is what F11 was.
  RateGuardWindowRequests = 28
    ## The sidecar caps 30 requests/minute per episode. `turnSpacingMs` pins
    ## the steady state at 23/min, but a run of retrying turns issues two
    ## each — so a turn that would push the trailing-60 s count past this
    ## takes the `delver` plan instead. Bounded, logged, and never a sleep on
    ## the episode's critical path.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.params = DefaultBaselineParams
  result.seat.baseline = blDelver
  result.seat.label = "delver"

proc policyKind*(engine: DecisionEngine): string =
  if engine.seat.isLlm: "llm" else: "scripted"

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(slot: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, endRule: string): string =
  ## The load-bearing wall-clock/fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is written as one record applied by the
  ## same proc on record and on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": endRule})

proc resultRecord*(sim: SimServer): string =
  ## The episode's whole results document, written once into the replay chat
  ## stream at episode end. It is what makes the replay SELF-SUFFICIENT.
  "{\"k\":\"result\",\"results\":" & sim.runResultsJson() & "}"

proc inventoryLetters*(sim: SimServer): set[char] =
  for letter in 0 ..< MaxInventory:
    if sim.cog.inv[letter].kind != ikNone:
      result.incl(chr(ord('a') + letter))

proc delverReply*(engine: var DecisionEngine, sim: SimServer): ParsedReply =
  ## The scripted plan, as a ParsedReply, so it travels the same path an LLM
  ## reply does.
  result.actions = delverPlan(sim, engine.params)
  result.source = dsFallback

proc scriptedReply*(engine: var DecisionEngine, sim: SimServer): ParsedReply =
  result.actions = scriptedPlan(engine.state, sim, engine.seat.baseline,
                                engine.params)
  result.source = dsScripted

proc recentRequests(engine: DecisionEngine): int =
  let now = getMonoTime()
  for stamp in engine.requestTicks:
    if (now - stamp).inSeconds < 60:
      inc result

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, elapsedSeconds: int
): tuple[reply: ParsedReply, records: seq[string]] =
  ## Runs ONE decision turn. Never raises: every failure path ends in a legal
  ## plan.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.records.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "nethack: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  if not engine.seat.isLlm:
    result.reply = engine.scriptedReply(sim)
    return

  if engine.llmOff or engine.client.disabled:
    let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
    result.reply = engine.delverReply(sim)
    inc sim.fallbackTurns
    result.records.add(fallbackRecord(turnIndex, 1, cause,
      "the LLM is unavailable for this turn; playing delver"))
    echo "nethack llm: seat falling back to delver (", cause, ") on turn ",
      turnIndex
    return

  if engine.recentRequests() >= RateGuardWindowRequests:
    result.reply = engine.delverReply(sim)
    inc sim.fallbackTurns
    result.records.add(fallbackRecord(turnIndex, 1, "rate_guard",
      "the trailing-60s request count would breach the provider cap"))
    echo "nethack llm: seat falling back to delver (rate_guard) on turn ",
      turnIndex
    return

  # --- the rate floor ------------------------------------------------------
  if engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true

  let observation = $sim.observationJson(turnIndex, includeMap = true)
  var attempt = 0
  var lastCause = "parse_error"
  var lastDetail = ""
  while attempt < 2:
    if getMonoTime() - turnStart >= budget:
      result.records.add(fallbackRecord(turnIndex, attempt + 1, "timeout",
        "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var user = observation
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY the " &
        "JSON object described above, starting with '{'.")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seat.prompt, user))
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, "0")
    let started = getMonoTime()
    engine.requestTicks.add(started)
    if engine.requestTicks.len > 256:
      engine.requestTicks.delete(0)
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is
    ## WHOLE SECONDS, so this conversion FLOORS — and sim_config rejects a
    ## non-whole-second value, so the floor below is an identity.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    try:
      let text = engine.client.textOf(
        responses[0].response, responses[0].error, request.url)
      var reply = parseReply(extractJsonObject(text),
                             sim.inventoryLetters(),
                             sim.config.maxActionsPerTurn)
      reply.source = dsLlm
      reply.latencyMs = latency
      inc sim.llmTurns
      sim.repliesRepaired += reply.repaired
      result.reply = reply
      return
    except CatchableError as error:
      lastDetail = error.msg
      if responses[0].error.len > 0:
        lastCause =
          if "timeout" in responses[0].error.toLowerAscii(): "timeout"
          else: "transport_error"
      elif error.msg.startsWith("llm throttled"):
        lastCause = "rate_guard"
      else:
        lastCause = "parse_error"
      result.records.add(
        fallbackRecord(turnIndex, attempt + 1, lastCause, error.msg))
      if attempt == 0:
        ## The attempt-1 notice says "will retry"; only a genuine SECOND
        ## failure logs "falling back" (the phrase phase 60 greps for).
        echo "nethack llm: attempt 1 failed, will retry: ", error.msg
      inc attempt
      if engine.client.throttled or engine.client.disabled:
        break

  result.reply = engine.delverReply(sim)
  inc sim.fallbackTurns
  let cause =
    if engine.client.disabled or engine.client.transport == ltNone:
      "no_credentials"
    elif engine.client.throttled: "rate_guard"
    else: lastCause
  result.records.add(fallbackRecord(turnIndex, 2, cause,
    "seat fell back to the delver plan: " & lastDetail))
  echo "nethack llm: seat falling back to delver (", cause, ") on turn ",
    turnIndex
