#!/usr/bin/env python3
"""Compare report parses from ReportParseGoldenTests, value by value.

Reads <out>/<pdf>.<server|device>.<run>.json and, for each PDF, compares
every pair of runs: server vs server and device vs device (how much the
model varies on its own) and server vs device (the two paths). A path is
reading the same as the other when its cross-path differences are no larger
than the within-path ones.

Values are flattened to stable keys (lists of records keyed by name, region
or species, not by position). Free text (rawText, notes, recommendations)
is ignored; numbers match within 0.5% or 0.01.

  python3 scripts/compare-report-parses.py <dir>/out [--markdown report.md]

Prints counts and the keys that differ, never the values themselves: the
inputs are health data.
"""
import itertools
import json
import os
import re
import sys
from collections import defaultdict

IGNORE = {"rawText", "notes", "recommendations", "extractedAt", "confidence", "source", "diagnostics"}
RECORD_KEYS = ("name", "region", "metric", "category", "label")


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(s).lower()).strip()


def flatten(value, path="", out=None):
    out = {} if out is None else out
    if isinstance(value, dict):
        for k, v in value.items():
            if k in IGNORE:
                continue
            flatten(v, f"{path}.{k}" if path else k, out)
    elif isinstance(value, list):
        if value and all(isinstance(x, dict) for x in value):
            for i, item in enumerate(value):
                ident = next((item[k] for k in RECORD_KEYS if item.get(k) not in (None, "")), None)
                label = norm(ident) if ident is not None else f"#{i}"
                key = f"{path}[{label}]"
                # Same name twice (a repeated test): keep both apart.
                n = 2
                while any(o.startswith(key + ".") or o == key for o in out):
                    key = f"{path}[{label}~{n}]"
                    n += 1
                flatten(item, key, out)
        elif value:
            out[path] = sorted(json.dumps(x, sort_keys=True) for x in value)
    elif value is not None:
        out[path] = value
    return out


def same(a, b) -> bool:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return abs(a - b) <= max(0.01, 0.005 * max(abs(a), abs(b)))
    if isinstance(a, str) and isinstance(b, str):
        return norm(a) == norm(b)
    return a == b


def compare(a: dict, b: dict):
    keys_a, keys_b = set(a), set(b)
    both = keys_a & keys_b
    differ = sorted(k for k in both if not same(a[k], b[k]))
    return {
        "both": len(both),
        "equal": len(both) - len(differ),
        "differ": differ,
        "only_a": sorted(keys_a - keys_b),
        "only_b": sorted(keys_b - keys_a),
    }


def load(path):
    with open(path, encoding="utf-8") as f:
        body = json.load(f)
    if not body.get("success"):
        return None, body
    reports = body.get("reports") or []
    report = reports[0]["report"] if reports else {}
    return flatten(report), body


def main() -> None:
    out_dir = sys.argv[1]
    md_path = sys.argv[sys.argv.index("--markdown") + 1] if "--markdown" in sys.argv else None
    runs = defaultdict(dict)
    meta = {}
    for name in sorted(os.listdir(out_dir)):
        m = re.fullmatch(r"(.+)\.(server|device)\.(\d+)\.json", name)
        if not m:
            continue
        flat, body = load(os.path.join(out_dir, name))
        runs[m.group(1)][(m.group(2), int(m.group(3)))] = flat
        d = body.get("diagnostics") or {}
        meta[(m.group(1), m.group(2), int(m.group(3)))] = (
            body.get("success"), body.get("code"), d.get("aiServedBy"), d.get("aiMs"), d.get("aiError"))

    lines = []
    for pdf, by_run in runs.items():
        lines.append(f"### {pdf}")
        lines.append("")
        lines.append("| run | ok | served by | AI time | values | AI note |")
        lines.append("|---|---|---|---|---|---|")
        for (path, run), flat in sorted(by_run.items()):
            ok, code, served, ai_ms, err = meta[(pdf, path, run)]
            lines.append(f"| {path} {run} | {'yes' if ok else 'no (' + str(code) + ')'} | {served or '-'} | "
                         f"{round((ai_ms or 0) / 1000)} s | {len(flat) if flat else 0} | {err or '-'} |")
        lines.append("")
        lines.append("| pair | values in both | equal | differ | only in first | only in second |")
        lines.append("|---|---|---|---|---|---|")
        detail = []
        for (ka, a), (kb, b) in itertools.combinations(sorted(by_run.items()), 2):
            if a is None or b is None:
                continue
            c = compare(a, b)
            kind = "same path" if ka[0] == kb[0] else "**cross**"
            label = f"{ka[0]} {ka[1]} vs {kb[0]} {kb[1]} ({kind})"
            lines.append(f"| {label} | {c['both']} | {c['equal']} | {len(c['differ'])} | "
                         f"{len(c['only_a'])} | {len(c['only_b'])} |")
            if c["differ"] or c["only_a"] or c["only_b"]:
                detail.append(f"- {label}:")
                for title, keys in (("differ", c["differ"]), ("only in first", c["only_a"]),
                                    ("only in second", c["only_b"])):
                    if keys:
                        shown = ", ".join(f"`{k}`" for k in keys[:12])
                        more = f" (+{len(keys) - 12} more)" if len(keys) > 12 else ""
                        detail.append(f"  - {title}: {shown}{more}")
        lines.append("")
        lines.extend(detail)
        lines.append("")
    text = "\n".join(lines)
    print(text)
    if md_path:
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main()
