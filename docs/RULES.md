# Rules

One cog, alone, at the top of a dungeon it has never seen. It has a dagger, a
food ration, a suit of leather armour and sixteen hit points. Rats, jackals,
kobolds, gnomes and worse are down there; so is gold, so is food, so is the
Oracle, and so — on every level — is a staircase down. It gets hungrier every
turn. It has **one life**: nothing in this game restores, resurrects or
reloads.

## The board

Every level is **48 columns x 18 rows**. `(0, 0)` is the north-west corner and
the whole border ring is solid rock.

| Terrain | Glyph | Passable | Notes |
|---|---|---|---|
| solid rock | ` ` | no | also what an unseen cell renders as |
| room floor | `.` | yes | |
| corridor | `#` | yes | dark: sight radius 1 |
| wall | `-` `\|` | no | |
| open doorway | `'` | yes | a doorway with no door in it |
| closed door | `+` | no | walking into it **opens** it (NetHack's `autoopen`) |
| locked door | `+` | no | identical glyph; only the message line says it is locked; needs `kick` |
| secret door | ` ` | no | looks like rock until `search` finds it |
| staircase down | `>` | yes | |
| staircase up | `<` | yes | |
| lava | `}` | yes | **entering it is instant death** |
| discovered trap | `^` | yes | the glyph a trap shows *after* it is found |

Items: **`$` gold**, **`%` food**, **`!` potion**, **`)` weapon**,
**`[` armour**. The cog is **`@`**. Monsters are letters.

## The cog

`hp` / `maxHp` (start **16 / 16**), `ac` (**lower is better**,
`ac = 9 - armourBonus`, so 7 in the starting leather), `xlevel` (start 1),
`xpPoints`, `gold`, `nutrition` (start **900**), a position, a depth, an
inventory of at most 26 stacks lettered `a … z`, and a status set drawn from
`{confused, paralysed, stuck, trapped}`.

Starting inventory, identical every episode: `a` a dagger (wielded, damage die
4, hit bonus +1); `b` a food ration (800 nutrition); `c` leather armour (worn,
bonus 2).

**Hunger.** `nutrition` falls by 1 every tick. `Satiated` > 1000;
`Not Hungry` 150 … 1000; `Hungry` 50 … 149; `Weak` 1 … 49; `Fainting` <= 0.
While `Weak` or `Fainting` the cog does not regenerate, takes **-2** to hit
and cannot kick. At `nutrition <= -200` it **dies of starvation**. 900
nutrition plus the starting ration covers 1 700 of the episode's 2 200 ticks,
so a cog that wants its whole clock must find and eat food at least once more.

**Regeneration.** `hp += 1` every twelve ticks, while `hp < maxHp` and hunger
is better than `Weak`.

**Experience.** A kill awards the species' xp value. `xlevel` is `1 +` the
number of thresholds passed in `[20, 40, 80, 160, 320, 640, 1280]`. On each
level-up, `maxHp` and `hp` both gain `1 + rnd(8)`.

## Combat

1. **To hit.** The attacker hits iff `d20 + attackBonus + defenderAc >= 15`.
   The cog's `attackBonus` is `xlevel + weaponHitBonus - (2 if Weak or worse)`;
   a monster's is its species level; `defenderAc` is the defender's armour
   class (lower is better; unarmoured 9, plate 3).
2. **Damage.** `1 + rnd(die)`. The cog's die is its wielded weapon's (unarmed
   2); a monster's is its species die.
3. **Death.** `hp <= 0` ends the run immediately.
4. **The floating eye.** A melee attack on `e` — hit **or** miss — paralyses
   the cog for **12 ticks**. Walk around it. It never moves.
5. **The lichen.** An `F` that hits sets `stuck` for 3 ticks: the cog may
   attack and act, but a `move` away from it fails.
6. The cog attacks by **moving into** a monster. There are no ranged attacks,
   no spells and no wands.

## The monsters

| Glyph | Name | Depths | hp | ac | level | dmg | speed | xp | Special |
|---|---|---|---|---|---|---|---|---|---|
| `x` | grid bug | 1–3 | 3 | 9 | 0 | 2 | 12 | 1 | moves orthogonally only |
| `r` | sewer rat | 1–4 | 5 | 7 | 1 | 3 | 12 | 2 | |
| `F` | lichen | 1–5 | 4 | 9 | 0 | 2 | 3 | 4 | sticks |
| `d` | jackal | 1–5 | 6 | 7 | 0 | 2 | 12 | 2 | packs of 3 from depth 2 |
| `k` | kobold | 2–6 | 8 | 6 | 1 | 4 | 12 | 4 | |
| `G` | gnome | 2–7 | 10 | 5 | 1 | 6 | 12 | 8 | drops `10 + rnd(50)` gold |
| `Z` | gnome zombie | 3–8 | 12 | 5 | 1 | 6 | 6 | 8 | half speed |
| `e` | floating eye | 3–8 | 10 | 9 | 2 | 0 | 0 | 10 | never moves; paralysis passive |
| `o` | hill orc | 4–8 | 14 | 4 | 2 | 6 | 12 | 12 | pairs from depth 2 |
| `h` | dwarf | 4–8 | 14 | 4 | 2 | 8 | 12 | 12 | |
| `M` | gnome mummy | 6–8 | 20 | 4 | 3 | 8 | 6 | 20 | |

**Speed** is movement points per 12 ticks: a monster acts on tick `t` exactly
`(t * speed) div 12 - ((t - 1) * speed) div 12` times.

**Monster AI**, first matching rule: attack the cog if 8-adjacent; else, if
the cog is within 10 cells and on the same room-or-corridor component, step to
the 8-neighbour that minimises Chebyshev distance (ties in the fixed order
`e, se, s, sw, w, nw, n, ne`; a grid bug is restricted to `e, s, w, n`); else
wander. A monster never enters lava, never opens a door and never steps onto
the cog.

## Items

- **Gold `$`** — `pickup` adds it to `gold`.
- **Food `%`** — food ration (800), tripe ration (200), apple (50).
- **Potions `!`** — healing (`hp += 1 + rnd(8)`), extra healing
  (`hp += 2 + rnd(8)`, `maxHp += 1`), confusion (10 ticks: every `move` goes
  in a random direction), sleeping (paralysed 10 ticks). **Appearances are a
  seeded permutation** of `pink, ruby, milky, smoky, cloudy, dark`: a potion
  reads "a smoky potion" until one of that appearance has been quaffed.
- **Weapons `)`** — dagger (die 4, +1), short sword (6, 0), mace (6, +1),
  long sword (8, 0).
- **Armour `[`** — leather (2), ring mail (3), plate mail (6).

## Traps

`(depth + 1) div 2` per level, hidden until triggered or found: arrow trap
(`1 + rnd(6)` damage), dart trap (`1 + rnd(3)`), pit (`1 + rnd(3)` and
`trapped` for 3 ticks), teleport trap. A triggered trap is discovered forever,
renders `^` and never fires again. **`search`** reveals every undiscovered
trap and secret door 8-adjacent to the cog on the **third** search executed
next to it — deterministic, so a level can never be permanently unsolvable.

## Visibility

```
if the cog stands on a floor cell belonging to a LIT room:
    visible = every floor cell of that room, plus its wall ring and its doors
else:
    visible = the cog's own cell and its 8 neighbours
```

Terrain is remembered forever. Items are remembered where they were last seen
and cleared when the cell is visible and the item is gone. **Monsters are
never remembered.** A cell never seen renders as a space and is
indistinguishable from solid rock.

## Turns, ticks and the clock

- **Tick** = one dungeon turn = one primitive by the cog, then the monsters.
- **`turnTicks = 40`**: one command turn executes at most forty primitives.
- **`maxTurns = 55`**, so **`maxTicks = 2200`**.
- A command turn ends when its queue empties, when the cog changes level, when
  the run ends, or at forty ticks — whichever is first. A reply with **no
  usable actions** spends the whole forty ticks waiting, so an unusable reply
  always costs the clock.

## Ending

| `endRule` | When | `reason` |
|---|---|---|
| `death` | `hp <= 0`, starvation or lava | `complete` |
| `bottom` | `down` on the last level | `complete` |
| `escaped` | `up` on level 1 | `complete` |
| `turnCap` | 55 turns or 2 200 ticks | `complete` |
| `wallClock` | the engine's 660 s stop | `deadline` |
| `fault` | an unexpected exception, settled from the last tick | `fault` |

**A death is a healthy, complete episode.** The score is the run the cog had.

## The Oracle

`chat` with `dir` pointing at an 8-adjacent `O`. With 50 gold or more the cost
is deducted, the `oracle` deed is earned, and the message line gives the true
compass octant from the cog to `>` on this level. Below 50 gold: *"The Oracle
scowls at your empty purse."* The Oracle never moves, never attacks and cannot
be attacked.

## The deeds

| Deed | Earned when |
|---|---|
| `fed` | the cog has eaten at least once |
| `hoard` | the cog has carried **>= 500 gold** at any moment |
| `oracle` | the cog has consulted the Oracle successfully |

## The terminal panel

The replay viewer's bottom-left panel renders *exactly the text the cog
receives*: the 48 x 18 glyph map, the last message line and the status line.
It is **not** a NetHack ttyrec — there is no NetHack process to record — it is
this sim's own observation, drawn honestly.
