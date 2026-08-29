## Items, the pack, and the identification game.
##
## The cog itself lives here because the pack does: `eat`, `quaff`, `wield`
## and `wear` are inventory operations, and the hunger clock is the pack's
## other half. Every proc returns the NetHack message line it produced, which
## is the only channel the cog has for learning what just happened.

import sim_types

type
  Cog* = object
    x*, y*, depth*: int
    hp*, maxHp*: int
    ac*: int
    xlevel*, xpPoints*: int
    gold*: int
    nutrition*: int
    confused*, paralysed*, stuck*, trapped*: int
    inv*: array[MaxInventory, Item]
    wielded*: int              ## inventory letter index, or -1
    worn*: int                 ## inventory letter index, or -1
    hunger*: Hunger

proc emptyItem*(): Item = Item(kind: ikNone, id: 0, count: 0)

proc potionAppearanceTable*(seed: int): array[PotionNames.len, int] =
  ## A seeded permutation of the six appearance names over the four potion
  ## kinds. Learning the mapping by drinking is the identification game, in
  ## miniature.
  var pool: seq[int] = @[]
  for i in 0 ..< PotionAppearances.len:
    pool.add(i)
  for kind in 0 ..< PotionNames.len:
    let pick = hashRnd(seed, 0, kind, 1201, pool.len)
    result[kind] = pool[pick]
    pool.delete(pick)

proc armourBonusOf*(cog: Cog): int =
  if cog.worn >= 0 and cog.inv[cog.worn].kind == ikArmour:
    ArmourBonus[cog.inv[cog.worn].id mod ArmourBonus.len]
  else:
    0

proc recomputeAc*(cog: var Cog) =
  cog.ac = 9 - cog.armourBonusOf()

proc weaponDie*(cog: Cog): int =
  if cog.wielded >= 0 and cog.inv[cog.wielded].kind == ikWeapon:
    WeaponDie[cog.inv[cog.wielded].id mod WeaponDie.len]
  else:
    2

proc weaponHitBonus*(cog: Cog): int =
  if cog.wielded >= 0 and cog.inv[cog.wielded].kind == ikWeapon:
    WeaponHit[cog.inv[cog.wielded].id mod WeaponHit.len]
  else:
    0

proc initCog*(startHp, startNutrition: int): Cog =
  ## The identical starting kit, every episode: no character generation.
  result.hp = startHp
  result.maxHp = startHp
  result.xlevel = 1
  result.xpPoints = 0
  result.gold = 0
  result.nutrition = startNutrition
  result.depth = 1
  result.wielded = 0
  result.worn = 2
  for i in 0 ..< MaxInventory:
    result.inv[i] = emptyItem()
  result.inv[0] = Item(kind: ikWeapon, id: 0, count: 1)   ## a dagger, wielded
  result.inv[1] = Item(kind: ikFood, id: 0, count: 1)     ## a food ration
  result.inv[2] = Item(kind: ikArmour, id: 0, count: 1)   ## leather, worn
  result.recomputeAc()
  result.hunger = hungerOf(result.nutrition)

proc freeLetter*(cog: Cog): int =
  for i in 0 ..< MaxInventory:
    if cog.inv[i].kind == ikNone:
      return i
  -1

proc lowestFoodLetter*(cog: Cog): int =
  for i in 0 ..< MaxInventory:
    if cog.inv[i].kind == ikFood:
      return i
  -1

proc removeItem*(cog: var Cog, letter: int) =
  if letter < 0 or letter >= MaxInventory:
    return
  cog.inv[letter] = emptyItem()
  if cog.wielded == letter: cog.wielded = -1
  if cog.worn == letter:
    cog.worn = -1
    cog.recomputeAc()

proc eatItem*(cog: var Cog, letter: int): tuple[ok: bool, message: string] =
  if letter < 0 or letter >= MaxInventory or cog.inv[letter].kind != ikFood:
    return (false, "You cannot eat that.")
  let id = cog.inv[letter].id mod FoodNutrition.len
  cog.nutrition += FoodNutrition[id]
  let name = FoodNames[id]
  cog.removeItem(letter)
  (true, "You finish eating the " & name & ".")

proc quaffItem*(
  cog: var Cog, letter: int,
  potionKnown: var array[PotionNames.len, bool],
  appearance: array[PotionNames.len, int],
  seed, depth, tick: int
): tuple[ok: bool, message: string, effect: string] =
  if letter < 0 or letter >= MaxInventory or cog.inv[letter].kind != ikPotion:
    return (false, "You cannot drink that.", "")
  let kind = cog.inv[letter].id mod PotionNames.len
  let shown = PotionAppearances[appearance[kind] mod PotionAppearances.len]
  potionKnown[kind] = true
  cog.removeItem(letter)
  var message = "You drink the " & shown & " potion."
  case kind
  of 0:
    let gain = 1 + hashRnd(seed, depth, tick, 1301, 8)
    cog.hp = min(cog.maxHp, cog.hp + gain)
    message.add(" You feel better.")
  of 1:
    let gain = 2 + hashRnd(seed, depth, tick, 1303, 8)
    cog.maxHp += 1
    cog.hp = min(cog.maxHp, cog.hp + gain)
    message.add(" You feel much better.")
  of 2:
    cog.confused = 10
    message.add(" Huh, what? Where am I?")
  else:
    cog.paralysed = 10
    message.add(" You fall asleep.")
  (true, message, PotionNames[kind])

proc wieldItem*(cog: var Cog, letter: int): tuple[ok: bool, message: string] =
  if letter < 0 or letter >= MaxInventory or cog.inv[letter].kind != ikWeapon:
    return (false, "You cannot wield that.")
  cog.wielded = letter
  (true, "You are now wielding the " &
    WeaponNames[cog.inv[letter].id mod WeaponNames.len] & ".")

proc wearItem*(cog: var Cog, letter: int): tuple[ok: bool, message: string] =
  if letter < 0 or letter >= MaxInventory or cog.inv[letter].kind != ikArmour:
    return (false, "You cannot wear that.")
  cog.worn = letter
  cog.recomputeAc()
  (true, "You are now wearing the " &
    ArmourNames[cog.inv[letter].id mod ArmourNames.len] & ".")

proc statusLine*(cog: Cog, tick: int): string =
  "Dlvl:" & $cog.depth & " $:" & $cog.gold & " HP:" & $max(0, cog.hp) &
    "(" & $cog.maxHp & ") AC:" & $cog.ac & " Xp:" & $cog.xlevel & "/" &
    $cog.xpPoints & " T:" & $tick & " " & $cog.hunger

proc statusList*(cog: Cog): seq[string] =
  if cog.confused > 0: result.add("confused")
  if cog.paralysed > 0: result.add("paralysed")
  if cog.stuck > 0: result.add("stuck")
  if cog.trapped > 0: result.add("trapped")
