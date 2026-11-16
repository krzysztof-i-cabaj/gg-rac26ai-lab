#!/usr/bin/env python3
# ==============================================================================
# Tytul:        make_charts.py
# Opis:         Wykresy wynikow testow awarii z results/runs/** jako recznie skladane SVG (tylko
#               biblioteka standardowa): RTO wg testu z mediana, lag w czasie z t_fault i t_lag_ok,
#               os zdarzen (gantt) stanow zasobow dla jednego reprezentatywnego przebiegu na test.
#               Etykiety EN w <nazwa>.svg, PL w <nazwa>_pl.svg. Jasne tlo, czytelne na GitHubie.
# Description [EN]: Charts of the failure-test results from results/runs/** as hand-built SVG
#               (standard library only): RTO per test with the median, lag over time with t_fault and
#               t_lag_ok, event timeline (gantt) of resource states for one representative run per test.
#               EN labels in <name>.svg, PL labels in <name>_pl.svg. Light background, readable on GitHub.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Python 3.8+, bez dodatkowych pakietow; dane w results/runs/<test>-<znacznik>/
# Requirements [EN]: - Python 3.8+, no extra packages; data in results/runs/<test>-<stamp>/
#
# Uzycie [PL]:       python tools/make_charts.py [--runs results/runs] [--out docs/img/results]
# Usage [EN]:        python tools/make_charts.py [--runs results/runs] [--out docs/img/results]
# ==============================================================================
"""Build the result charts of the failure tests as SVG files (no third-party packages)."""
import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path
from xml.sax.saxutils import escape

# Palette: categorical slots 1-3 for runs, fixed status colors for states, neutral inks (light surface)
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
RUN_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]
BAR = "#2a78d6"
STATE_COLORS = {"up": "#0ca30c", "down": "#d03b3b", "transit": "#fab219", "unknown": "#b4b2a9"}
FONT = "font-family=\"system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif\""

LAG_TESTS = ["T1", "T2", "T3", "T4b", "T5", "T6", "T7"]
RTO_TESTS = ["T1", "T2", "T3", "T4", "T4b", "T5", "T6", "T7"]
GANTT_TESTS = ["T1", "T2", "T3", "T4", "T4b", "T5", "T6", "T7"]

TEXT = {
    "en": {
        "rto_title": "Recovery time (RTO) per failure test",
        "rto_sub": "Passed runs only, seconds from the fault to the last chain marker (here: lag below 30 s). Line = median.",
        "rto_axis": "seconds after the fault",
        "median": "median",
        "no_auto": "no automatic recovery",
        "no_auto2": "({n}/{n} runs, 900 s window)",
        "manual": "incl. manual move",
        "lag_title": "{t}: replication lag around the fault",
        "lag_sub": "Lag = incoming_lag + age of the last heartbeat (target view ggadmin.gg_lag), 1 s samples.",
        "lag_axis_x": "seconds relative to the fault (t_fault = 0)",
        "lag_axis_y": "lag [s]",
        "threshold": "threshold 30 s",
        "fault": "fault",
        "run": "run {i}",
        "lag_ok": "lag OK {s} s",
        "interv": "manual move {s} s",
        "gantt_title": "{t}: resource states over time (run {d})",
        "gantt_sub": "One bar per resource; text in the bar = node; lines = markers from summary.json. EXT1/DP1 are not observable while the XAG resource is down.",
        "state_up": "up (ONLINE / RUNNING / Active)",
        "state_down": "down (OFFLINE / STOPPED / Inactive)",
        "state_transit": "in between (INTERMEDIATE / ABENDED)",
        "state_unknown": "unknown / not observable",
        "m_fault": "fault", "m_detect": "detect", "m_lag_ok": "lag OK", "m_interv": "manual move",
        "m_end": "no recovery until the end of the observation",
        "rows": {"node:ggrac1": "node ggrac1", "node:ggrac2": "node ggrac2", "inst:ggcdb1": "instance ggcdb1",
                 "inst:ggcdb2": "instance ggcdb2", "svc": "service gg_srcpdb", "acfs": "ACFS OGGVOL",
                 "vip": "VIP oggvip", "sm": "XAG resource (SM)", "EXT1": "Extract EXT1", "DP1": "Path DP1",
                 "REP1": "Replicat REP1"},
        "footer": "Measured 16.11.2026 on VirtualBox (laptop), 3 vCPU per RAC node, load 10 rows/s per instance.",
    },
    "pl": {
        "rto_title": "Czas powrotu (RTO) w testach awarii",
        "rto_sub": "Tylko zaliczone przebiegi; sekundy od awarii do ostatniego znacznika (tu: lag poniżej 30 s). Kreska = mediana.",
        "rto_axis": "sekundy od awarii",
        "median": "mediana",
        "no_auto": "brak samodzielnego powrotu",
        "no_auto2": "({n}/{n} przebiegi, okno 900 s)",
        "manual": "z ręcznym przeniesieniem",
        "lag_title": "{t}: opóźnienie replikacji wokół awarii",
        "lag_sub": "Lag = incoming_lag + wiek ostatniego heartbeatu (widok ggadmin.gg_lag na celu), próbki co 1 s.",
        "lag_axis_x": "sekundy względem awarii (t_fault = 0)",
        "lag_axis_y": "lag [s]",
        "threshold": "próg 30 s",
        "fault": "awaria",
        "run": "przebieg {i}",
        "lag_ok": "lag OK {s} s",
        "interv": "ręczne przeniesienie {s} s",
        "gantt_title": "{t}: stany zasobów w czasie (przebieg {d})",
        "gantt_sub": "Jeden pasek na zasób; napis w pasku = węzeł; linie = znaczniki z summary.json. EXT1/DP1 niewidoczne, gdy zasób XAG nie działa.",
        "state_up": "działa (ONLINE / RUNNING / Active)",
        "state_down": "nie działa (OFFLINE / STOPPED / Inactive)",
        "state_transit": "stan pośredni (INTERMEDIATE / ABENDED)",
        "state_unknown": "nieznany / niewidoczny",
        "m_fault": "awaria", "m_detect": "wykrycie", "m_lag_ok": "lag OK", "m_interv": "ręczne przeniesienie",
        "m_end": "brak powrotu do końca obserwacji",
        "rows": {"node:ggrac1": "węzeł ggrac1", "node:ggrac2": "węzeł ggrac2", "inst:ggcdb1": "instancja ggcdb1",
                 "inst:ggcdb2": "instancja ggcdb2", "svc": "serwis gg_srcpdb", "acfs": "ACFS OGGVOL",
                 "vip": "VIP oggvip", "sm": "zasób XAG (SM)", "EXT1": "Extract EXT1", "DP1": "ścieżka DP1",
                 "REP1": "Replicat REP1"},
        "footer": "Pomiar 16.11.2026 w VirtualBox (laptop), 3 vCPU na węzeł RAC, obciążenie 10 wierszy/s na instancję.",
    },
}
ROW_ORDER = ["node:ggrac1", "node:ggrac2", "inst:ggcdb1", "inst:ggcdb2", "svc", "acfs", "vip", "sm", "EXT1", "DP1", "REP1"]


def fmt(v):
    """Number with one decimal, dot as separator in EN and comma in PL is applied by the caller."""
    return f"{v:.1f}"


def num(v, lang):
    s = fmt(v)
    return s.replace(".", ",") if lang == "pl" else s


def load_runs(root):
    runs = []
    for d in sorted(p for p in root.iterdir() if p.is_dir()):
        m = re.match(r"^(T\d+b?)-(\d{8}-\d{6})$", d.name)
        sp = d / "summary.json"
        if not m or not sp.exists():
            continue
        s = json.loads(sp.read_text(encoding="utf-8"))
        lag = []
        if (d / "lag.csv").exists():
            with open(d / "lag.csv", encoding="utf-8", newline="") as f:
                for r in csv.DictReader(f):
                    try:
                        lag.append((float(r["t_rel_s"]), float(r["lag_s"])))
                    except (KeyError, ValueError):
                        pass
        events = []
        if (d / "events.csv").exists():
            with open(d / "events.csv", encoding="utf-8", newline="") as f:
                events = list(csv.DictReader(f))
        runs.append({"dir": d.name, "test": m.group(1), "stamp": m.group(2), "s": s, "lag": lag, "events": events})
    return runs


def is_pass(r):
    s = r["s"]
    return s.get("pass") is True and not s.get("measurement_error") and s.get("rto_s") is not None


def nice_max(v, step):
    return max(step, math.ceil(v / step) * step)


def svg_open(w, h, title):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" {FONT}>',
            f"<title>{escape(title)}</title>",
            f'<rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="10" fill="{SURFACE}" stroke="{AXIS}"/>']


def text(x, y, s, size=12, fill=INK2, anchor="start", weight="normal"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" text-anchor="{anchor}" '
            f'font-weight="{weight}">{escape(s)}</text>')


def chart_rto(runs, lang):
    t = TEXT[lang]
    w, h = 960, 460
    left, right, top, bottom = 70, 30, 90, 70
    pw, ph = w - left - right, h - top - bottom
    groups = []
    for tid in RTO_TESTS:
        ok = [r for r in runs if r["test"] == tid and is_pass(r)]
        groups.append((tid, [r["s"]["rto_s"] for r in ok]))
    ymax = nice_max(max(v for _, vs in groups for v in vs), 50)
    y = lambda v: top + ph - v / ymax * ph
    out = svg_open(w, h, t["rto_title"])
    out.append(text(20, 32, t["rto_title"], 18, INK, weight="600"))
    out.append(text(20, 54, t["rto_sub"], 12))
    for v in range(0, int(ymax) + 1, 50):
        out.append(f'<line x1="{left}" y1="{y(v):.1f}" x2="{w - right}" y2="{y(v):.1f}" stroke="{GRID if v else AXIS}"/>')
        out.append(text(left - 8, y(v) + 4, str(v), 11, MUTED, "end"))
    out.append(f'<text transform="translate(18,{top + ph / 2:.0f}) rotate(-90)" font-size="11" fill="{MUTED}" '
               f'text-anchor="middle">{escape(t["rto_axis"])}</text>')
    gw = pw / len(groups)
    for gi, (tid, vals) in enumerate(groups):
        gx = left + gi * gw
        cx = gx + gw / 2
        out.append(text(cx, top + ph + 20, tid, 13, INK, "middle", "600"))
        if tid == "T4b":
            out.append(text(cx, top + ph + 36, t["manual"], 10, MUTED, "middle"))
        if not vals:
            n = len([r for r in runs if r["test"] == tid and r["s"].get("markers", {}).get("t_fault") is not None
                     and not r["s"].get("harness_error") and r["s"].get("recovered") is False])
            out.append(f'<rect x="{gx + 10:.1f}" y="{top + 10}" width="{gw - 20:.1f}" height="{ph - 10}" rx="4" '
                       f'fill="none" stroke="{STATE_COLORS["down"]}" stroke-dasharray="4 3"/>')
            out.append(text(cx, top + ph / 2 - 6, t["no_auto"], 11, INK, "middle"))
            out.append(text(cx, top + ph / 2 + 10, t["no_auto2"].format(n=n), 10, INK2, "middle"))
            continue
        bw = min(22, (gw - 24) / len(vals) - 2)
        x0 = cx - (len(vals) * (bw + 2) - 2) / 2
        for i, v in enumerate(vals):
            bx = x0 + i * (bw + 2)
            tip = "{} {}: {} s".format(tid, t["run"].format(i=i + 1), num(v, lang))
            out.append(f'<path d="M{bx:.1f},{y(0):.1f} V{y(v) + 4:.1f} q0,-4 4,-4 h{bw - 8:.1f} q4,0 4,4 V{y(0):.1f} Z" '
                       f'fill="{BAR}"><title>{escape(tip)}</title></path>')
        med = statistics.median(vals)
        out.append(f'<line x1="{x0 - 6:.1f}" y1="{y(med):.1f}" x2="{x0 + len(vals) * (bw + 2) + 4:.1f}" y2="{y(med):.1f}" '
                   f'stroke="{INK}" stroke-width="2"/>')
        label = f"{num(med, lang)} s" if len(vals) >= 3 else f"{num(vals[0], lang)} s"
        out.append(text(cx, y(max(vals)) - 8, (t["median"] + " " if len(vals) >= 3 else "") + label, 11, INK, "middle"))
    out.append(text(20, h - 14, t["footer"], 11, MUTED))
    out.append("</svg>")
    return "\n".join(out)


def chart_lag(runs, tid, lang):
    t = TEXT[lang]
    ok = [r for r in runs if r["test"] == tid and is_pass(r)]
    if not ok:
        return None
    w, h = 960, 440
    left, right, top, bottom = 64, 30, 100, 70
    pw, ph = w - left - right, h - top - bottom
    xmin = -60.0
    ends = []
    for r in ok:
        mk = r["s"].get("markers", {})
        ends.append(mk.get("t_lag_ok") or 0)
        if r["s"].get("lag_relapse_first_s"):
            ends.append(r["s"]["lag_relapse_first_s"])
    xmax = nice_max(max(ends) + 60, 30)
    vis = [v for r in ok for (x, v) in r["lag"] if xmin <= x <= xmax]
    ymax = nice_max(max(vis + [40]), 50 if max(vis) > 100 else 10)
    X = lambda v: left + (v - xmin) / (xmax - xmin) * pw
    Y = lambda v: top + ph - v / ymax * ph
    out = svg_open(w, h, t["lag_title"].format(t=tid))
    out.append(text(20, 32, t["lag_title"].format(t=tid), 18, INK, weight="600"))
    out.append(text(20, 54, t["lag_sub"], 12))
    ystep = 50 if ymax > 200 else (25 if ymax > 100 else 10)
    for v in range(0, int(ymax) + 1, ystep):
        out.append(f'<line x1="{left}" y1="{Y(v):.1f}" x2="{w - right}" y2="{Y(v):.1f}" stroke="{GRID if v else AXIS}"/>')
        out.append(text(left - 8, Y(v) + 4, str(v), 11, MUTED, "end"))
    xstep = 60 if xmax - xmin > 400 else 30
    v = math.ceil(xmin / xstep) * xstep
    while v <= xmax:
        out.append(text(X(v), top + ph + 18, str(int(v)), 11, MUTED, "middle"))
        out.append(f'<line x1="{X(v):.1f}" y1="{top + ph}" x2="{X(v):.1f}" y2="{top + ph + 4}" stroke="{AXIS}"/>')
        v += xstep
    out.append(text(left + pw / 2, top + ph + 40, t["lag_axis_x"], 11, MUTED, "middle"))
    out.append(f'<text transform="translate(18,{top + ph / 2:.0f}) rotate(-90)" font-size="11" fill="{MUTED}" '
               f'text-anchor="middle">{escape(t["lag_axis_y"])}</text>')
    # threshold and fault
    out.append(f'<line x1="{left}" y1="{Y(30):.1f}" x2="{w - right}" y2="{Y(30):.1f}" stroke="{INK2}" stroke-dasharray="6 4"/>')
    out.append(text(w - right - 4, Y(30) - 5, t["threshold"], 11, INK2, "end"))
    out.append(f'<line x1="{X(0):.1f}" y1="{top}" x2="{X(0):.1f}" y2="{top + ph}" stroke="{INK}" stroke-width="1.5"/>')
    out.append(text(X(0) + 4, top + 12, t["fault"], 11, INK))
    # legend (one row above the plot)
    lx = 20
    for i, r in enumerate(ok):
        c = RUN_COLORS[i % len(RUN_COLORS)]
        mk = r["s"]["markers"]
        lbl = f'{t["run"].format(i=i + 1)} · {t["lag_ok"].format(s=num(mk["t_lag_ok"], lang))}'
        out.append(f'<line x1="{lx}" y1="76" x2="{lx + 18}" y2="76" stroke="{c}" stroke-width="3" stroke-linecap="round"/>')
        out.append(text(lx + 24, 80, lbl, 12, INK))
        lx += 24 + len(lbl) * 6.6 + 24
    for i, r in enumerate(ok):
        c = RUN_COLORS[i % len(RUN_COLORS)]
        pts = [(x, v) for (x, v) in r["lag"] if xmin <= x <= xmax]
        d = " ".join(f"{'M' if k == 0 else 'L'}{X(x):.1f},{Y(v):.1f}" for k, (x, v) in enumerate(pts))
        out.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="2" stroke-linejoin="round">'
                   f'<title>{escape(t["run"].format(i=i + 1))}</title></path>')
        mk = r["s"]["markers"]
        lo = mk.get("t_lag_ok")
        if lo is not None:
            out.append(f'<line x1="{X(lo):.1f}" y1="{top}" x2="{X(lo):.1f}" y2="{top + ph}" stroke="{c}" stroke-width="1.5" '
                       f'stroke-dasharray="3 3"><title>{escape(t["lag_ok"].format(s=num(lo, lang)))}</title></line>')
            out.append(f'<circle cx="{X(lo):.1f}" cy="{Y(min(29, ymax)):.1f}" r="4" fill="{c}" stroke="{SURFACE}" stroke-width="2"/>')
        iv = mk.get("t_intervention")
        if iv is not None:
            out.append(f'<path d="M{X(iv):.1f},{top + 22} l-5,-9 h10 Z" fill="{c}" stroke="{SURFACE}" stroke-width="1"/>')
            out.append(text(X(iv) + 7, top + 22 + 12 * i, t["interv"].format(s=num(iv, lang)), 10, INK2))
    out.append(text(20, h - 14, t["footer"], 11, MUTED))
    out.append("</svg>")
    return "\n".join(out)


def state_class(state):
    s = (state or "").upper()
    if s in ("ONLINE", "RUNNING", "ACTIVE"):
        return "up"
    if s in ("OFFLINE", "STOPPED", "INACTIVE"):
        return "down"
    if s in ("INTERMEDIATE", "ABENDED", "STARTING", "STOPPING"):
        return "transit"
    return "unknown"


def pick_representative(runs, tid):
    ok = sorted((r for r in runs if r["test"] == tid and is_pass(r)), key=lambda r: r["s"]["rto_s"])
    if ok:
        return ok[(len(ok) - 1) // 2] if len(ok) % 2 == 0 else ok[len(ok) // 2]
    real = [r for r in runs if r["test"] == tid and r["events"] and r["s"].get("markers", {}).get("t_fault") is not None
            and not r["s"].get("harness_error") and not r["s"].get("measurement_error")]
    return real[0] if real else None


def chart_gantt(runs, tid, lang):
    t = TEXT[lang]
    r = pick_representative(runs, tid)
    if not r:
        return None
    mk = r["s"].get("markers", {})
    ev = [e for e in r["events"] if e["resource"] != "fault"]
    for e in ev:
        e["t"] = float(e["t_rel_s"])
    rows = [k for k in ROW_ORDER if any(e["resource"] == k for e in ev)]
    end = mk.get("t_lag_ok")
    recovered = end is not None
    xmin = -20.0
    if recovered:
        xmax = nice_max(end + 40, 20)
    else:
        # no recovery: show the whole observation window (last lag sample)
        last = max([x for x, _ in r["lag"]] + [e["t"] for e in ev])
        xmax = nice_max(last, 60)
    # EXT1 and DP1 are read through the source Service Manager: while the XAG resource is not ONLINE
    # their state cannot be observed (the probe keeps no fresh line for them), so it is drawn as unknown
    sm_seq = sorted((e for e in ev if e["resource"] == "sm"), key=lambda e: e["t"])
    sm_down = []
    for j, e in enumerate(sm_seq):
        if state_class(e["state_to"]) != "up":
            sm_down.append((e["t"], sm_seq[j + 1]["t"] if j + 1 < len(sm_seq) else float("inf")))
    w = 960
    left, right, top = 170, 30, 118
    rh = 26
    h = top + len(rows) * rh + 92
    pw = w - left - right
    X = lambda v: left + (min(max(v, xmin), xmax) - xmin) / (xmax - xmin) * pw
    out = svg_open(w, h, t["gantt_title"].format(t=tid, d=r["stamp"]))
    out.append(text(20, 32, t["gantt_title"].format(t=tid, d=r["stamp"]), 18, INK, weight="600"))
    out.append(text(20, 54, t["gantt_sub"], 12))
    lx = 20
    for k in ("up", "transit", "down", "unknown"):
        lbl = t["state_" + k]
        out.append(f'<rect x="{lx}" y="68" width="14" height="12" rx="3" fill="{STATE_COLORS[k]}"/>')
        out.append(text(lx + 20, 79, lbl, 11, INK))
        lx += 20 + len(lbl) * 6.0 + 22
    bottom_y = top + len(rows) * rh
    xstep = 60 if xmax - xmin > 400 else (20 if xmax - xmin <= 200 else 30)
    v = math.ceil(xmin / xstep) * xstep
    while v <= xmax:
        out.append(f'<line x1="{X(v):.1f}" y1="{top}" x2="{X(v):.1f}" y2="{bottom_y}" stroke="{GRID}"/>')
        out.append(text(X(v), bottom_y + 16, str(int(v)), 11, MUTED, "middle"))
        v += xstep
    out.append(text(left + pw / 2, bottom_y + 34, TEXT[lang]["lag_axis_x"], 11, MUTED, "middle"))
    for i, res in enumerate(rows):
        y0 = top + i * rh
        out.append(text(left - 10, y0 + rh / 2 + 4, t["rows"].get(res, res), 12, INK, "end"))
        seq = sorted((e for e in ev if e["resource"] == res), key=lambda e: e["t"])
        pieces = []
        for j, e in enumerate(seq):
            a = e["t"]
            b = seq[j + 1]["t"] if j + 1 < len(seq) else xmax
            cls = state_class(e["state_to"])
            node = e["node"] if e["node"] and e["node"] != "-" else ""
            cuts = [(a, b, cls, node, e["state_to"])]
            if res in ("EXT1", "DP1"):
                for da, db in sm_down:
                    nxt = []
                    for (pa, pb, pc, pn, ps) in cuts:
                        lo, hi = max(pa, da), min(pb, db)
                        if lo >= hi:
                            nxt.append((pa, pb, pc, pn, ps))
                            continue
                        if pa < lo:
                            nxt.append((pa, lo, pc, pn, ps))
                        nxt.append((lo, hi, "unknown", "", t["state_unknown"]))
                        if hi < pb:
                            nxt.append((hi, pb, pc, pn, ps))
                    cuts = nxt
            pieces.extend(cuts)
        for (a, b, cls, node, state) in pieces:
            if b < xmin or a > xmax:
                continue
            x1, x2 = X(a), X(b)
            if x2 - x1 < 0.5:
                continue
            e = {"state_to": state}
            tip = f'{t["rows"].get(res, res)}: {e["state_to"]}{" @ " + node if node else ""} [{num(max(a, xmin), lang)} .. {num(b, lang)} s]'
            out.append(f'<rect x="{x1 + 1:.1f}" y="{y0 + 5}" width="{max(x2 - x1 - 2, 1):.1f}" height="{rh - 10}" rx="4" '
                       f'fill="{STATE_COLORS[cls]}"><title>{escape(tip)}</title></rect>')
            if node and x2 - x1 > 52 and not res.startswith(("node:", "inst:")):
                fill = "#ffffff" if cls in ("up", "down") else INK
                out.append(text((x1 + x2) / 2, y0 + rh / 2 + 4, node, 11, fill, "middle", "600"))
    marks = [("t_fault", t["m_fault"]), ("t_crs_detect", t["m_detect"]), ("t_intervention", t["m_interv"]),
             ("t_lag_ok", t["m_lag_ok"])]
    placed = []
    for key, lbl in marks:
        v = mk.get(key)
        if v is None:
            continue
        x = X(v)
        level = 0
        while any(abs(x - px) < 90 and pl == level for px, pl in placed):
            level += 1
        placed.append((x, level))
        ly = top - 8 - level * 13
        out.append(f'<line x1="{x:.1f}" y1="{ly + 3:.1f}" x2="{x:.1f}" y2="{bottom_y}" stroke="{INK}" stroke-width="1.2" '
                   f'stroke-dasharray="{"none" if key == "t_fault" else "4 3"}"/>')
        out.append(text(x, ly, f"{lbl} {num(v, lang)} s", 11, INK, "middle"))
    if not recovered:
        out.append(text(w - right - 4, top - 8, t["m_end"] + f" ({int(xmax)} s)", 11, STATE_COLORS["down"], "end", "600"))
    out.append(text(20, h - 14, t["footer"], 11, MUTED))
    out.append("</svg>")
    return "\n".join(out)


def write(path, content, written):
    path.write_bytes((content + "\n").encode("utf-8"))
    written.append(path)


def main():
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs", default=str(repo / "results" / "runs"))
    ap.add_argument("--out", default=str(repo / "docs" / "img" / "results"))
    a = ap.parse_args()
    runs = load_runs(Path(a.runs))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    written = []
    for lang, suf in (("en", ""), ("pl", "_pl")):
        write(out / f"rto_by_test{suf}.svg", chart_rto(runs, lang), written)
        for tid in LAG_TESTS:
            c = chart_lag(runs, tid, lang)
            if c:
                write(out / f"lag_{tid}{suf}.svg", c, written)
        for tid in GANTT_TESTS:
            c = chart_gantt(runs, tid, lang)
            if c:
                write(out / f"timeline_{tid}{suf}.svg", c, written)
    for p in written:
        print(p)


if __name__ == "__main__":
    main()
