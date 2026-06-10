#!/usr/bin/env python3
"""
leadv2-crossrepo-aggregate.py — Cross-repo immune-pattern analysis core.

Accepts per-repo pattern data via --payload-json (JSON array from shell driver).
Uses KEYWORD_STEMS stem-intersection (not exact sha1) for cross-repo deduplication.
Within-repo sha1 stable-ID preserved unchanged.

Emits shadow proposals to docs/leadv2/shadow/proposals/<sha1>.yaml:
  kind: cross-repo-pattern
  status: proposed
  risk_level: high   (always high — founder-gated by shadow-apply D7)
  repos: [list of source repo names]

NEVER writes outside shadow/proposals/ directory.
NEVER writes plugin source files.

DECISIONS: D7 D13 D16 D20 D21

Usage:
  python3 leadv2-crossrepo-aggregate.py
      --plugin-root <path>
      --proposals-dir <path>
      --payload-json '<json>'
      [--dry-run]
      [--similarity-threshold 0.6]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

# ---------------------------------------------------------------------------
# Re-use KEYWORD_STEMS from leadv2-immune-aggregate.py (D16)
# ---------------------------------------------------------------------------
KEYWORD_STEMS: dict[str, list[str]] = {
    "UTC": ["utc", "timezone", "tz", "timestamptz"],
    "freshness": ["fresh", "stale", "staleness", "is_fresh"],
    ".env": [r"\.env", "env.file", "env var", "environmentfile"],
    "partial-index": ["partial.index", "partial unique", "where predicate"],
    "upsert": ["upsert", "on conflict", "pgrst102"],
    "FK": [r"\bfk\b", "foreign key"],
    "RLS": [r"\brls\b", "row level security", "policy"],
    "race": [r"\brace\b", "race condition", "concurrent"],
    "retry": ["retry", "backoff", "max_retries", "max.retries"],
    "timeout": ["timeout", "wait_for"],
    "deploy": ["deploy", "deploy-latest", "both vps"],
    "control-sync": ["control.sync", "control_sync"],
    "bash-syntax": ["apostrophe", "single.quot", "bash.n", "syntax error", "set -e", "pipefail"],
    "schema": ["migration", "schema", "create table", "alter table", "column"],
    "locale": ["locale", "timezone", "tz", "day_utc"],
    "world-context": ["world.context", "freshness", "wc_is_fresh"],
    "source-inject": ["source ", r"source.*\.sh"],
    "grep-only": ["grep", "repo grep"],
}

SIMILARITY_THRESHOLD_DEFAULT = 0.6


def _tag(text: str) -> frozenset[str]:
    """Return frozenset of KEYWORD_STEMS keys matching text."""
    low = text.lower()
    tags: list[str] = []
    for kw, patterns in KEYWORD_STEMS.items():
        for p in patterns:
            if re.search(p, low):
                tags.append(kw)
                break
    return frozenset(tags)


def _stem_similarity(tags_a: frozenset[str], tags_b: frozenset[str]) -> float:
    """Jaccard similarity on keyword stem sets (D16)."""
    if not tags_a and not tags_b:
        return 0.0
    intersection = len(tags_a & tags_b)
    union = len(tags_a | tags_b)
    return intersection / union if union > 0 else 0.0


def _proposal_id(normalized_key: str) -> str:
    """sha1 of normalised cross-repo pattern key — stable proposal ID."""
    return hashlib.sha1(normalized_key.encode()).hexdigest()


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Pattern representation
# ---------------------------------------------------------------------------
class Pattern:
    __slots__ = ("repo", "pid", "summary", "action", "keywords", "seen_count", "source")

    def __init__(
        self,
        repo: str,
        pid: str,
        summary: str,
        action: str,
        keywords: list[str],
        seen_count: int,
        source: str,
    ) -> None:
        self.repo = repo
        self.pid = pid
        self.summary = summary
        self.action = action
        self.keywords: frozenset[str] = frozenset(keywords) if keywords else _tag(summary)
        self.seen_count = seen_count
        self.source = source


def load_patterns(payload: list[dict[str, Any]]) -> list[Pattern]:
    patterns: list[Pattern] = []
    for repo_entry in payload:
        repo_name: str = repo_entry.get("repo_name", "unknown")
        for p in repo_entry.get("patterns", []):
            summary = str(p.get("summary", ""))
            if not summary:
                continue
            kws = p.get("keywords") or []
            # Compute tags from summary if not populated (reflect_signature source)
            effective_kws = list(kws) if kws else list(_tag(summary))
            patterns.append(
                Pattern(
                    repo=repo_name,
                    pid=str(p.get("id", "")),
                    summary=summary,
                    action=str(p.get("action", summary)),
                    keywords=effective_kws,
                    seen_count=int(p.get("seen_count", 1)),
                    source=str(p.get("source", "unknown")),
                )
            )
    return patterns


# ---------------------------------------------------------------------------
# Cross-repo pattern detection (D16)
# ---------------------------------------------------------------------------
def detect_cross_repo_patterns(
    patterns: list[Pattern],
    threshold: float,
) -> list[dict[str, Any]]:
    """
    Return list of cross-repo pattern groups where the same conceptual pattern
    appears in >= 2 distinct repos (stem Jaccard similarity >= threshold).

    Algorithm:
    1. For each pair of patterns from different repos, compute stem similarity.
    2. If similarity >= threshold, union-find-style group them.
    3. Filter groups spanning >= 2 distinct repos.
    """
    n = len(patterns)
    # Union-Find
    parent = list(range(n))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x: int, y: int) -> None:
        px, py = find(x), find(y)
        if px != py:
            parent[px] = py

    for i in range(n):
        for j in range(i + 1, n):
            if patterns[i].repo == patterns[j].repo:
                continue  # cross-repo only
            if not patterns[i].keywords or not patterns[j].keywords:
                continue  # no tags → cannot match
            sim = _stem_similarity(patterns[i].keywords, patterns[j].keywords)
            if sim >= threshold:
                union(i, j)

    # Collect groups
    groups: dict[int, list[int]] = {}
    for i in range(n):
        root = find(i)
        groups.setdefault(root, []).append(i)

    results: list[dict[str, Any]] = []
    for idxs in groups.values():
        if len(idxs) < 2:
            continue
        repos_in_group = {patterns[i].repo for i in idxs}
        if len(repos_in_group) < 2:
            continue  # all from same repo

        members = [patterns[i] for i in idxs]
        # Canonical summary: most seen_count, then longest
        rep = max(members, key=lambda p: (p.seen_count, len(p.summary)))
        all_keywords = frozenset().union(*(m.keywords for m in members))

        # Stable proposal ID: sha1 of sorted stems (D16 — stem-based, not sha1 of text)
        stem_key = _normalize(" ".join(sorted(all_keywords)))
        proposal_sha = _proposal_id(stem_key)

        # Build diff_patch representing immune pattern addition
        diff_patch = (
            "--- a/docs/leadv2/immune-patterns.yaml\n"
            "+++ b/docs/leadv2/immune-patterns.yaml\n"
            "@@ -0,0 +1,7 @@\n"
            f"+- id: {proposal_sha[:12]}\n"
            f"+  summary: {rep.summary[:100]}\n"
            f"+  action: {rep.action[:200]}\n"
            f"+  keywords: [{', '.join(sorted(all_keywords))}]\n"
            f"+  seen_count: {sum(m.seen_count for m in members)}\n"
            f"+  cross_repo: true\n"
            f"+  source_repos: [{', '.join(sorted(repos_in_group))}]\n"
        )

        results.append(
            {
                "proposal_sha": proposal_sha,
                "stem_key": stem_key,
                "repos": sorted(repos_in_group),
                "keywords": sorted(all_keywords),
                "representative_summary": rep.summary,
                "representative_action": rep.action,
                "members_count": len(members),
                "diff_patch": diff_patch,
            }
        )

    return results


# ---------------------------------------------------------------------------
# Proposal emission
# ---------------------------------------------------------------------------
def build_proposal(group: dict[str, Any]) -> dict[str, Any]:
    """Build a shadow proposal dict conforming to cross-repo-pattern kind (D21)."""
    sha = group["proposal_sha"]
    repos_str = " + ".join(group["repos"])
    keywords_str = ", ".join(group["keywords"][:5])  # top 5 for title readability

    return {
        "id": sha,
        # cross-repo proposals use 'cross-repo-reflect' as task_id (manual-only D20)
        "task_id": "cross-repo-reflect",
        "kind": "cross-repo-pattern",
        "risk_level": "high",
        # target_file points to immune-patterns.yaml (the aggregated output file)
        "target_file": "docs/leadv2/immune-patterns.yaml",
        # before_snapshot written by shadow-apply.sh at promote time
        "before_snapshot": f"docs/leadv2/shadow/snapshots/{sha}.bak",
        "diff_patch": group["diff_patch"],
        # arm determined by hash(task_id)%2 — cross-repo-reflect always → A
        "arm": "A",
        "status": "founder_gated",
        "proposed_at": _now_iso(),
        "min_n_per_arm": 1,
        # Extended fields (not in base schema but preserved for cross-repo routing)
        "title": f"[cross-repo] {keywords_str} pattern seen in {repos_str}",
        "repos": group["repos"],
        "keywords": group["keywords"],
        "representative_summary": group["representative_summary"],
        "members_count": group["members_count"],
    }


def emit_proposal(
    proposal: dict[str, Any],
    proposals_dir: Path,
    plugin_root: Path,
    dry_run: bool,
) -> None:
    """Write proposal YAML idempotently. Refuse writes outside proposals_dir."""
    sha = proposal["id"]
    out_path = proposals_dir / f"{sha}.yaml"

    # Safety assertion: target must be inside proposals_dir (D7 / R5)
    try:
        out_path.resolve().relative_to(proposals_dir.resolve())
    except ValueError:
        print(
            f"[crossrepo-aggregate] SECURITY: proposal path {out_path} is outside "
            f"proposals_dir {proposals_dir} — refusing to write",
            file=sys.stderr,
        )
        sys.exit(1)

    # Extra safety: refuse if proposals_dir is inside plugin_root
    try:
        proposals_dir.resolve().relative_to(plugin_root.resolve())
        print(
            f"[crossrepo-aggregate] SECURITY: proposals_dir {proposals_dir} is inside "
            f"plugin_root {plugin_root} — refusing to write plugin files (D7)",
            file=sys.stderr,
        )
        sys.exit(1)
    except ValueError:
        pass  # Good — proposals_dir is outside plugin_root

    yaml_str = yaml.dump(proposal, allow_unicode=True, sort_keys=False, default_flow_style=False)

    if dry_run:
        print(f"# DRY-RUN: would write {out_path}")
        print(yaml_str)
        return

    if out_path.exists():
        print(
            f"[crossrepo-aggregate] idempotent skip: proposal {sha} already exists",
            file=sys.stderr,
        )
        return

    proposals_dir.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".yaml.tmp")
    tmp.write_text(yaml_str, encoding="utf-8")
    tmp.rename(out_path)
    print(f"[crossrepo-aggregate] emitted proposal {sha} → {out_path}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Cross-repo immune-pattern analysis core (leadv2 G3)"
    )
    parser.add_argument(
        "--plugin-root",
        required=True,
        help="Plugin root directory (for safety assertion — proposals must be outside it)",
    )
    parser.add_argument(
        "--proposals-dir",
        required=True,
        help="Absolute path to docs/leadv2/shadow/proposals/",
    )
    parser.add_argument(
        "--payload-json",
        required=True,
        help="JSON array of {repo_name, repo_path, patterns[]} from shell driver",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Print proposal YAML to stdout; do not write to disk",
    )
    parser.add_argument(
        "--similarity-threshold",
        type=float,
        default=SIMILARITY_THRESHOLD_DEFAULT,
        help=f"Jaccard similarity threshold for cross-repo dedup (default: {SIMILARITY_THRESHOLD_DEFAULT})",
    )
    args = parser.parse_args()

    plugin_root = Path(args.plugin_root).resolve()
    proposals_dir = Path(args.proposals_dir).resolve()

    try:
        payload: list[dict[str, Any]] = json.loads(args.payload_json)
    except json.JSONDecodeError as exc:
        print(f"[crossrepo-aggregate] ERROR: invalid --payload-json: {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(payload, list):
        print("[crossrepo-aggregate] ERROR: --payload-json must be a JSON array", file=sys.stderr)
        sys.exit(1)

    patterns = load_patterns(payload)
    if not patterns:
        print("[crossrepo-aggregate] No patterns loaded — nothing to analyse", file=sys.stderr)
        sys.exit(0)

    cross_repo_groups = detect_cross_repo_patterns(patterns, args.similarity_threshold)

    if not cross_repo_groups:
        print(
            f"[crossrepo-aggregate] No cross-repo patterns detected "
            f"(threshold={args.similarity_threshold})",
            file=sys.stderr,
        )
        sys.exit(0)

    print(
        f"[crossrepo-aggregate] Detected {len(cross_repo_groups)} cross-repo pattern(s)",
        file=sys.stderr,
    )

    for group in cross_repo_groups:
        proposal = build_proposal(group)
        emit_proposal(proposal, proposals_dir, plugin_root, args.dry_run)


if __name__ == "__main__":
    main()
