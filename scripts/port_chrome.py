#!/usr/bin/env python3
"""Apply the enumerated edits that turn the inherited coworld-ctf broadcast
page into the nethack one.

This is NOT a rewrite: `client/replay_broadcast.html` starts as a byte copy of
`coworld-ctf`'s page, and this script performs exactly the removals and label
re-mappings the design note's Viewer section lists, then the appended NETHACK
game block is added under its banner. Every replacement is asserted, so a
starter bump that moves one of these strings fails loudly instead of silently
skipping an edit.

Run once (from the repo root) against the pristine starter copy:

    python3 scripts/port_chrome.py client/replay_broadcast.html
"""

import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "client/replay_broadcast.html"


def cut(text, start, end, why):
    i = text.index(start)
    j = text.index(end, i) + len(end)
    return text[:i] + text[j:]


def sub(text, old, new, count=1):
    assert text.count(old) >= count, f"missing: {old[:90]!r}"
    return text.replace(old, new, count)


src = open(PATH, encoding="utf-8").read()

# --- adapter + shell identifiers -------------------------------------------
assert "window.CtfStaticReplay" in src
src = src.replace("window.CtfStaticReplay", "window.NethackStaticReplay")
src = sub(src, "'ctf-shell'", "'nethack-shell'")
src = src.replace("window.PaintballChrome", "window.NethackChrome")

# --- removed: #povBadge and the togglePov wiring ---------------------------
src = cut(src, "/* POV eye badge shown when a slot is inspected (fog-honesty lens) */",
          "#povBadge.on { display: flex; }\n", "povBadge CSS")
src = sub(src, '    <div id="povBadge">\U0001f441 POV lens — click to clear</div>\n', "")
src = sub(src, """  function renderPov(s) {
    var badge = $('povBadge');
    badge.classList.toggle('on', s.pov >= 0);
    if (s.pov >= 0) badge.textContent = '\U0001f441 POV: ' + shortName(rosterName(s, s.pov)) + ' — click to clear';
    renderFpv(s);
  }""", """  // NETHACK: one seat, so there is nothing to select and no POV badge. The
  // #fpv panel is repurposed as the TERMINAL and is always on; the appended
  // game block draws its text.
  function renderPov(s) {
    $('fpv').classList.add('on');
    renderFpv(s);
  }""")
src = sub(src, "  $('povBadge').addEventListener('click', function () { send('v:-1'); });\n", "")

# --- removed: #fpv-hp, #fpv-gear, #fpv-map, #fpv-map-canvas ----------------
src = cut(src, ".fpv-hp {", ".fpv-dead .fpv-hp, .fpv-dead .fpv-gear { opacity: 0.4; }\n",
          "fpv hp/gear CSS")
src = cut(src, "/* Un-fogged tactical minimap inset: top-right corner, BOARD aspect.",
          ".fpv-map canvas {\n  position: absolute;\n  inset: 0;\n  width: 100%;\n  height: 100%;\n",
          "fpv map CSS head")
src = sub(src, '        <span class="fpv-hp" id="fpv-hp"></span>\n', "")
src = sub(src, '        <span class="fpv-gear" id="fpv-gear"></span>\n', "")
src = sub(src, """      <!-- Un-fogged tactical minimap: arena walls + all units + hearts + the
           POV seat's vision wedge. Full context, no fog of war. -->
      <div class="fpv-map" id="fpv-map">
        <canvas id="fpv-map-canvas"></canvas>
      </div>
""", "")

# The two readouts those removed elements fed are only ever reached through
# renderFpv, which returns early with one seat — but a null element is one
# refactor away from a thrown frame, and a thrown frame latches the whole
# static shell into `failed` (the cogball 0.1.4 scar). Guard them.
src = sub(src, "    var hpEl = $('fpv-hp'), hpHtml = '';",
          "    var hpEl = $('fpv-hp'), hpHtml = '';\n    if (!hpEl) return;")
src = sub(src, "  function renderFpvMap(fp) {",
          "  function renderFpvMap(fp) {\n    if (!fpvMapEl) return;")

# --- removed: the beat-marker kinds this game never emits ------------------
src = cut(src,
          "/* kill ticks are short and colored by the KILLER's team (a red tick = red",
          ".beat-marker.capture { background: var(--tc, var(--amber)); width: calc(3 * var(--u)); height: calc(12 * var(--u)); }\n",
          "stale beat-marker CSS")

# --- the label re-mappings the design note enumerates ----------------------
src = sub(src, '<div class="fpv-cap" id="fpv-cap">EYES</div>',
          '<div class="fpv-cap" id="fpv-cap">TERMINAL 48\u00d718</div>')
src = sub(src, '<div class="caption" id="clock-caption">In the locker room</div>',
          '<div class="caption" id="clock-caption">Waiting for the cog</div>')
src = sub(src, '<div id="mmwarn">Replay hash mismatch — showing recorded inputs</div>',
          '<div id="mmwarn">Replay hash mismatch — showing recorded actions</div>')
assert "Filling hoppers with fresh paint&hellip;" in src
src = src.replace("Filling hoppers with fresh paint&hellip;", "Rolling up the dungeon&hellip;")
src = sub(src, """      'Filling hoppers with fresh paint\u2026',
      'Pump check: one, two. One, two\u2026',
      'Polishing visors to a mirror shine\u2026',
      'Shaking the paint pods awake\u2026',
      'Squats. Even robots warm up\u2026',
      'Topping off the CO\u2082\u2026',
      'Chalking up the wheels\u2026',
      'Reviewing the game plan\u2026'""",
"""      'Rolling up the dungeon\u2026',
      'Sharpening the dagger\u2026',
      'Trimming the lantern wick\u2026',
      'Counting the rations\u2026',
      'Oiling the leather\u2026',
      'Reading the rank titles aloud\u2026',
      'Chalking up the wheels\u2026',
      'Reviewing the descent\u2026'""")
src = sub(src, 'Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)',
          'Spoilers: descents and the death on the timeline ahead of the playhead (o)')
src = src.replace('<span class="momentum-label">LIVES LEAD</span>',
                  '<span class="momentum-label">DEPTH</span>')

# --- the scorebug plate: the CONTENTS change, the plate does not -----------
src = sub(src, """        plate.innerHTML =
          '<div class="hillchip" id="hill-' + team + '" title="Hill coverage">—</div>' +
          '<div class="team-id">' +
          '<div class="lives-line">' +
          '<span class="team-name plate-name" id="name-' + team + '">' + team.toUpperCase() + '</span>' +
          '<span class="hcap" id="hcap-' + team + '" style="display:none"></span>' +
          '<span class="lives-label pb-lbl">Hill</span>' +
          '<span class="lives-num" id="lives-' + team + '">—</span>' +
          '</div>' +
          '<div class="pb-sub">' +
          '<span class="pb-tags pb-lbl" id="tags-' + team + '"></span>' +
          '<span class="squad" id="squad-' + team + '"></span>' +
          '</div>' +
          '</div>';""",
"""        // NETHACK: the seat's real policy name, its in-game alias, the
        // running score as the numeral, an HP bar and a hunger chip.
        plate.innerHTML =
          '<div class="hungerchip" id="hunger-' + team + '" title="Hunger">—</div>' +
          '<div class="team-id">' +
          '<div class="lives-line">' +
          '<span class="team-name plate-name" id="name-' + team + '">' + team.toUpperCase() + '</span>' +
          '<span class="nh-alias" id="alias-' + team + '">ALPHA THE DIGGER</span>' +
          '<span class="hp-label pb-lbl">Score</span>' +
          '<span class="score-num" id="score-' + team + '">—</span>' +
          '</div>' +
          '<div class="pb-sub">' +
          '<span class="nh-stats pb-lbl" id="stats-' + team + '"></span>' +
          '<span class="hpbar" id="hpbar-' + team + '"></span>' +
          '</div>' +
          '</div>';""")

src = sub(src, """      if (PB_MODE) {
        var t = tr[team] || {};
        // PAINTBALL: the big numeral is HILL TIME HELD (M:SS), the chip is
        // live hill coverage, and the sub-line counts tag-outs. '—' until the
        // frame actually carries this team's entry.
        $('lives-' + team).textContent = tr[team] ? fmt(t.held || 0) : '—';
        var chip = $('hill-' + team);
        if (chip) {
          chip.textContent = tr[team] ? (t.cov || 0) + '%' : '—';
          chip.classList.toggle('own', !!t.own);
          chip.style.color = teamCol(team) || PAPER;
        }
        var tagsEl = $('tags-' + team);
        if (tagsEl) {
          tagsEl.textContent = tr[team]
            ? (t.tags || 0) + ' tags · ' + (t.cogs || 0) + ' up' : '';
        }
        renderSquad($('squad-' + team), s, team, s.pov);
        // leader pulse when this team leads every rival on banked hill time
        var bestPbRival = -Infinity;
        teams.forEach(function (o) {
          if (o !== team) bestPbRival = Math.max(bestPbRival, (tr[o] && tr[o].held) || 0);
        });
        var pbPlate = document.querySelector('.plate[data-team="' + team + '"]');
        if (pbPlate) {
          pbPlate.classList.toggle(
            'leader',
            (t.held || 0) - bestPbRival >= 5 && s.ph === 'playing'
          );
        }
        return;
      }""",
"""      if (PB_MODE) {
        // NETHACK: the big numeral is the running SCORE, the chip is the
        // hunger state, the sub-line is the run's own counters and the bar is
        // hit points. '—' until the frame actually carries the seat's entry.
        var nh = s.nh || {};
        var el = $('score-' + team);
        if (el) el.textContent = tr[team] ? String(nh.score || 0) : '—';
        var aliasEl = $('alias-' + team);
        if (aliasEl && nh.alias) {
          var alias = String(nh.alias).toUpperCase();
          if (aliasEl.textContent !== alias) aliasEl.textContent = alias;
        }
        var chip = $('hunger-' + team);
        if (chip) {
          chip.textContent = tr[team] ? (nh.hunger || '—') : '—';
          chip.classList.toggle('warn', nh.hunger === 'Hungry');
          chip.classList.toggle('bad',
            nh.hunger === 'Weak' || nh.hunger === 'Fainting');
        }
        var statsEl = $('stats-' + team);
        if (statsEl) {
          var line = tr[team]
            ? 'DL' + (nh.depth || 1) + ' · $' + (nh.gold || 0) + ' · ' +
              (nh.kills || 0) + ' slain' +
              ((nh.fallbacks || 0) > 0 ? ' · \\u21af' : '')
            : '';
          if (statsEl.textContent !== line) statsEl.textContent = line;
        }
        var barEl = $('hpbar-' + team);
        if (barEl) {
          var maxhp = Math.max(1, nh.maxhp || 1);
          var pct = Math.max(0, Math.min(100, Math.round((nh.hp || 0) * 100 / maxhp)));
          var key = pct + '/' + maxhp;
          if (barEl._key !== key) {
            barEl._key = key;
            barEl.innerHTML = '<i style="width:' + pct + '%"></i>';
          }
          barEl.title = 'HP ' + (nh.hp || 0) + '/' + maxhp;
          barEl.classList.toggle('low', pct <= 33);
        }
        return;
      }""")

# --- the endcard columns ---------------------------------------------------
src = sub(src, """        return '<div class="ec-row' + (mvp ? ' mvp' : '') + '">' +
          '<span class="pcell">' +
          '<span class="pname">' + esc(p.alias || shortName(rosterName(s, p.s))) + '</span>' +
          pbMarks +
          '</span>' +
          '<span class="n">' + (p.k || 0) + '</span>' +
          '<span class="n">' + (p.d || 0) + '</span>' +
          '<span class="n clstr">' + (tr.paint || 0) + '</span>' +
          '</div>';""",
"""        var nhRow = s.nh || {};
        return '<div class="ec-row' + (mvp ? ' mvp' : '') + '">' +
          '<span class="pcell">' +
          '<span class="pname">' + esc(p.alias || shortName(rosterName(s, p.s))) + '</span>' +
          pbMarks +
          '</span>' +
          '<span class="n">' + (nhRow.deepest || 1) + '</span>' +
          '<span class="n">' + (nhRow.gold || 0) + '</span>' +
          '<span class="n clstr">' + (nhRow.score || 0) + '</span>' +
          '</div>';""")
src = sub(src, "'<div class=\"ec-thead\"><span>Cog</span><span>Tags</span><span>Out</span><span>Paint</span></div>' +",
          "'<div class=\"ec-thead\"><span>Cog</span><span>Depth</span><span>Gold</span><span>Score</span></div>' +")
src = sub(src, "'<span class=\"fl-cap\">Hill time</span>' +",
          "'<span class=\"fl-cap\">Experience</span>' +")
src = sub(src, "'<div class=\"ec-thead\"><span>Player</span><span>K</span><span>D</span><span>Clstr</span><span>Cap</span></div>' +",
          "'<div class=\"ec-thead\"><span>Dlvl</span><span>Turns</span><span>Kills</span><span>Gold</span><span>Seen</span></div>' +")
src = sub(src, "'<span class=\"fl-cap\">Lives left</span>' +",
          "'<span class=\"fl-cap\">Deepest level</span>' +")

# --- the appended NETHACK game block ---------------------------------------
marker = "<!-- ============================================================\n     PAINTBALL additions"
i = src.index(marker)
block = open("client/nethack_block.html", encoding="utf-8").read()
src = src[:i] + block

open(PATH, "w", encoding="utf-8").write(src)
print("chrome ported:", len(src), "bytes")
