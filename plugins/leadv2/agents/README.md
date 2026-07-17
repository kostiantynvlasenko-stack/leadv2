# Shared Cross-Cutting Agents

Project-specific schema (DB tables, columns, invariants) lives in
`.claude/leadv2-overrides/extensions.md`.

The architect agent reads that file to understand DB structure and domain
conventions. Keep it up to date whenever schema changes are made.

Shared agents: critic, architect, security-auditor.
