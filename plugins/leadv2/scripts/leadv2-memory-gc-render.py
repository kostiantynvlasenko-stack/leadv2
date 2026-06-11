
import os, json, sys
try: d = json.loads(os.environ["GC_OUTPUT_ESC"])
except Exception: d = {"stale_paths": [], "duplicates": [], "archive_candidates": [], "applied": False}
stale = d.get("stale_paths", [])
dupes = d.get("duplicates", [])
archive = d.get("archive_candidates", [])
applied = d.get("applied", False)
cs = os.environ["COUNT_STALE"]; cd = os.environ["COUNT_DUPES"]; ca = os.environ["COUNT_ARCH"]
ts = os.environ["REPORT_TS"]; note = os.environ["APPLY_NOTE"]
pr = os.environ["PR_LABEL"]; ma = os.environ["MA_LABEL"]
out = [
    "# Memory GC Report\n",
    "Generated: " + ts, "Mode: " + note, "Project root: " + pr, "Max age days: " + ma + "\n",
    "## Summary\n", "| Check | Count |", "|---|---|",
    "| Stale paths (report-only) | " + cs + " |",
    "| Duplicates " + ("(deduped)" if applied else "(report-only)") + " | " + cd + " |",
    "| Archive candidates (report-only) | " + ca + " |\n",
    "## Stale Paths\n",
    "Path-like tokens found in memory stores that do not exist under project root.",
    "Report-only — no auto-deletion.\n",
]
if stale:
    out += ["| Store | Token |", "|---|---|"]
    for r in stale: out.append("| " + r["store"] + " | `" + r["token"] + "` |")
else:
    out.append("_None found._")
out += ["\n## Duplicates\n",
    "Deduplication applied (newest kept; removed archived to memory-gc-archive.yaml)."
    if applied else "Report-only. Run with `--apply` to deduplicate (keeps newest entry).", ""]
if dupes:
    out += ["| Store | Field | Value (truncated) | Indices |", "|---|---|---|---|"]
    for r in dupes:
        val = str(r.get("value", ""))[:80]
        out.append("| " + r["store"] + " | " + r["field"] + " | `" + val + "` | " + str(r["indices"]) + " |")
else:
    out.append("_None found._")
out += ["\n## Archive Candidates\n",
    "Entries with hits/uses==0 (or absent) and timestamp older than " + ma + " days.",
    "Report-only — founder reviews and manually archives entries.\n"]
if archive:
    out += ["| Store | Entry ID | Hits | Timestamp |", "|---|---|---|---|"]
    for r in archive:
        out.append("| " + r["store"] + " | " + str(r["id"]) + " | " + str(r.get("hits", "(absent)")) + " | " + str(r["timestamp"]) + " |")
else:
    out.append("_None found._")
print("\n".join(out))
