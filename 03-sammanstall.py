#!/usr/bin/env python3
"""Sammanställer resultat/resultat.csv till tabeller (endast standardbiblioteket)."""
import csv
import statistics
import sys
from collections import OrderedDict
from pathlib import Path

here = Path(__file__).resolve().parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "resultat" / "resultat.csv"
rows = list(csv.DictReader(src.open(encoding="utf-8")))
if not rows:
    sys.exit("Inga rader i " + str(src))


def fmt(values):
    if not values:
        return "-", "-", "-"
    return (f"{statistics.median(values):.1f}", f"{min(values):.1f}", f"{max(values):.1f}")


def floats(items, key):
    return [float(r[key]) for r in items if r[key] not in ("", None)]


out = []
groups = OrderedDict()
for r in rows:
    groups.setdefault((r["serie"], r["test"], r["namn"]), []).append(r)

out.append("SERIE A: utfall per ändring")
out.append(f"{'Test':<5}{'Ändring':<34}{'n':>3}{'Upptäckt':>10}{'Återställd':>12}"
           f"{'Median s':>10}{'Min s':>8}{'Max s':>8}")
for (serie, test, namn), items in groups.items():
    if serie != "A":
        continue
    det = sum(r["upptackt"] == "ja" for r in items)
    res = [r for r in items if r["aterstalld"] == "ja"]
    med, lo, hi = fmt(floats(res, "tid_till_aterstallning_s"))
    out.append(f"{test:<5}{namn:<34}{len(items):>3}{det:>10}{len(res):>12}{med:>10}{lo:>8}{hi:>8}")

out.append("")
out.append("SERIE A: tid till upptäckt (endast upptäckta körningar)")
out.append(f"{'Test':<5}{'n':>3}{'Median s':>10}{'Min s':>8}{'Max s':>8}")
for (serie, test, namn), items in groups.items():
    if serie != "A":
        continue
    det = [r for r in items if r["upptackt"] == "ja"]
    med, lo, hi = fmt(floats(det, "tid_till_upptackt_s"))
    out.append(f"{test:<5}{len(det):>3}{med:>10}{lo:>8}{hi:>8}")

out.append("")
out.append("SERIE B: samma ändring upprepad utan att Application återskapas")
out.append(f"{'Körning':<9}{'Upptäckt':>10}{'Tid till upptäckt s':>21}{'Återställd':>12}{'Tid till återställning s':>26}")
for r in rows:
    if r["serie"] != "B":
        continue
    out.append(f"{r['korning']:<9}{r['upptackt']:>10}{(r['tid_till_upptackt_s'] or '-'):>21}"
               f"{r['aterstalld']:>12}{(r['tid_till_aterstallning_s'] or '-'):>26}")

text = "\n".join(out)
print(text)
(src.parent / "sammanstallning.txt").write_text(text + "\n", encoding="utf-8")
print(f"\nSparat i {src.parent / 'sammanstallning.txt'}")
