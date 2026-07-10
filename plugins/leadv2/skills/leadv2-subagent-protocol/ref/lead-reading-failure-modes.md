# Lead reading-discipline — failure modes (extracted from leadv2-subagent-protocol §10)

Concrete token-burn examples that motivate the §10 hard rules. Referenced from `SKILL.md` as a
2-line pointer; kept here so the rules list stays scannable without dropping the examples.

- Reading 226-line architect-design.md fully into lead → ~30k tokens × every subsequent turn until compaction.
- 9 hours of `journalctl` output dumped raw → tens of KB stuck in lead history.
- Writing PO/architect mission files via Write inline → mission body lives in transcript forever.
