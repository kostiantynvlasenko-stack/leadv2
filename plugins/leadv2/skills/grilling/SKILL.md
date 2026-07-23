---
name: grilling
description: "Interview the user relentlessly about a plan, decision, or idea until you reach shared understanding — one question at a time, each with your recommended answer. Use when the user wants to stress-test their thinking, pin down requirements before building, or says 'grill me' / 'grill this' / 'interrogate the plan'."
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Interview the user relentlessly about every aspect of this until you reach a shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one. For each question, give your recommended answer.

Ask one question at a time, and wait for the answer before continuing — several questions at once is bewildering.

If a *fact* can be found by exploring the environment (filesystem, code, tools, logs), look it up rather than asking. The *decisions* are the user's — put each one to them and wait.

Do not act on the outcome until the user confirms you have reached shared understanding.

<!-- Adapted from mattpocock/skills (MIT) — the grilling loop. -->
