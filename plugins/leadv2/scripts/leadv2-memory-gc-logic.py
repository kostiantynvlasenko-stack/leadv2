
import os, sys, re, yaml, json, datetime
from pathlib import Path

project_root  = Path(os.environ["PROJECT_ROOT"])
immune_path   = Path(os.environ["IMMUNE_FILE"])
nm_path       = Path(os.environ["NM_FILE"])
priors_path   = Path(os.environ["PRIORS_FILE"])
patterns_path = Path(os.environ["PATTERNS_MD"])
archive_path  = Path(os.environ["ARCHIVE_FILE"])
apply         = os.environ["APPLY"] == "1"
max_age_days  = int(os.environ["MAX_AGE_DAYS"])
now    = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=max_age_days)

PATH_RE = re.compile(r'(?:^|[\s"\'])([^\s"\']+/[^\s"\']*\.[a-zA-Z0-9]{1,10})(?:[\s"\']|$)')

def xt(t): return [m.group(1).strip("\"'") for m in PATH_RE.finditer(t)]
def ly(p):
    if not p.exists(): return None
    try: return yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except Exception as e: print(f"[gc] WARN: {p}: {e}", file=sys.stderr); return {}
def pts(v):
    if v is None: return None
    if isinstance(v, datetime.datetime): return v if v.tzinfo else v.replace(tzinfo=datetime.timezone.utc)
    if isinstance(v, datetime.date): return datetime.datetime(v.year, v.month, v.day, tzinfo=datetime.timezone.utc)
    s = str(v).strip()
    for f in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try: return datetime.datetime.strptime(s, f).replace(tzinfo=datetime.timezone.utc)
        except ValueError: continue
    return None

stale, seen_s = [], set()
def rs(tok, lbl):
    k = (lbl, tok)
    if k not in seen_s: seen_s.add(k); stale.append({"store": lbl, "token": tok})
def csy(data, lbl):
    def w(o):
        if isinstance(o, str):
            for t in xt(o):
                if not (project_root / t).exists(): rs(t, lbl)
        elif isinstance(o, dict): [w(v) for v in o.values()]
        elif isinstance(o, list): [w(v) for v in o]
    w(data)

for p, l in [(immune_path, "immune-patterns.yaml"), (nm_path, "leadv2-negative-memory.yaml"), (priors_path, "leadv2-priors.yaml")]:
    d = ly(p)
    if d is not None: csy(d, l)
if patterns_path.exists():
    try:
        for t in xt(patterns_path.read_text(encoding="utf-8")):
            if not (project_root / t).exists(): rs(t, "lead-patterns.md")
    except Exception as e: print(f"[gc] WARN: {e}", file=sys.stderr)

dupes = []
def do_arc(rem, src):
    if not rem: return
    a = ly(archive_path) or {"archived": []}
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    for r in rem:
        r = dict(r); r["archived_at"] = at; r["archived_from"] = src
        a.setdefault("archived", []).append(r)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    archive_path.write_text(yaml.dump(a, default_flow_style=False, allow_unicode=True), encoding="utf-8")

imd = ly(immune_path); imd2 = None
if imd:
    el = imd.get("patterns") or imd.get("entries") or []
    if isinstance(el, list):
        sm = {}
        for i, e in enumerate(el):
            if not isinstance(e, dict): continue
            sg = e.get("pattern") or e.get("regex") or ""
            if sg:
                if sg in sm: dupes.append({"store": "immune-patterns.yaml", "field": "pattern/regex", "value": sg, "indices": [sm[sg], i]})
                else: sm[sg] = i
        if apply:
            keep, seen = set(), {}
            for i, e in enumerate(el):
                if not isinstance(e, dict): keep.add(i); continue
                sg = e.get("pattern") or e.get("regex") or ""
                if sg: seen[sg] = i
                else: keep.add(i)
            keep |= set(seen.values())
            do_arc([e for i, e in enumerate(el) if i not in keep], "immune-patterns.yaml")
            imd2 = [e for i, e in enumerate(el) if i in keep]

nmd = ly(nm_path); nmd2 = None
if nmd:
    el = nmd.get("entries") or []
    if isinstance(el, list):
        sm2 = {}
        for i, e in enumerate(el):
            if not isinstance(e, dict): continue
            sg = e.get("signature") or {}
            c = "{}|{}".format(e.get("failure_mode") or "", sg.get("approach") or sg.get("pattern") or "")
            if c and c != "|":
                if c in sm2: dupes.append({"store": "leadv2-negative-memory.yaml", "field": "failure_mode+pattern", "value": c[:120], "indices": [sm2[c], i]})
                else: sm2[c] = i
        if apply:
            keep, seen = set(), {}
            for i, e in enumerate(el):
                if not isinstance(e, dict): keep.add(i); continue
                sg = e.get("signature") or {}
                c = "{}|{}".format(e.get("failure_mode") or "", sg.get("approach") or sg.get("pattern") or "")
                if c and c != "|": seen[c] = i
                else: keep.add(i)
            keep |= set(seen.values())
            do_arc([e for i, e in enumerate(el) if i not in keep], "leadv2-negative-memory.yaml")
            nmd2 = [e for i, e in enumerate(el) if i in keep]

ac = []
def ca(data, lbl, k):
    if not data: return
    for i, e in enumerate(data.get(k) or []):
        if not isinstance(e, dict): continue
        h = e.get("hits") or e.get("uses") or e.get("use_count")
        if h is not None and not (isinstance(h, (int, float)) and h == 0): continue
        tv = e.get("created_at") or e.get("timestamp") or e.get("added_at") or e.get("updated_at")
        ts = pts(tv)
        if ts and ts < cutoff:
            ac.append({"store": lbl, "id": e.get("id") or e.get("nm_id") or "[idx={}]".format(i), "hits": h, "timestamp": str(tv)})

ca(imd, "immune-patterns.yaml", "patterns")
ca(nmd, "leadv2-negative-memory.yaml", "entries")
ca(ly(priors_path), "leadv2-priors.yaml", "priors")

if apply:
    if imd2 is not None and imd:
        ky = "patterns" if "patterns" in imd else "entries"
        imd[ky] = imd2; immune_path.write_text(yaml.dump(imd, default_flow_style=False, allow_unicode=True), encoding="utf-8")
    if nmd2 is not None and nmd:
        nmd["entries"] = nmd2; nm_path.write_text(yaml.dump(nmd, default_flow_style=False, allow_unicode=True), encoding="utf-8")

print(json.dumps({"stale_paths": stale, "duplicates": dupes, "archive_candidates": ac,
    "counts": {"stale": len(stale), "duplicates": len(dupes), "archive": len(ac)}, "applied": apply}))
