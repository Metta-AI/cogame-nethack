# What this is and is not a port of

**No NLE. No NetHack C source. No MiniHack dependency. No bit-exactness with
any of them.**

No upstream code is vendored, no upstream numbers are claimed as reproduced,
and **no score from this coworld is comparable to a published NLE, NetHack
Challenge or BALROG number.**

This was decided as a scoping rail before design, and the reason is
mechanical: NetHack is a 250 kLOC C program with its own RNG and its own tty
layer, and NLE/MiniHack wrap it in Python. Embedding any of them means a
simulator that **cannot compile to WebAssembly** — and the static wasm replay
viewer is a non-optional pin of this platform. A coworld whose replays are a
live pod is not shippable here.

What this repo implements is the **problem** NetHack poses, not the package: a
seeded, procedurally generated, multi-level dungeon with monsters, items,
hunger, traps, permadeath, a descend-the-stairs depth ladder and a score,
presented through a **text-native observation** (a rendered ASCII map, a
message line and a status line), written as its own deterministic integer Nim
sim.

## The divergences, named

1. **48 x 18 maps, not NetHack's 80 x 21.** Chosen for viewer legibility: 80
   columns cannot be drawn legibly in a 360 px-wide embed. Everything else
   about the map — rooms, corridors, doors, secret doors, stairs — keeps
   NetHack's shape and glyphs.
2. **Eight dungeon levels, one branch.** No Gnomish Mines, no Sokoban, no Big
   Room, no quest, no Gehennom, no Amulet, no ascension, no branch stairs, no
   trapdoors, no level teleporters.
3. **Eleven monster species, not hundreds.** No monster inventories, no pets,
   no ranged attacks (the arrow trap aside), no spellcasting, no polymorph, no
   engulfing, no corpses — and therefore no corpse-eating and no
   petrification.
4. **Five item classes.** Gold, food, potions, weapons, armour. No scrolls,
   wands, rings, amulets, spellbooks, tools, gems, artifacts, containers or
   shops; no blessed/cursed status; no enchantment; no encumbrance; no
   erosion.
5. **No roles, races, alignments, gods, prayer, luck or attributes.** One
   implicit role, "the Digger", with a fixed starting kit. NetHack's prayer —
   the classic get-out-of-jail for starvation — is deliberately absent, which
   is what makes the hunger clock bite.
6. **Nutrition is a flat 1 per tick** and `Fainting` does not cause random
   fainting; starvation kills at -200.
7. **Turn model.** One primitive = one dungeon turn; monster speed is movement
   points per 12 ticks; the only multi-turn occupations are pit escape (3),
   lichen stickiness (3), potion sleep (10) and the floating eye's paralysis
   (12). No speed potions, no fast/slow, no Elbereth.
8. **Keystrokes are named verbs in JSON, batched under a driver, not raw tty
   keys stepped one per call.** The idea's "keystroke per turn over a text
   observation" is preserved as the primitive set and the text observation;
   what changed is *who calls it*. One LLM call per keystroke would be 2 200
   calls in a 720 s budget — impossible — and a policy that cannot express
   "walk over there" spends every turn walking one square. `travel` is
   NetHack's own `_` command.
9. **`autoopen` is on** and **locked doors are opened by `kick` only** — no
   `#force`, no unlocking tools, no key items.
10. **The Oracle is `O`, not a white `@`**, and the consultation is a flat 50
    gold for the compass direction of the down staircase plus a scored deed.
    No minor/major consultations, no fountains, no centaur statues.
11. **Vision** is the lit-room / radius-1 rule. No light sources, no
    blindness, no telepathy, no infravision, no clairvoyance, no magic
    mapping.
12. **Searching is deterministic** — three adjacent searches always reveal —
    where NetHack rolls each turn. Chosen so a level can never be permanently
    unsolvable inside a 55-turn budget.
13. **Score is not NetHack's score formula.** NetHack scores gold + 50 x
    (deepest - 1) + experience and multiplies for ascension; this game makes
    depth strictly dominant, because the league needs one rankable integer and
    the motive is a depth attack. Every underlying quantity is in `results`,
    so an NLE-style per-run report is directly readable.
14. **Permadeath is faithful and total**: one life, no life saving, no amulet
    of life saving, no save/restore, no quit.
15. **A turn ends when its queue empties.** The design note read as though a
    command turn always burns its whole forty ticks; a plan of four
    primitives would then cost thirty-six turns of hunger for nothing, and a
    55-turn episode could not cross a single dungeon level. A turn therefore
    ends when the last queued primitive has run — but a reply with **no
    usable actions** still spends the full forty ticks waiting, so an
    unusable reply always costs the clock.

## The balance corrections, measured

Three constants in the design note produced a game the scripted floor could
not survive: over thirty measured seeds, the `delver` baseline died on
**dungeon level 1 in thirty of thirty runs**, which makes the depth ladder,
the hunger clock and the identification game unreachable and turns the whole
score into a coin flip on the first room. They are corrected here, and the
corrections are named so nobody has to reverse-engineer them:

| Constant | Note | Shipped | Why |
|---|---|---|---|
| to-hit threshold | `d20 + attackBonus + defenderAc >= 11` | `>= 15` | at 11 a level-0 monster hits a cog in starting leather 85 % of the time. 15 keeps the formula, the armour-class scale and the "lower is better" reading, and moves a starting cog to 65 % incoming / 75–85 % outgoing — where NetHack's own early game sits. |
| `startHp` | 12 | **16** | twelve hit points is four dungeon turns against two attackers. |
| regeneration | 1 hp / 20 ticks | 1 hp / **12** ticks (`regenTicks`) | regeneration is the only healing this game has. |
| monsters per level | `min(12, 3 + depth)` | `min(10, 2 + depth)`, and packs only from depth 2 | with packs on top of it, dungeon level 1 could open with three jackals. |

Measured with `tools/tune_baselines.nim` over a fixed 40-seed sweep. With the
corrections the `delver` floor averages dungeon level 2 and reaches level 3+
on its better seeds, which is what leaves an LLM policy somewhere to climb.

## The terminal panel is not a ttyrec

The viewer's terminal panel renders *this* sim's glyph map, message line and
status line. It does not emit or play a NetHack ttyrec, because there is no
NetHack process to record. It is the honest equivalent, and it is labelled as
such.

## What a future version could add

A **reporting** mapping — depth, gold, experience — so runs can be read
alongside NLE reports. It will never claim parity.
