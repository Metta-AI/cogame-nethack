# Actions and the reply format

Every turn the seat receives one observation object and replies with **one
JSON object and nothing else**. The reply must begin with `{` and end with
`}` — no prose, no markdown, no code fences. A reply that is not a JSON object
is a parse failure; the turn is retried once and then falls back to the
`delver` scripted plan.

```json
{"actions": [{"do": "move", "dir": "ne"},
             {"do": "travel", "x": 5, "y": 6},
             {"do": "pickup"},
             {"do": "eat", "item": "b"}],
 "say": "rat first, then the gold, then the closed door west",
 "notes": "DL3: no > yet. west door (2,4) is next. 214 gold."}
```

## The verbs

| Action | What it does |
|---|---|
| `{"do":"move","dir":"ne"}` | step one cell. Moving INTO a monster attacks it. Moving into a closed door OPENS it and spends the tick without moving. |
| `{"do":"travel","x":31,"y":8}` | walk there: the shortest path through cells you have **already seen**. Refuses unseen cells, lava, closed and locked doors, and cells holding a visible monster. |
| `{"do":"down"}` | take `>` down. You must be standing on it. |
| `{"do":"up"}` | take `<` up. On level 1 this **ends the run**. |
| `{"do":"pickup"}` | take the stack under you |
| `{"do":"eat","item":"b"}` | eat a food item from your pack |
| `{"do":"quaff","item":"d"}` | drink a potion (you find out what it was) |
| `{"do":"wield","item":"a"}` | wield a weapon |
| `{"do":"wear","item":"c"}` | wear armour |
| `{"do":"kick","dir":"n"}` | kick a locked door open. May take several kicks; impossible while Weak. |
| `{"do":"search"}` | search the 8 cells around you. Three searches next to a hidden thing finds it. |
| `{"do":"chat","dir":"e"}` | talk to the Oracle. Costs 50 gold, gives the direction of `>`. |
| `{"do":"wait"}` | waste a dungeon turn |

## The caps

| Field | Type | Cap / domain |
|---|---|---|
| `actions` | array | **<= 10 entries**. Entries past the cap are dropped and counted. Absent or empty is still a **usable** reply — the turn is spent waiting. |
| `actions[].do` | string | **<= 8 runes**, lower-cased before matching, from the verb list above |
| `actions[].dir` | string | required for `move`, `kick`, `chat`; **<= 2 runes**, case-insensitive, one of `n s e w ne nw se sw`. Anything else **drops the entry**. |
| `actions[].x`, `.y` | integer | required for `travel`; **clamped** to 0…47 / 0…17. A non-integer or absent value drops the entry. |
| `actions[].item` | string | required for `eat`, `quaff`, `wield`, `wear`; **exactly one rune**, `a`…`z`. A letter not in the pack drops the entry. |
| `say` | string | **<= 140 runes** — the cog thinking out loud. Drawn in the spectator feed, never fed back to you. |
| `notes` | string | **<= 400 runes** — your private scratchpad, echoed back to you next turn. **This is the only memory you have.** |
| whole reply | bytes | **<= 4096** read from the provider before parsing |

Unknown top-level and per-action keys are ignored.

## Invalid actions are DROPPED, never rewritten

A mis-specified move in a permadeath game has no meaningful repair: turning an
invalid `travel` into a `move` could walk the cog into lava on the game's own
initiative. An entry that does not validate is removed, counted, and reported
back to you next turn in `last_plan.dropped`.

## How a turn is executed

1. Entries past `maxActionsPerTurn = 10` are dropped.
2. Each entry is validated; one that does not validate is dropped.
3. `travel x y` expands, against the **remembered map as of turn start**, into
   the BFS path's `move` primitives — at most `macroPrimitiveCap = 40` of
   them. A target that is not reachable through remembered passable cells
   yields **zero** primitives and is reported next turn as `unreachable`.
   A diagonal step may not cut a doorway or a wall corner.
   Travelling to a cell that is not itself walkable (a closed door, say)
   leaves the cog **next to** it, ready to walk into it or kick it.
4. The queue is truncated to 40 primitives; the surplus is discarded and
   reported next turn as `truncated`. **Nothing carries over.**
5. `say` and `notes` are sanitised on RUNE boundaries and recorded.

## Crossing into the dark

`travel` plans on what you have **seen**, never on hope: it will not path
through a space. The only way to learn a new cell is to `move` onto it. That
is why a good plan is usually a `travel` to the edge of what you know followed
by several `move`s in the same heading — and why a plan that spends only one
`move` past the frontier learns one cell.

## What you are told back

`last_plan` reports `executed` (the primitives that actually ran),
`truncated`, `dropped` and `unreachable`. `messages` is at most eight lines
since your last observation; if more were produced the oldest are dropped and
the first entry says how many.
