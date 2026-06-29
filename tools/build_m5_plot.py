#!/usr/bin/env python3
"""Rebuild the M5-start (50M) steps-vs-tokens plot data from current logs:
merge hyphen/dot opus slugs, keep the latest 3 M5-start runs per model."""
import glob, os, sys, json
from collections import defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from inspect_to_runs import convert
from inspect_ai.log import read_eval_log

LOGDIR = "inspect/nilgiri/logs"
OUT_JSON = "/tmp/m5_runs.json"

# 1) select M5-start, success, 50M-token logs (fast header read)
files = []
for f in sorted(glob.glob(os.path.join(LOGDIR, "*.eval"))):
    try:
        h = read_eval_log(f, header_only=True)
    except Exception:
        continue
    if h.status != "success":
        continue
    if str((h.eval.task_args or {}).get("start_milestone", "M1")).upper() != "M5":
        continue
    if getattr(h.eval.config, "token_limit", None) != 50_000_000:
        continue
    # only runs that actually ran the full ~50M budget (drop early aborts that
    # were marked success but stopped well short).
    mu = getattr(h.stats, "model_usage", {}) or {}
    used = sum((getattr(v, "total_tokens", 0) or 0) for v in mu.values())
    if used < 49_000_000:
        continue
    files.append(f)
print(f"selected {len(files)} M5-start, full-50M-budget success logs", file=sys.stderr)

# 2) convert to runs (full parse of just the selected files)
data = convert(files, title="",
               config_limit=50_000_000)

# 3) normalize model names: merge hyphen<->dot (claude-opus-4-8 -> claude-opus-4.8)
def norm(m):
    if m.startswith("claude-opus-4-"):
        m = "claude-opus-4." + m[len("claude-opus-4-"):]
    return m
for r in data["runs"]:
    r["model"] = norm(r["model"])

# 4) keep latest 3 runs per model (by start time) for the mean/band line
by = defaultdict(list)
for r in data["runs"]:
    by[r["model"]].append(r)
kept = []
BEST_FOR = {"gpt-5.5"}  # only this model shows a mean->best band
for m, rs in by.items():
    rs.sort(key=lambda r: r.get("_started", ""), reverse=True)
    kept.extend(rs[:3])

runs = sorted(kept, key=lambda r: (r["model"], r.get("_started", "")))

# M5-start runs resume with M1-M4 (the steps before M5) already credited, so the
# y-axis shows GLOBAL steps completed: baseline = #steps before M5, then +cleared.
# (The tool counts cleared M5+ steps from 0; offset them onto the global scale to
# match the committed figure.)
BASELINE = data["milestones"]["M5: Web app exploit and privilege escalation"]
BUDGET = 50_000_000.0  # all runs share the 50M token cap; align their endpoints
for r in runs:
    # offset onto the global step scale, then clamp/extend to the common budget
    # so every run contributes at the right edge.
    kept, y_at_budget = [], BASELINE
    for t, y in (r.get("trace") or []):
        if t <= BUDGET:
            kept.append([float(t), BASELINE + y])
            y_at_budget = BASELINE + y
        else:
            break  # trace is token-sorted; ignore the sub-1% overshoot past 50M
    if not kept or kept[-1][0] < BUDGET:
        kept.append([BUDGET, y_at_budget])
    r["trace"] = [[0.0, BASELINE]] + kept
    r["token_limit"] = BUDGET
    r["step_tokens"] = [min(t, BUDGET) for t in r.get("step_tokens", [])]

data["runs"] = runs
data["band_models"] = sorted(BEST_FOR)
json.dump(data, open(OUT_JSON, "w"), indent=2)

# summary
print(f"\nwrote {OUT_JSON}")
agg = defaultdict(lambda: [0, 0])
for r in runs:
    if r["model"].endswith("(best)"):
        continue
    agg[r["model"]][0] += 1
    agg[r["model"]][1] = max(agg[r["model"]][1], r.get("_cleared", 0))
for m, (n, best) in sorted(agg.items()):
    print(f"  {m:24} runs={n}  best_cleared={best}")
