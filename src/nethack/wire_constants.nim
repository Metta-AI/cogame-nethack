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
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
