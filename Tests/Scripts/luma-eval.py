#!/usr/bin/env python3
"""Luma answer evaluation: send the app's exact chat requests, score the answers.

Reads the request files written by
LumaTemporalContextTests.test_write_luma_eval_requests (one JSON per question),
POSTs each to /api/ai/chat, and scores the answers with the regex checks in
luma-eval-checks.json. Writes results.json and report.md to --out.

Stdlib only. Run with `python3 -I` (see luma-eval.sh).

The Vercel protection bypass secret comes from AMACH_VERCEL_BYPASS in the
environment, or from Amach-Website/.env.local. It is only ever sent as a
request header; it is never printed or written to disk.
"""

import argparse
import calendar
import concurrent.futures
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
WEBSITE_ENV = REPO_ROOT.parent / "Amach-Website" / ".env.local"
TARGETS = {
    "prod": "https://www.amachhealth.com",
    "local": "http://localhost:3000",
}
PREVIEW = "https://amach-website-git-{slug}-daveo280s-projects.vercel.app"
TIMEOUT_S = 300


def bypass_secret():
    value = os.environ.get("AMACH_VERCEL_BYPASS")
    if value:
        return value.strip()
    if WEBSITE_ENV.is_file():
        for line in WEBSITE_ENV.read_text().splitlines():
            m = re.match(r"\s*(?:export\s+)?AMACH_VERCEL_BYPASS\s*=\s*(.*)$", line)
            if m:
                return m.group(1).strip().strip("'\"")
    return None


def preview_url(branch):
    slug = re.sub(r"[^a-z0-9]+", "-", branch.lower()).strip("-")
    return PREVIEW.format(slug=slug)


def website_branch():
    head = REPO_ROOT.parent / "Amach-Website" / ".git" / "HEAD"
    if head.is_file():
        ref = head.read_text().strip()
        if ref.startswith("ref: refs/heads/"):
            return ref[len("ref: refs/heads/"):]
    return None


# ── Checks ───────────────────────────────────────────────────────────────────

def months_since(iso, today):
    d = dt.date.fromisoformat(iso)
    months = (today.year - d.year) * 12 + today.month - d.month
    return months - 1 if today.day < d.day else months


def fill(pattern, today):
    def sub(m):
        kind, arg = m.group(1), m.group(2)
        if kind == "months_since":
            return str(months_since(arg, today))
        month = (today.month - 1 - int(arg)) % 12 + 1
        return calendar.month_name[month]
    return re.sub(r"\{(months_since|month_ago):([^}]+)\}", sub, pattern)


def load_checks(path, today):
    raw = json.loads(Path(path).read_text())
    glob = raw.get("_global", {})
    checks = {}
    for qid, c in raw.items():
        if qid.startswith("_"):
            continue
        checks[qid] = {
            "note": fill(c.get("note", ""), today),
            "must_contain": [fill(p, today) for p in c.get("must_contain", [])],
            "must_not_contain": [fill(p, today) for p in c.get("must_not_contain", [])],
        }
    return glob, checks


def snippet(text, m, pad=60):
    a, b = max(0, m.start() - pad), min(len(text), m.end() + pad)
    return ("…" if a else "") + text[a:b].replace("\n", " ") + ("…" if b < len(text) else "")


def score(result, check, glob):
    """Returns a list of failure strings (empty = pass) and a list of warnings."""
    failures, warnings = [], []
    if result["status"] != 200 or not result.get("content"):
        failures.append(f"HTTP {result['status']}: {result.get('error') or 'no content'}")
        return failures, warnings
    text = result["content"]
    for p in (check or {}).get("must_contain", []):
        if not re.search(p, text, re.I):
            failures.append(f"missing /{p}/")
    for p in (check or {}).get("must_not_contain", []):
        m = re.search(p, text, re.I)
        if m:
            failures.append(f"forbidden /{p}/ → “{snippet(text, m)}”")
    if result["seconds"] > glob.get("max_seconds", 60):
        warnings.append(f"slow: {result['seconds']:.0f}s")
    model = result.get("model") or ""
    if model in glob.get("fallback_models", []):
        warnings.append(f"fallback model {model}")
    elif glob.get("expected_model") and model and model != glob["expected_model"]:
        warnings.append(f"unexpected model {model}")
    return failures, warnings


# ── Requests ─────────────────────────────────────────────────────────────────

def send(base, req, secret):
    body = {k: req[k] for k in ("message", "context", "history", "options") if k in req}
    headers = {"Content-Type": "application/json", "User-Agent": "luma-eval"}
    if secret:
        headers["x-vercel-protection-bypass"] = secret
    http = urllib.request.Request(base.rstrip("/") + "/api/ai/chat", data=json.dumps(body).encode(),
                                  headers=headers, method="POST")
    out = {"id": req["id"], "mode": (req.get("options") or {}).get("mode"), "question": req["message"]}
    start = time.monotonic()
    try:
        with urllib.request.urlopen(http, timeout=TIMEOUT_S) as r:
            status, model, raw = r.status, r.headers.get("x-amach-model"), r.read()
    except urllib.error.HTTPError as e:
        status, model, raw = e.code, e.headers.get("x-amach-model"), e.read()
    except Exception as e:  # timeouts, DNS, resets
        status, model, raw = 0, None, json.dumps({"error": type(e).__name__ + ": " + str(e)}).encode()
    out["seconds"] = round(time.monotonic() - start, 1)
    out["status"] = status
    try:
        data = json.loads(raw)
    except ValueError:
        data = {"error": raw[:300].decode(errors="replace")}
    out["model"] = model or data.get("model")
    out["usage"] = data.get("usage")
    out["content"] = data.get("content")
    if data.get("error"):
        out["error"] = str(data["error"])[:300]
    return out


def run_once(base, requests, secret, workers, log):
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(send, base, r, secret): r["id"] for r in requests}
        for f in concurrent.futures.as_completed(futures):
            res = f.result()
            log(f"  {res['id']:<14} {res['status']:>3}  {res['seconds']:>6.1f}s  {res.get('model') or '-'}")
            results.append(res)
    order = {r["id"]: i for i, r in enumerate(requests)}
    return sorted(results, key=lambda r: order[r["id"]])


# ── Report ───────────────────────────────────────────────────────────────────

def report(runs, base, glob, checks, started):
    n = len(runs)
    ids = [r["id"] for r in runs[0]]
    lines = [f"# Luma eval — {started:%Y-%m-%d %H:%M}", "",
             f"Target: `{base}` · runs: {n} · questions: {len(ids)} · "
             f"slow > {glob.get('max_seconds', 60)}s · expected model `{glob.get('expected_model', '?')}`", "",
             "Regex checks are a first pass. Read every answer below and fill in the manual review.", "",
             "## Summary", "",
             "| question | pass | fails | slow | fallback | median s | models |",
             "|---|---|---|---|---|---|---|"]
    total_pass = total = 0
    for qid in ids:
        rows = [run[ids.index(qid)] for run in runs]
        passed = sum(1 for r in rows if not r["failures"])
        slow = sum(1 for r in rows if any(w.startswith("slow") for w in r["warnings"]))
        fb = sum(1 for r in rows if any(w.startswith("fallback") for w in r["warnings"]))
        secs = sorted(r["seconds"] for r in rows)
        models = ", ".join(sorted({r.get("model") or "-" for r in rows}))
        total_pass += passed
        total += n
        mark = "✅" if passed == n else ("⚠️" if passed else "❌")
        lines.append(f"| {qid} | {mark} {passed}/{n} | {n - passed} | {slow} | {fb} | {secs[len(secs) // 2]:.0f} | {models} |")
    lines += ["", f"**Total: {total_pass}/{total} answers passed the regex checks.**", "",
              "## Failures and warnings", ""]
    any_issue = False
    for i, run in enumerate(runs, 1):
        for r in run:
            for f in r["failures"]:
                lines.append(f"- run {i} · **{r['id']}** · {f}")
                any_issue = True
            for w in r["warnings"]:
                lines.append(f"- run {i} · {r['id']} · _{w}_")
                any_issue = True
    if not any_issue:
        lines.append("None.")
    lines += ["", "## Manual review", "",
              "For each answer: is it correct, in the right time frame, with the right units, and useful? "
              "Mark ok / slip / wrong and note why.", ""]
    for qid in ids:
        c = checks.get(qid, {})
        lines += [f"### {qid}", "", f"> {runs[0][ids.index(qid)]['question']}", ""]
        if c.get("note"):
            lines += [f"_Expect: {c['note']}_", ""]
        for i, run in enumerate(runs, 1):
            r = run[ids.index(qid)]
            verdict = "pass" if not r["failures"] else "FAIL"
            lines += [f"**Run {i}** — regex {verdict} · {r['seconds']:.0f}s · {r.get('model') or '-'}", "",
                      "<details><summary>Answer</summary>", "",
                      (r.get("content") or f"(no content: {r.get('error')})").strip(), "", "</details>", "",
                      "Manual: [ ] ok  [ ] slip  [ ] wrong — notes:", ""]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("requests", help="folder of request JSON files, or a results.json with --rescore")
    ap.add_argument("--rescore", action="store_true",
                    help="re-score saved answers in a results.json with the current checks (no requests sent)")
    ap.add_argument("--target", choices=["prod", "preview", "local"], default="prod")
    ap.add_argument("--branch", help="Website branch for --target preview (default: Amach-Website's checked-out branch)")
    ap.add_argument("--url", help="base URL; overrides --target")
    ap.add_argument("--checks", default=str(SCRIPT_DIR / "luma-eval-checks.json"))
    ap.add_argument("--out", help="output folder (default: Tests/Logs/luma-eval/<timestamp>)")
    ap.add_argument("--repeat", type=int, default=1, help="run every question N times")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--only", help="comma-separated question ids")
    args = ap.parse_args()

    if args.rescore:
        src = Path(args.requests)
        saved = json.loads(src.read_text())
        started = dt.datetime.fromisoformat(saved["started"])
        glob, checks = load_checks(args.checks, started.date())
        for run in saved["runs"]:
            for r in run:
                r["failures"], r["warnings"] = score(r, checks.get(r["id"]), glob)
        out = Path(args.out) if args.out else src.parent
        out.mkdir(parents=True, exist_ok=True)
        saved.update(checks=checks, rescored=dt.datetime.now().isoformat(timespec="seconds"))
        return finish(out, saved, report(saved["runs"], saved["target"], glob, checks, started))

    if args.url:
        base = args.url
    elif args.target == "preview":
        branch = args.branch or website_branch()
        if not branch:
            sys.exit("--target preview needs --branch (could not read Amach-Website's branch)")
        base = preview_url(branch)
    else:
        base = TARGETS[args.target]

    secret = bypass_secret()
    if not secret and "vercel.app" in base:
        sys.exit("AMACH_VERCEL_BYPASS is not set (env or Amach-Website/.env.local); previews will refuse requests")

    files = sorted(Path(args.requests).glob("*.json"))
    requests = [json.loads(f.read_text()) for f in files]
    if args.only:
        keep = set(args.only.split(","))
        requests = [r for r in requests if r["id"] in keep]
    if not requests:
        sys.exit(f"no request files in {args.requests}")

    started = dt.datetime.now()
    glob, checks = load_checks(args.checks, started.date())
    out = Path(args.out) if args.out else REPO_ROOT / "Tests" / "Logs" / "luma-eval" / f"{started:%Y%m%d-%H%M%S}"
    out.mkdir(parents=True, exist_ok=True)

    print(f"Luma eval → {base}  ({len(requests)} questions × {args.repeat}, {args.workers} parallel)")
    print(f"Bypass header: {'set' if secret else 'not set'}")
    runs = []
    for i in range(args.repeat):
        print(f"Run {i + 1}/{args.repeat}")
        run = run_once(base, requests, secret, args.workers, print)
        for r in run:
            r["failures"], r["warnings"] = score(r, checks.get(r["id"]), glob)
        runs.append(run)

    saved = {"target": base, "started": started.isoformat(timespec="seconds"), "checks": checks, "global": glob,
             "runs": runs}
    return finish(out, saved, report(runs, base, glob, checks, started))


def finish(out, saved, md):
    (out / "results.json").write_text(json.dumps(saved, indent=2, ensure_ascii=False) + "\n")
    (out / "report.md").write_text(md)
    print(md.split("## Manual review")[0].split("## Summary")[1].rstrip())
    print(f"\nReport:  {out / 'report.md'}\nResults: {out / 'results.json'}")
    failed = sum(1 for run in saved["runs"] for r in run if r["failures"])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
