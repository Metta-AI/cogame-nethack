# Protocol

The Coworld contract, unchanged in shape from `coworld-ctf`.

## Environment

| In | |
|---|---|
| `COGAME_CONFIG_URI` | the episode's `game_config`, as JSON |
| `COGAME_HOST` / `COGAME_PORT` | the bind address (default `0.0.0.0:8080`) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_API_KEY_URI` | the LLM credential, injected into the **game** pod |

| Out | |
|---|---|
| `COGAME_RESULTS_URI` | `results.json` — the closed schema in the manifest |
| `COGAME_SAVE_REPLAY_URI` | the binary `COWLDNET` replay |
| `COGAME_PLAYER_FAILURE_URI` | exactly `{"message", "failed_policy_index"}`, and nothing else |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_LOAD_REPLAY_URI` | replay mode: serve this replay instead of playing |

## Routes

| Route | |
|---|---|
| `GET /healthz` | `healthy`, always, including for the shutdown grace after the artifacts are written |
| `GET /player?slot=N&token=T` (websocket) | the seat. **Closes unless the token matches the seat** — the certifier probes with a bad token. |
| `GET /global` (websocket) | the spectator board + chrome stream (Sprite v1 binary). Refuses player credentials. |
| `GET /replay` (websocket) | the same stream in replay mode |
| `GET /client/replay`, `GET /client/global` | the broadcast page |
| `GET /client/player?slot=&token=` | token-checked, and it **does not** open the player socket |
| `GET /replay-data` | the loaded replay's bytes, in replay mode |
| `GET /client/font.ttf` | the chrome's font |

## The seat

The seat sends **one Sprite v1 chat message** (0x81) carrying its
registration, and then only receives:

```json
{"type": "register",
 "prompt": "<PLAYER_PROMPT, <= 4000 runes, or empty>",
 "scripted": "delver" | "bumbler" | null,
 "policy": "<PLAYER_POLICY_LABEL, <= 64 runes>"}
```

It re-sends that message for the first ~10 s of received frames, because a
registration that lands before the slot does would otherwise be dropped. The
server holds it, consumes it as registration — **never** as speech, and never
into the replay chat stream — and writes a REDACTED `register` record: the
policy label and the kind, never the prompt.

Any other chat text from the seat is dropped. The cog speaks through `say`.

The seat sends **no inputs**: the server computes every primitive. The Sprite
v1 ready packet (0x85) is acknowledged and ignored.

## The replay

Binary `COWLDNET`:

| Record | Carries |
|---|---|
| header | magic, format version, `gameName` `nethack`, `gameVersion` |
| config JSON | seed, variant, `num_agents`, every rule constant, `players[].name`, `slots[]`, `fastMode` |
| join | the seat's real policy name, slot, token |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `stop` / `result` |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

The `directive` records carry the accepted action list, which is this game's
**entire input log**: the dungeon generator, the monster table, the item
tables and the message strings are code, compiled into both the binary and the
wasm module, so the viewer reconstructs every level, every monster, every item
and every message line from bytes it already has, with no fetch.

The wall-clock and fault stops are written as a **load-bearing `stop`
record**: a wall-clock fact cannot be re-derived from sim state, so it is
applied by the same proc on record and on playback.

`tools/replay_summary.py` reads the same bytes with the Python standard
library alone.
