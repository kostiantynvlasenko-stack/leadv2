---
name: clean-skill
description: Validate skill and agent config files for drift before commit, using deterministic checks only.
allowed-tools:
  - Read
  - Bash
---

# Clean Skill

Runs a single deterministic pass over each target file, with a hard cap of one
iteration per file — max 1 pass, no unbounded loops or repeated spawning.
Uses `Bash` to run checks and `Read` to inspect target files.
