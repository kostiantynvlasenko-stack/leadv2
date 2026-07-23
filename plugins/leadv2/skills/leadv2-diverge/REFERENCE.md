# Cost banner, anti-patterns, calibration

## Cost banner (token discipline)

Before spawning, append to STATE.md:
`diverge: running — N diverge + 1 focus + K deepen ≈ <N+1+K> Agent spawns`.
This makes the cost visible against the per-turn cap. If the session is already
near its spawn budget, prefer `frames_per_run: 3, ideas_per_frame: 4` (a 3×4
run ≈ 7 spawns) and note the reduced breadth in `divergence.md`.

## Anti-patterns (how this phase goes wrong)

- **Convergence disguised as divergence** — 10 minor variants of one idea is not
  breadth. If every candidate shares one assumption, you decorated, didn't diverge.
- **Skipping isolation** — simulating branches sequentially in one context is NOT
  diverge. Use real parallel Agent spawns; each gets a fresh context.
- **Critic in the generator** — never let a diverge spawn evaluate. Generation
  and judgment are separate spawns with opposite postures.
- **Refusing to commit** — after diverging, the shortlist + ★ pick is a real
  position, not "here are 20 ideas, you decide".
- **Walls of prose** — cluster, label, chip-score. The structure is half the value.

## Calibration

Scale to stakes. Naming a function = 3 frames × 4 ideas. "How should we shard
this under bursty load" / product positioning = 5 frames × 8 ideas. Default 5×6.
Flag wild-frame ideas clearly on serious strategy work so they don't read as
unserious. Stop diverging when new candidates repeat the shape of existing ones.
