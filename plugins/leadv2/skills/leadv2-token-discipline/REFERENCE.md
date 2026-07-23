# REFERENCE: Why token discipline exists

## The diagnosis (verified Apr 2026 from 30 recent sessions)

Founder uses Opus as lead and hits 1M daily cap fast. Switching lead to Sonnet causes poor orchestration. Solution: **keep Opus, fix the conversation length**.

What was eating tokens in real sessions:
- 28/30 recent sessions had **>100 turns**, 26/30 had **>200 turns**, worst = 2257 turns
- Each turn re-sends the growing conversation prefix; turn 1000 input ≈ 550K tokens
- **Foreground Agent spawns** dropped full subagent transcripts (30-100KB each) into chat
- Same files re-read 4-11x per session without offset/limit
- Bash output 5-11KB blobs without `head/tail` at source
- Zero `/compact` events — sessions just kept growing

This is **operational discipline**, not model switching.

---

## Trade-off table: model routing per task class

| Task class | Lead model default | Plan triad | Build subagent | Review |
|---|---|---|---|---|
| Trivial | sonnet | skip | sonnet (1) | skip |
| Light | sonnet | architect-sonnet only | sonnet (1) | reviewer-sonnet |
| Standard | sonnet | architect-opus + critic-opus | sonnet (per group) | critic-opus + reviewer-sonnet |
| Complex | sonnet (or opus if T1/T2/T6/T9) | architect-opus + critic-opus | sonnet | critic-opus + reviewer-sonnet + sec-auditor |

**Total Opus calls per Standard task ≈ 2-3 (Plan + Review). NOT every phase. NOT lead.**

Note: Lead default is Sonnet across all classes (Opus is only reserved for architect/critic/reviewer roles in Plan and Review phases). The exception "opus if T1/T2/T6/T9" for Complex refers to explicit founder requests; otherwise respect the table.
