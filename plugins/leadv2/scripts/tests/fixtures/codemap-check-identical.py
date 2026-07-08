import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    a = json.load(f)["result"]
with open(sys.argv[2], encoding="utf-8") as f:
    b = json.load(f)["result"]
sys.exit(0 if a == b else 1)
