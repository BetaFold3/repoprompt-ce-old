# Phase 3 initial OracleA review — incomplete response

Scope: read when the task touches Phase 3 process-registry review findings.
Authority: Reference
Last-verified: 2026-10-22

Frozen tree: `aaa821b7755edc7fb9520b7b52efc93328913c53`. Initial response ended mid-finding; incomplete. One same-preset retry is pending; no combined review conclusion is drawn from this artifact.

# Oracle Review

## Summary

This snapshot adds durable runtime records, an app-scoped registry, provider launch hooks, transport fences, discovery/watches, recovery projections, and scheduler restrictions. Production registration, fresh Claude session IDs, and recovered Stop remain disabled as intended. However, the fixture-enabled implementation still has ownership and discovery gaps that prevent accepting it as source-complete R6. The reported passing tests cover useful boundaries but miss several cases below.

References are relative to `Sources/RepoPromptAgentCore/` unless otherwise stated.

## Required — P1

### R6-01 — Incomplete ownership inspection can incorrectly prove family exit

**Evidence:** `AgentMode/Runtime/Recovery/AgentProcessRegistry.swift:324–326,359–377,454–463`; `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessInventory.swift:63–82`.

**Scenario / impact:** A previously unseen writer survives its launcher and is reparented. Its birth identity is readable, but its environment is unavailable. Inventory nevertheless reports completeness because only whole-inspection `.unavailable` results count as incomplete. Discovery cannot match its marker or parent, excludes it, and can mark the recorded family `exited`. Another writer can then be admitted.

**Smallest fix:** Do not claim family completeness when an inventory candidate cannot be ruled out because ownership evidence is unavailable. Also represent the inventory’s UID basis and relevant access limitations explicitly. Add a fixture with an unrecorded, reparented writer whose birth is readable but marker inspection fails.

### R6-02 — “Not a known writer basename” is not positive tool identification

**Evidence:** `AgentMode/Runtime/Recovery/AgentProcessRegistry.swift:384–398,423–430`.

**Scenario / impact:** Every newly discovered executable outside `writerExecutableBasenames` becomes `.tool` when environment inspection succeeds. That includes ambiguous interpreters, alternate launchers, and mixed samples across `exec`. The supplied inspection contract guarantees consistent **birth identity**, not a coherent executable/environment snapshot. After the root exits, such a process can incorrectly release conversation ownership.

The existing mixed-exec test checks previously recorded roles; it does not establish that a newly observed nonmatching executable is tool-only.

**Smallest fix:** Default unmatched or ambiguous observations to `.unknown`. Permit `.tool`
