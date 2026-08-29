## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id, the
## board's cell size). Rendered ONCE, from the same Nim consts the engine
## runs on; `tools/gen_wire_constants.nim` emits it for the static wasm
## bundle and `server.nim` splices it into every served client page.

import std/strutils

import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add(",")
    result.add($value)
  result.add("]")

const WireConstantsJs* =
  "window.NETHACK_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cell:" & $CellPx &
  ",levelW:" & $LevelW &
  ",levelH:" & $LevelH &
  "};window.CTF_WIRE=window.NETHACK_WIRE;"
    ## The fork renamed the wire global, but `client/chrome_common.js` is kept
    ## BYTE-IDENTICAL to the starter's and reads `window.CTF_WIRE` for the
    ## speed chips and the presentation fps. Without the alias it fell back to
    ## the starter's [1,2,3,4,8,16], so the transport drew six chips of which
    ## `3x` and `16x` sent commands `replays.applySpeedCommand` does not
    ## handle and no chip could ever highlight. The alias is the one-line fix
    ## that keeps the byte pin intact: both names point at the same object, so
    ## the chips are this game's own PlaybackSpeeds.

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
