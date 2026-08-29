#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of a binary COWLDNET replay.

Python 3 standard library only: no Nim, no Docker, no dependencies. This is
the phase-60 forensic path for a coworld whose replay is binary — the shared
`docker_smoke.sh` runs with SMOKE_REQUIRE_REPLAY_JSON=0, and this is what
makes the bytes readable anyway:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null
    jq -r '.protocol, .results.reason, .results.endRule, .results.depthReached' /tmp/ep.json
    jq -r '[.plans[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json

Every string it emits came out of the replay as UTF-8 and is re-encoded as
UTF-8, so the output parses under a STRICT parser and carries no lone
surrogates: the writer truncates on rune boundaries precisely so this holds.
"""

import json
import struct
import sys

MAGIC = b"COWLDNET"
TICK_HASH, INPUT, JOIN, LEAVE, CHAT, DEBUG_SPRITE = 1, 2, 3, 4, 5, 6


class Reader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, count):
        if self.offset + count > len(self.data):
            raise ValueError("truncated replay")
        chunk = self.data[self.offset:self.offset + count]
        self.offset += count
        return chunk

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def i16(self):
        return struct.unpack("<h", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def string(self):
        return self.take(self.u16()).decode("utf-8")


def parse(path):
    data = open(path, "rb").read()
    if not data.startswith(MAGIC):
        raise SystemExit(f"not a COWLDNET replay: {path}")
    reader = Reader(data)
    reader.take(len(MAGIC))
    reader.u16()                       # format version
    game_name = reader.string()
    game_version = reader.string()
    reader.u64()                       # written-at, milliseconds
    config = json.loads(reader.string())

    joins, chats, ticks = [], [], 0
    last_tick = -1
    while reader.offset < len(data):
        kind = reader.u8()
        if kind == TICK_HASH:
            tick = reader.u32()
            reader.u64()
            if tick <= last_tick:
                break              # the codec's own rhoStop rule
            last_tick = tick
            ticks += 1
        elif kind == INPUT:
            reader.u32(), reader.u8(), reader.u8()
        elif kind == JOIN:
            reader.u32()
            player = reader.u8()
            name = reader.string()
            slot = reader.i16()
            reader.string()
            joins.append({"player": player, "name": name, "slot": slot})
        elif kind == LEAVE:
            reader.u32(), reader.u8()
        elif kind == CHAT:
            reader.u32()
            reader.u8()
            chats.append(reader.string())
        elif kind == DEBUG_SPRITE:
            reader.u32()
            reader.u8()
            reader.take(reader.u32())
        else:
            break
    return game_name, game_version, config, joins, chats, ticks


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: replay_summary.py <replay path>")
    game_name, game_version, config, joins, chats, ticks = parse(sys.argv[1])

    plans, says, results, kinds, aliases = [], [], {}, [], []
    fallbacks = 0
    for raw in chats:
        if not raw.startswith("{"):
            continue
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        kind = record.get("k")
        if kind == "register":
            kinds.append(record.get("kind", ""))
            aliases.append(record.get("alias", ""))
        elif kind == "directive":
            plans.append({
                "turn": record.get("turn"),
                "depth": record.get("depth"),
                "source": record.get("source"),
                "verbs": [a.get("do") for a in record.get("actions") or []],
                "truncated": record.get("truncated"),
                "dropped": record.get("dropped"),
                "unreachable": record.get("unreachable"),
            })
            if record.get("say"):
                says.append(record["say"])
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "result":
            results = record.get("results") or {}

    summary = {
        "protocol": "nethack/v1",
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant"),
        "names": [j["name"] for j in joins],
        "aliases": aliases,
        "policyKinds": kinds,
        "tickCount": ticks,
        "plans": plans,
        "says": says,
        "fallbacks": fallbacks,
        "results": results,
    }
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
