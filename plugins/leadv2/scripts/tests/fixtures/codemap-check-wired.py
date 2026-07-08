import json, sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
inp = d["inputCodeMap"]
arch_prompt = d["prompts"].get("architect", "")
synth_prompt = d["prompts"].get("synthesize", "")
# architect prompt embeds CODE_MAP raw (template literal); synthesize prompt embeds it via
# JSON.stringify(CODE_MAP) — compare against Python's equivalent JSON escaping for that leg.
arch_ok = inp in arch_prompt
synth_ok = json.dumps(inp) in synth_prompt
# [fix-round-1 #4] both prompts must fence the MCP-derived text as untrusted DATA, not splice
# it in bare — assert the explicit start/end markers + an "untrusted"/"information only" cue.
fence_ok = (
    "<<<CODE_MAP_DATA_START>>>" in arch_prompt and "<<<CODE_MAP_DATA_END>>>" in arch_prompt
    and "UNTRUSTED" in arch_prompt.upper() and "instructions" in arch_prompt
    and "<<<CODE_MAP_DATA_START>>>" in synth_prompt and "<<<CODE_MAP_DATA_END>>>" in synth_prompt
    and "UNTRUSTED" in synth_prompt.upper() and "instructions" in synth_prompt
)
ctx = d.get("ctx") or ""
# context.yaml is re-serialized by leadv2-plan.js's TASK-CLASS-PERSIST block (yaml.safe_dump),
# which may fold the block scalar into a different style — parse as YAML and check content,
# not a literal "code_map: |" formatting marker.
try:
    ctx_doc = yaml.safe_load(ctx) or {}
except Exception:
    ctx_doc = {}
ctx_ok = isinstance(ctx_doc.get("code_map"), str) and inp.strip() in ctx_doc["code_map"]
included_ok = d["result"].get("code_map_included") is True
if not (arch_ok and synth_ok and fence_ok and ctx_ok and included_ok):
    print(f"arch={arch_ok} synth={synth_ok} fence={fence_ok} ctx={ctx_ok} inc={included_ok}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
