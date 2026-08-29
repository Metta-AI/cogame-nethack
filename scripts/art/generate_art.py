#!/usr/bin/env python3
"""Generate the cogame-nethack board art with nano-banana (Gemini image gen).

Two sheets, both anchored on the Softmax cog reference so the style is
consistent across the board:

  cog_sheet.png      one figure  — ALPHA THE DIGGER, the seat's own cog
  monsters_sheet_a.png  four figures — grid bug, sewer rat, lichen, jackal
  monsters_sheet_b.png  four figures — kobold, gnome, gnome zombie, floating eye
  monsters_sheet_c.png  four figures — hill orc, dwarf, gnome mummy, the Oracle

Run from the repo root with GEMINI_API_KEY in the environment:

    python3 scripts/art/generate_art.py

The key is NEVER printed, never written to a file and never passed as a URL
parameter: it is the header `x-goog-api-key`, which the vault substitutes on
egress to generativelanguage.googleapis.com only.

CI does not regenerate art — the source sheets and the split sprites are
committed. This script exists so the assets are reproducible, not mysterious.
"""

import base64
import json
import os
import sys
import urllib.request

ENDPOINT = ("https://generativelanguage.googleapis.com/v1beta/models/"
            "gemini-2.5-flash-image:generateContent")

BACKDROP = ("Background: perfectly flat, solid, uniform pure bright green "
            "(#00FF00), no shadows, no gradients, no floor, no text, no "
            "labels — it will be chroma-keyed out.")

SHEETS = {
    "cog_sheet.png": (
        "Using this robot character (\"cog\") as the exact character design "
        "reference, draw ONE of these cogs, full body, front-facing, centred, "
        "same clean cartoon rendering, as a DUNGEON DELVER: battered brown "
        "leather armour over its chassis, a short steel dagger in its right "
        "hand, a small burning lantern clipped to its shoulder, a dusty "
        "adventurer's pack. Heroic, readable at small size. " + BACKDROP),
    "monsters_sheet_a.png": (
        "Draw FOUR fantasy dungeon monsters side by side in one row, evenly "
        "spaced, same size, full body, front-facing, in the same clean bold "
        "cartoon style as the reference robot art (thick dark outlines, flat "
        "saturated colours, chunky silhouettes). LEFT: a small purple "
        "insect-like GRID BUG with two glowing antennae. SECOND: a grey-brown "
        "SEWER RAT with a long tail. THIRD: a lumpy green LICHEN, a shambling "
        "fungus blob with fronds. RIGHT: a lean tawny JACKAL, snarling. "
        + BACKDROP),
    "monsters_sheet_b.png": (
        "Draw FOUR fantasy dungeon monsters side by side in one row, evenly "
        "spaced, same size, full body, front-facing, in the same clean bold "
        "cartoon style as the reference robot art (thick dark outlines, flat "
        "saturated colours, chunky silhouettes). LEFT: a scrappy orange-brown "
        "KOBOLD with a crude club. SECOND: a blue-hatted GNOME with a pickaxe "
        "and a bag of gold. THIRD: a grey rotting GNOME ZOMBIE, arms out. "
        "RIGHT: a FLOATING EYE — a single huge blue eyeball hovering, no "
        "limbs, faint magical glow. " + BACKDROP),
    "monsters_sheet_c.png": (
        "Draw FOUR fantasy dungeon figures side by side in one row, evenly "
        "spaced, same size, full body, front-facing, in the same clean bold "
        "cartoon style as the reference robot art (thick dark outlines, flat "
        "saturated colours, chunky silhouettes). LEFT: a burly green HILL ORC "
        "with a notched axe. SECOND: a stocky bearded DWARF in iron mail with "
        "a mattock. THIRD: a bandage-wrapped GNOME MUMMY, small and grey. "
        "RIGHT: THE ORACLE — a serene robed woman in white and gold, arms "
        "raised, mystical. " + BACKDROP),
}


def generate(reference_png: str, prompt: str, out_path: str) -> None:
    with open(reference_png, "rb") as handle:
        reference = base64.b64encode(handle.read()).decode()
    body = {
        "contents": [{
            "parts": [
                {"inline_data": {"mime_type": "image/png", "data": reference}},
                {"text": prompt},
            ]
        }],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": os.environ["GEMINI_API_KEY"],
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    part = next(p for p in payload["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes)")


def main() -> int:
    reference = "data/soldier_red_front.png"
    only = sys.argv[1:] or list(SHEETS)
    for name in only:
        generate(reference, SHEETS[name], os.path.join("scripts/art/source", name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
