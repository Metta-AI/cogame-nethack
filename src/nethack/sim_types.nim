## Wire types, closed enums and rule constants for cogame-nethack.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the module keeps that
## file's job (one place that owns `GameVersion`, `TargetFps`, the rune caps
## and every constant the sim, the server and the viewer must agree on) and
## keeps its prepend-only changelog-comment discipline for `GameVersion`.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES, and every truncation
## that consumes one lands on a rune boundary (`directives.truncateRunes`).
## Slicing a recorded string by BYTE index is forbidden anywhere on the path
## to the replay.

import std/[strutils, unicode]

const
  GameName* = "nethack"

  GameVersion* = "2"  ## GV2: a lichen's hold blocks only a move that breaks contact
    ## The headline above sits on the SAME LINE as the number on purpose:
    ## tools/ci/check_gameversion.sh reads that one line to tell "this branch
    ## did not change the rules" from "another branch already spent this
    ## number for a different rule".
    ## GV2 (lichen `stuck`): a lichen's hold blocks only a move that BREAKS
    ## contact with it — the cog may still attack, act, and shuffle to a cell
    ## the same lichen is adjacent to, and a stale `stuck` counter left by a
    ## dead lichen blocks nothing. GV1 blocked every move in every direction.
    ## GV1 (first rules): the eight-level seeded dungeon of the design note —
    ## 48x18 levels, eleven monster species, five item classes, four trap
    ## kinds, the lit-room visibility rule, hunger at 1/tick, permadeath, and
    ## the depth-dominant score. Prepend a new comment ABOVE this one for
    ## every rule change and bump the number in the same commit; a replay's
    ## recorded version is what identifies the rules that produced it.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 4, 8]

  ## --- the board -----------------------------------------------------------
  LevelW* = 48
  LevelH* = 18
  MaxDungeonLevels* = 8
  MaxMonstersPerLevel* = 12
  MaxInventory* = 26

  ## --- rune caps (re-pinned for this fork; see the design note) ------------
  MaxSayRunes* = 140
  MaxNoteRunes* = 400
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxMessageRunes* = 160
  MaxStopDetailRunes* = 200
  MaxDirectiveRunes* = 4000
  MaxReplyBytes* = 4096
  MaxObservedMessages* = 8

  ## --- caps the platform contract needs ------------------------------------
  MaxTicks* = 2200
  ConsultCostDefault* = 50

type
  NethackError* = object of CatchableError

  Terrain* = enum
    tRock = 0
    tFloor
    tCorridor
    tWallH
    tWallV
    tDoorway
    tDoorClosed
    tDoorLocked
    tSecretDoor
    tStairsDown
    tStairsUp
    tLava

  ItemKind* = enum
    ikNone = "none"
    ikGold = "gold"
    ikFood = "food"
    ikPotion = "potion"
    ikWeapon = "weapon"
    ikArmour = "armour"

  Item* = object
    kind*: ItemKind
    id*: int    ## index into the kind's table; for gold, the amount.
    count*: int

  Species* = enum
    spGridBug = 0
    spSewerRat
    spLichen
    spJackal
    spKobold
    spGnome
    spGnomeZombie
    spFloatingEye
    spHillOrc
    spDwarf
    spGnomeMummy
    spOracle

  Verb* = enum
    vMove = "move"
    vTravel = "travel"
    vSearch = "search"
    vPickup = "pickup"
    vEat = "eat"
    vQuaff = "quaff"
    vWield = "wield"
    vWear = "wear"
    vKick = "kick"
    vChat = "chat"
    vDown = "down"
    vUp = "up"
    vWait = "wait"

  Action* = object
    ## One entry of the reply's `actions` array, already validated.
    verb*: Verb
    dir*: int      ## 0..7 in the fixed order e, se, s, sw, w, nw, n, ne
    x*, y*: int    ## travel target
    item*: int     ## inventory letter index 0..25

  Primitive* = object
    ## What the driver hands the tick loop. Never `vTravel`.
    verb*: Verb
    dir*: int
    item*: int

  Phase* = enum
    Lobby = "lobby"
    Playing = "playing"
    GameOver = "gameover"

  EndRule* = enum
    erNone = "none"
    erDeath = "death"
    erBottom = "bottom"
    erEscaped = "escaped"
    erTurnCap = "turnCap"
    erWallClock = "wallClock"
    erFault = "fault"

  EndReason* = enum
    reasonComplete = "complete"
    reasonDeadline = "deadline"
    reasonFault = "fault"

  CauseOfDeath* = enum
    codNone = "none"
    codKilled = "killed"
    codStarved = "starved"
    codBurned = "burned"

  Deed* = enum
    deedFed = "fed"
    deedHoard = "hoard"
    deedOracle = "oracle"

  Hunger* = enum
    hSatiated = "Satiated"
    hNotHungry = "Not Hungry"
    hHungry = "Hungry"
    hWeak = "Weak"
    hFainting = "Fainting"

const
  ## The fixed 8-neighbour order used EVERYWHERE: monster AI tie-breaks, the
  ## BFS neighbour order, the wander draw and the `dir` enum.
  DirDx*: array[8, int] = [1, 1, 0, -1, -1, -1, 0, 1]
  DirDy*: array[8, int] = [0, 1, 1, 1, 0, -1, -1, -1]
  DirNames*: array[8, string] = ["e", "se", "s", "sw", "w", "nw", "n", "ne"]
  OrthoDirs*: array[4, int] = [0, 2, 4, 6]   ## e, s, w, n (the grid bug)

  TerrainGlyph*: array[Terrain, char] = [
    ' ',   # tRock
    '.',   # tFloor
    '#',   # tCorridor
    '-',   # tWallH
    '|',   # tWallV
    '\'',  # tDoorway
    '+',   # tDoorClosed
    '+',   # tDoorLocked
    ' ',   # tSecretDoor (rock until found)
    '>',   # tStairsDown
    '<',   # tStairsUp
    '}'    # tLava
  ]

  TerrainPassable*: array[Terrain, bool] = [
    false, # tRock
    true,  # tFloor
    true,  # tCorridor
    false, # tWallH
    false, # tWallV
    true,  # tDoorway
    false, # tDoorClosed
    false, # tDoorLocked
    false, # tSecretDoor
    true,  # tStairsDown
    true,  # tStairsUp
    true   # tLava (entering it is death, not a wall)
  ]

  TerrainClearSight*: array[Terrain, bool] = [
    false, true, true, false, false, true, false, false, false, true, true, true
  ]

  ItemGlyph*: array[ItemKind, char] = [' ', '$', '%', '!', ')', '[']

  SpeciesGlyph*: array[Species, char] = [
    'x', 'r', 'F', 'd', 'k', 'G', 'Z', 'e', 'o', 'h', 'M', 'O'
  ]

  SpeciesName*: array[Species, string] = [
    "grid bug", "sewer rat", "lichen", "jackal", "kobold", "gnome",
    "gnome zombie", "floating eye", "hill orc", "dwarf", "gnome mummy",
    "Oracle"
  ]

  ## hp, ac, level, damage die, speed (movement points per 12 ticks), xp
  SpeciesHp*: array[Species, int] = [3, 5, 4, 6, 8, 10, 12, 10, 14, 14, 20, 20]
  SpeciesAc*: array[Species, int] = [9, 7, 9, 7, 6, 5, 5, 9, 4, 4, 4, 0]
  SpeciesLevel*: array[Species, int] = [0, 1, 0, 0, 1, 1, 1, 2, 2, 2, 3, 0]
  SpeciesDmg*: array[Species, int] = [2, 3, 2, 2, 4, 6, 6, 0, 6, 8, 8, 0]
  SpeciesSpeed*: array[Species, int] = [12, 12, 3, 12, 12, 12, 6, 0, 12, 12, 6, 0]
  SpeciesXp*: array[Species, int] = [1, 2, 4, 2, 4, 8, 8, 10, 12, 12, 20, 0]
  SpeciesMinDepth*: array[Species, int] = [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 6, 1]
  SpeciesMaxDepth*: array[Species, int] = [3, 4, 5, 5, 6, 7, 8, 8, 8, 8, 8, 8]

  FoodNames*: array[3, string] = ["food ration", "tripe ration", "apple"]
  FoodNutrition*: array[3, int] = [800, 200, 50]

  PotionNames*: array[4, string] = [
    "healing", "extra healing", "confusion", "sleeping"]
  PotionAppearances*: array[6, string] = [
    "pink", "ruby", "milky", "smoky", "cloudy", "dark"]

  WeaponNames*: array[4, string] = [
    "dagger", "short sword", "mace", "long sword"]
  WeaponDie*: array[4, int] = [4, 6, 6, 8]
  WeaponHit*: array[4, int] = [1, 0, 1, 0]

  ArmourNames*: array[3, string] = ["leather armour", "ring mail", "plate mail"]
  ArmourBonus*: array[3, int] = [2, 3, 6]

  TrapNames*: array[4, string] = [
    "arrow trap", "dart trap", "pit", "teleport trap"]

  AllDeeds*: array[3, Deed] = [deedFed, deedHoard, deedOracle]

proc splitmix64*(value: uint64): uint64 =
  ## One splitmix64 finalisation round.
  var z = value + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc mix64*(a, b, c, d: int): uint64 =
  ## The ONE seeded source in this game, and it is a pure hash read, never a
  ## consumed stream: level `k`'s layout cannot be shifted by anything the
  ## policy did on level `k - 1`. All four words go through 64-bit casts so
  ## the value is identical on the native 64-bit build and the wasm32 one.
  result = 0xCBF29CE484222325'u64
  result = splitmix64(result xor cast[uint64](int64(a)))
  result = splitmix64(result xor cast[uint64](int64(b)))
  result = splitmix64(result xor cast[uint64](int64(c)))
  result = splitmix64(result xor cast[uint64](int64(d)))

proc hashRnd*(seed, depth, tick, salt, n: int): int =
  ## `rnd(n)` of the design note: `mix64(seed, depth, tick, salt) mod n`.
  if n <= 0:
    return 0
  int(mix64(seed, depth, tick, salt) mod cast[uint64](int64(n)))

proc dirIndex*(name: string): int =
  ## Case-insensitive `n|s|e|w|ne|nw|se|sw` -> the fixed direction order.
  ## Returns -1 for anything else (the entry is then DROPPED, never repaired).
  let key = name.strip().toLowerAscii()
  for i, value in DirNames:
    if value == key:
      return i
  -1

proc runeCount*(text: string): int =
  text.runeLen

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened; a BYTE slice anywhere on the
  ## path to the replay is what makes a replay fail a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc hungerOf*(nutrition: int): Hunger =
  if nutrition > 1000: hSatiated
  elif nutrition >= 150: hNotHungry
  elif nutrition >= 50: hHungry
  elif nutrition >= 1: hWeak
  else: hFainting

proc itemName*(item: Item, potionKnown: openArray[bool],
               potionAppearance: openArray[int]): string =
  ## The identified name for identified things, the APPEARANCE for an
  ## unidentified potion. `potionAppearance[kind]` is the seeded appearance
  ## index of potion kind `kind`.
  case item.kind
  of ikNone: ""
  of ikGold:
    $item.id & " gold piece" & (if item.id == 1: "" else: "s")
  of ikFood: FoodNames[item.id mod FoodNames.len]
  of ikPotion:
    let kind = item.id mod PotionNames.len
    let appearance =
      if kind < potionAppearance.len: potionAppearance[kind]
      else: kind
    if kind < potionKnown.len and potionKnown[kind]:
      "potion of " & PotionNames[kind]
    else:
      "a " & PotionAppearances[appearance mod PotionAppearances.len] & " potion"
  of ikWeapon: WeaponNames[item.id mod WeaponNames.len]
  of ikArmour: ArmourNames[item.id mod ArmourNames.len]
