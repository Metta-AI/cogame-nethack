## The board compositor: the cell grid drawn to RGBA and shipped on the
## Sprite v1 binary channel, plus the viewer state the transport controls
## ride in on.
##
## Forked from `coworld-ctf`'s `src/ctf/global.nim` with its three named
## edits: the board is a 48x18 CELL GRID, not a pixel arena; the raycast fov
## cache and its shadowcasting are gone, replaced by the lit-room visibility
## rule's boolean mask plus the per-level memory mask, which this module
## draws as the two-level dark wash; and the monster/item/feature art is
## baked once at install (nano-banana renders of the Softmax cog and the
## dungeon's inhabitants — scripts/art/) rather than composited per frame.

import std/[os, strutils, tables]

import pixie
import bitworld/spriteprotocol

import sim

const
  CellPx* = 18
  BoardW* = LevelW * CellPx
  BoardH* = LevelH * CellPx
  MapLayerId* = 0
  BoardSpriteId* = 300
  BoardObjectId* = 300
  BroadcastChromeSpriteId* = 4090
  MaxChromeLabelBytes = 60_000
    ## The sprite protocol writes a label length as U16, so a chrome frame
    ## that grew past 64 KiB would be silently truncated into a corrupt
    ## packet. The map rows are the only field that can approach it, so they
    ## are the field that is dropped.

type
  GlobalViewerState* = object
    mouseX*, mouseY*: int
    mouseDown*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    initialised*: bool

proc initGlobalViewerState*(): GlobalViewerState =
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState, message: string
) =
  ## One or more global protocol client messages. Whole-string commands are
  ## intercepted before the char-by-char transport path so a multi-digit tick
  ## is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      elif item.text.startsWith("v:"):
        discard                      ## one seat: there is nothing to select
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    else:
      discard

# ---------------------------------------------------------------------------
#  Art
# ---------------------------------------------------------------------------

type Chip = object
  pixels: seq[uint8]      ## CellPx * CellPx * 4, straight alpha

var
  chips: Table[string, Chip]
  bedTile: seq[uint8]
  wallTile: seq[uint8]
  artLoaded = false

proc gameDir(): string = getCurrentDir()

proc blankChip(): Chip =
  result.pixels = newSeq[uint8](CellPx * CellPx * 4)

proc chipFromImage(image: Image): Chip =
  ## Nearest-neighbour down-sample to the cell box. Hand-written rather than
  ## pixie's bilinear resize so the bold outlines the nano-banana art carries
  ## survive at board scale instead of feathering into a halo.
  result = blankChip()
  if image.width <= 0 or image.height <= 0:
    return
  for y in 0 ..< CellPx:
    for x in 0 ..< CellPx:
      let
        sx = min(image.width - 1, x * image.width div CellPx)
        sy = min(image.height - 1, y * image.height div CellPx)
        pixel = image[sx, sy].rgba
        offset = (y * CellPx + x) * 4
      result.pixels[offset] = pixel.r
      result.pixels[offset + 1] = pixel.g
      result.pixels[offset + 2] = pixel.b
      result.pixels[offset + 3] = pixel.a

proc tileFromImage(image: Image, scale, bright: int): seq[uint8] =
  ## One CellPx tile cut from a big texture, scaled by `bright` permille.
  result = newSeq[uint8](CellPx * CellPx * 4)
  for y in 0 ..< CellPx:
    for x in 0 ..< CellPx:
      let
        sx = (x * scale) mod max(1, image.width)
        sy = (y * scale) mod max(1, image.height)
        pixel = image[sx, sy].rgba
        offset = (y * CellPx + x) * 4
      result[offset] = uint8(clamp(int(pixel.r) * bright div 1000, 0, 255))
      result[offset + 1] = uint8(clamp(int(pixel.g) * bright div 1000, 0, 255))
      result[offset + 2] = uint8(clamp(int(pixel.b) * bright div 1000, 0, 255))
      result[offset + 3] = 255'u8

proc proceduralTile(r, g, b: int): seq[uint8] =
  result = newSeq[uint8](CellPx * CellPx * 4)
  for i in 0 ..< CellPx * CellPx:
    result[i * 4] = uint8(clamp(r, 0, 255))
    result[i * 4 + 1] = uint8(clamp(g, 0, 255))
    result[i * 4 + 2] = uint8(clamp(b, 0, 255))
    result[i * 4 + 3] = 255'u8

const SpeciesArt: array[Species, string] = [
  "mon_gridbug", "mon_rat", "mon_lichen", "mon_jackal", "mon_kobold",
  "mon_gnome", "mon_zombie", "mon_eye", "mon_orc", "mon_dwarf", "mon_mummy",
  "mon_oracle"]

proc loadArt*() =
  ## Loads the committed board art once. A missing asset degrades to a
  ## procedural chip rather than raising: the board must always draw.
  if artLoaded:
    return
  artLoaded = true
  try:
    let floor = readImage(gameDir() / "data/arena_floor.png")
    bedTile = tileFromImage(floor, 3, 600)
    wallTile = tileFromImage(floor, 5, 1400)
  except CatchableError:
    bedTile = proceduralTile(52, 46, 40)
    wallTile = proceduralTile(120, 108, 92)
  var names = @["cog_digger"]
  for name in SpeciesArt:
    names.add(name)
  for name in names:
    var chip = blankChip()
    try:
      chip = chipFromImage(readImage(gameDir() / "data/art" / (name & ".png")))
    except CatchableError:
      discard
    chips[name] = chip

# ---------------------------------------------------------------------------
#  The board
# ---------------------------------------------------------------------------

proc putPixel(board: var seq[uint8], x, y: int, r, g, b: int) =
  if x < 0 or y < 0 or x >= BoardW or y >= BoardH:
    return
  let offset = (y * BoardW + x) * 4
  board[offset] = uint8(clamp(r, 0, 255))
  board[offset + 1] = uint8(clamp(g, 0, 255))
  board[offset + 2] = uint8(clamp(b, 0, 255))
  board[offset + 3] = 255'u8

proc blitTile(board: var seq[uint8], cx, cy: int, tile: seq[uint8],
              wash: int) =
  if tile.len == 0:
    return
  for y in 0 ..< CellPx:
    for x in 0 ..< CellPx:
      let src = (y * CellPx + x) * 4
      board.putPixel(cx * CellPx + x, cy * CellPx + y,
                     int(tile[src]) * wash div 100,
                     int(tile[src + 1]) * wash div 100,
                     int(tile[src + 2]) * wash div 100)

proc blitChip(board: var seq[uint8], cx, cy: int, chip: Chip, wash: int) =
  if chip.pixels.len == 0:
    return
  for y in 0 ..< CellPx:
    for x in 0 ..< CellPx:
      let src = (y * CellPx + x) * 4
      let alpha = int(chip.pixels[src + 3])
      if alpha < 24:
        continue
      let
        px = cx * CellPx + x
        py = cy * CellPx + y
        offset = (py * BoardW + px) * 4
      if px < 0 or py < 0 or px >= BoardW or py >= BoardH:
        continue
      let
        sr = int(chip.pixels[src]) * wash div 100
        sg = int(chip.pixels[src + 1]) * wash div 100
        sb = int(chip.pixels[src + 2]) * wash div 100
      board[offset] = uint8(clamp((sr * alpha + int(board[offset]) * (255 - alpha)) div 255, 0, 255))
      board[offset + 1] = uint8(clamp((sg * alpha + int(board[offset + 1]) * (255 - alpha)) div 255, 0, 255))
      board[offset + 2] = uint8(clamp((sb * alpha + int(board[offset + 2]) * (255 - alpha)) div 255, 0, 255))

proc fillCell(board: var seq[uint8], cx, cy, r, g, b, wash: int) =
  for y in 0 ..< CellPx:
    for x in 0 ..< CellPx:
      board.putPixel(cx * CellPx + x, cy * CellPx + y,
                     r * wash div 100, g * wash div 100, b * wash div 100)

proc drawInset(board: var seq[uint8], cx, cy, inset, r, g, b, wash: int) =
  for y in inset ..< CellPx - inset:
    for x in inset ..< CellPx - inset:
      board.putPixel(cx * CellPx + x, cy * CellPx + y,
                     r * wash div 100, g * wash div 100, b * wash div 100)

proc drawTopEdge(board: var seq[uint8], cx, cy, r, g, b, wash: int) =
  ## The masonry bevel: a two-pixel highlight along a wall's top edge, so a
  ## wall run reads as dungeon masonry rather than a black bar.
  for x in 0 ..< CellPx:
    for y in 0 ..< 2:
      board.putPixel(cx * CellPx + x, cy * CellPx + y,
                     r * wash div 100, g * wash div 100, b * wash div 100)

proc drawGlyphBar(board: var seq[uint8], cx, cy, r, g, b, wash: int) =
  ## A small centred bar: the readable shape behind a staircase chevron.
  for x in 4 ..< CellPx - 4:
    for y in CellPx div 2 - 1 .. CellPx div 2 + 1:
      board.putPixel(cx * CellPx + x, cy * CellPx + y,
                     r * wash div 100, g * wash div 100, b * wash div 100)

proc renderBoard*(sim: SimServer): seq[uint8] =
  ## The whole level, drawn with the TWO-LEVEL MEMORY WASH: a cell never seen
  ## is fully dark; a cell seen but not currently visible is drawn at 45%
  ## with its remembered contents and NO monsters; a cell in the current
  ## visible set is drawn clean and bright with everything on it.
  loadArt()
  result = newSeq[uint8](BoardW * BoardH * 4)
  let li = sim.levelIndex
  let level = sim.levels[li]
  for cy in 0 ..< LevelH:
    for cx in 0 ..< LevelW:
      let i = idx(cx, cy)
      let visible = sim.visible[i]
      let seen = level.seen[i]
      if not seen:
        result.fillCell(cx, cy, 8, 7, 10, 100)
        continue
      let wash = if visible: 100 else: 45
      let terrain = if visible: level.cells[i].terrain else: level.memTerrain[i]
      case terrain
      of tRock, tSecretDoor:
        result.fillCell(cx, cy, 12, 11, 14, wash)
      of tWallH, tWallV:
        result.blitTile(cx, cy, wallTile, wash)
        result.drawTopEdge(cx, cy, 210, 198, 176, wash)
      of tFloor, tStairsUp, tStairsDown:
        result.blitTile(cx, cy, bedTile, wash)
      of tCorridor:
        result.blitTile(cx, cy, bedTile, wash * 70 div 100)
      of tDoorway:
        result.blitTile(cx, cy, bedTile, wash)
        result.drawInset(cx, cy, 6, 24, 18, 12, wash)
      of tDoorClosed:
        result.blitTile(cx, cy, bedTile, wash)
        result.drawInset(cx, cy, 2, 128, 84, 40, wash)
      of tDoorLocked:
        result.blitTile(cx, cy, bedTile, wash)
        result.drawInset(cx, cy, 2, 128, 84, 40, wash)
        result.drawInset(cx, cy, 7, 230, 190, 70, wash)
      of tLava:
        let flicker = 100 + ((sim.tickCount + cx + cy) mod 4) * 12
        result.fillCell(cx, cy, 210 * flicker div 100, 70 * flicker div 100,
                        20, wash)
      if terrain == tStairsDown:
        result.drawGlyphBar(cx, cy, 240, 232, 214, wash)
        result.drawInset(cx, cy, 7, 40, 200, 140, wash)
      elif terrain == tStairsUp:
        result.drawGlyphBar(cx, cy, 240, 232, 214, wash)
        result.drawInset(cx, cy, 7, 90, 150, 230, wash)
      if level.cells[i].trapKind >= 0 and level.cells[i].trapFound:
        result.drawInset(cx, cy, 6, 220, 90, 90, wash)
      let item =
        if visible: level.cells[i].item
        else: level.memItem[i]
      case item.kind
      of ikGold: result.drawInset(cx, cy, 5, 235, 195, 60, wash)
      of ikFood: result.drawInset(cx, cy, 5, 150, 200, 90, wash)
      of ikPotion: result.drawInset(cx, cy, 5, 190, 110, 220, wash)
      of ikWeapon: result.drawInset(cx, cy, 5, 200, 205, 215, wash)
      of ikArmour: result.drawInset(cx, cy, 5, 120, 160, 220, wash)
      of ikNone: discard
      if visible:
        let monster = level.monsterAt(cx, cy)
        if monster >= 0:
          let species = level.monsters[monster].species
          result.blitChip(cx, cy, chips.getOrDefault(SpeciesArt[species],
                                                     blankChip()), 100)
  result.blitChip(sim.cog.x, sim.cog.y,
                  chips.getOrDefault("cog_digger", blankChip()), 100)

# ---------------------------------------------------------------------------
#  The packet
# ---------------------------------------------------------------------------

proc buildBoardPacket*(
  sim: var SimServer, state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[uint8] =
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  if not state.initialised:
    nextState.initialised = true
    result.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
    result.addViewport(MapLayerId, BoardW, BoardH)
  result.addSprite(BoardSpriteId, BoardW, BoardH, sim.renderBoard())
  result.addObject(BoardObjectId, 0, 0, 0, MapLayerId, BoardSpriteId)

proc addChrome*(packet: var seq[uint8], chromeJson: string) =
  ## The broadcast chrome rides the SAME binary channel the board does, as
  ## the label of a reserved 1x1 sprite — the only path that survives a
  ## hosted replay.
  var label = chromeJson
  if label.len > MaxChromeLabelBytes:
    ## Drop the terminal panel's map rows rather than emit a truncated label.
    let start = label.find("\"map\":[")
    if start >= 0:
      let stop = label.find(']', start)
      if stop > start:
        label = label[0 ..< start] & "\"map\":[" & label[stop .. ^1]
  if label.len > MaxChromeLabelBytes:
    label = "{\"t\":0,\"mt\":1,\"ph\":\"playing\"}"
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], label)
