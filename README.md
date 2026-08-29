# cogame-nethack

**NetHack in miniature.** One cog, one life, and eight levels of a dungeon
that was generated out of this episode's seed and exists nowhere else.

The cog reads an ASCII map of what it has explored, one message line of what
just happened, and one status line of what it is — the same three things a
NetHack player reads — and answers with commands. Everything else (the shape
of the level below, what is behind that door, whether the smoky potion is
healing or sleeping, whether the thing that just bit it is worth fighting) has
to be inferred, written down in a 400-rune note, and carried forward.

**The only number the league reads is how deep it got.** Gold, experience and
three named deeds are the tie-break, and one more dungeon level always beats
every one of them put together.

```
score = 100000 * (deepest level - 1)      # 0 .. 700 000
      +     10 * min(gold, 2000)          # 0 ..  20 000
      +     50 * min(experience, 1000)    # 0 ..  50 000
      +   5000 * deeds earned             # 0 ..  15 000
```

Death subtracts nothing. That is NetHack's own rule: you score the run you
had, and dying merely stops you scoring more.

## A policy is just a prompt

```bash
coworld upload-policy coworld-nethack:latest \
  --name my-nethack \
  --run /bin/nethack-player \
  --secret-env PLAYER_PROMPT="Dive. If > is on your map, travel to it and take it in the same turn."
```

The seat container is deliberately thin: it connects, sends one registration
message, and receives. **Every decision is made inside the game server**,
because that is the only container the platform injects the coworld's
`anthropic_api_key` secret into. The same image ships two scripted baselines,
selected by environment variable:

```bash
--secret-env PLAYER_SCRIPTED=delver     # the deterministic crawler (the floor)
--secret-env PLAYER_SCRIPTED=bumbler    # the reactive control
```

## What the cog sees

```json
{"you_are": "Alpha the Digger",
 "status_line": "Dlvl:3 $:214 HP:9(14) AC:7 Xp:3/42 T:517 Hungry",
 "map": ["                                                ",
         "  ------------                                  ",
         "  |..........|                                  ",
         "  +.........r|                                  ",
         "  |.......@..'#########                         ", "…"],
 "messages": ["You hit the sewer rat.", "The sewer rat bites!"],
 "visible": [{"glyph": "r", "name": "sewer rat", "x": 12, "y": 4, "kind": "monster"}],
 "inventory": [{"letter": "a", "name": "dagger", "kind": "weapon", "count": 1,
                "equipped": "wielded"}],
 "deeds": [{"name": "fed", "earned": true}], "depth_reached": 3,
 "notes": "DL3: came down at (35,10). no > yet. smoky potion untested."}
```

A space is a cell it has **never seen**. Monsters are **never remembered**: if
one is not in `visible`, the cog does not know where it is.

## What the cog sends

One JSON object, up to ten actions, which run one per dungeon turn:

```json
{"actions": [{"do": "travel", "x": 31, "y": 8}, {"do": "down"}],
 "say": "stairs first, then the gold",
 "notes": "DL3: > at (31,8). west door still dark. 214 gold."}
```

`docs/ACTIONS.md` is the full verb list and the reply schema.
`docs/RULES.md` is the game. `docs/PORTING-NETHACK.md` says exactly what this
is and is not a port of — **no score here is comparable to an NLE, NetHack
Challenge or BALROG number**, and the reasons are written down.

## Layout

| Path | What |
|---|---|
| `src/nethack/` | the sim (`dungeon`, `mobs`, `items`, `minihack`, `sim`), the driver, the baselines, the LLM decision layer, the replay codec, the board compositor and the mummy server |
| `src/nethack.nim` | the game entrypoint (`/bin/nethack`) |
| `src/nethack_player.nim` | the seat registrar (`/bin/nethack-player`) |
| `client/` | the broadcast chrome, inherited from `coworld-ctf` with an appended nethack block |
| `replay-viewer/` | the static wasm replay bundle: the same sim module compiled to WebAssembly |
| `tools/` | the CI smoke, the viewer smoke, the replay-viewer build hook, the baseline sweep, the replay summariser |
| `scripts/art/` | the nano-banana source sheets and the split script that produce `data/art/` |
| `tests/` | the sim, generator, driver, engine, replay, manifest, viewer and label tests |
| `docs/plans/` | the accepted design note, verbatim |

## Building and running it

The whole toolchain is pinned. CI is the harness:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --hints:off --path:src tests/test_nethack_sim.nim   # any test file
./tools/ci/docker_smoke.sh coworld-nethack:ci             # one real episode
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

## Replays

The replay is the binary `COWLDNET` format: the resolved config, the join
record, one **plan record per turn** (this game's entire input log), the chat
records and one `gameHash` per tick. The static wasm viewer re-simulates the
whole episode from those bytes and compares the hash chain **every tick**, so
a replay that has drifted says so in `#mmwarn` at the tick it drifted.

`tools/replay_summary.py` reads the same bytes with the Python standard
library alone and prints one strict-UTF-8 JSON object.

MIT licensed.
