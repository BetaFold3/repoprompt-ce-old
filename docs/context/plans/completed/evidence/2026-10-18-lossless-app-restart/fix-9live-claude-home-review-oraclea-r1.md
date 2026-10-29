# 9-live fix 4 (Claude history location): OracleA review, round 1

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 1) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md


## Verdict

**Request changes:** one remaining P1 in the new home-selection logic. The original symlink P1 and the unreadable-candidate/test P2s are addressed. No P0 identified.

Review is based on the supplied diff; validation results remain unverified claims.

### P1 — An unknown outer CLI still lets a nested Claude supply the home

**Evidence:** `AgentProcessRegistry.closestWriterHome` rejects an intermediate ancestor only when it is already classified `.writer`:

```swift
if next == root { return true }
if roles[next] == .writer { return false }
```

An `.unknown` ancestor is traversed. The new unknown-to-writer test explicitly establishes that the real native-installer CLI can initially be `.unknown` while its environment is unreadable.

**Failure scenario:**

```text
root shim: no home
└─ real CLI: .unknown, environment temporarily unreadable
   └─ bash: .unknown
      └─ nested Claude: .writer, readable marker, home B
```

The nested Claude inherits the runtime marker and qualifies as a writer. Its parent chain reaches the root without encountering a **classified** writer, so `closestWriterHome` returns B.

`recoveryClaudeHistoryRoots` trusts a nonempty recorded home and bypasses the locator’s uniqueness checks. Consequently, the nested account’s home can be selected instead of the conversation’s actual home. If B contains a copied history with the same session ID, baseline capture can target that copy; otherwise recovery can miss the actual history. A later cursor identity check does not establish that the initial baseline used the correct account.

The new nested-process test covers a fully classified outer CLI and a missing parent chain—not this partially classified chain.

**Smallest fix:** Treat an intermediate `.unknown` member as a barrier to home attribution, not proof that no outer writer exists. Return no home when ancestry is uncertain and allow the bounded locator to handle discovery. Keep nested processes classified as possible writers for safety.

**Regression test:** First refresh with the outer CLI’s environment unavailable and the nested CLI’s environment readable: assert no nested home is recorded. Then expose the outer CLI’s marker and home A: assert A is recorded. Retain the direct shim → CLI success test.

## Round-0 findings

| Finding | Assessment |
|---|---|
| Symlinked `projects` escapes search | **Fixed for static filesystem layouts.** `lstat` checks precede listing and reject symlinked `projects`, project directories, and files. Real-filesystem tests cover all three. |
| Unreadable candidate treated as absent | **Fixed.** Inspection failures propagate as `.uninspectable`; tests cover unreadable and unlistable candidates alongside a hit. |
| Unknown → writer transition untested | **Fixed.** A two-pass test now exercises the transition and home extraction. |
| Refresh-independent baseline test | **Fixed.** Home availability now depends on the refresh seam. The registry test separately pins production refresh invocation and its per-runtime limit. |
| Nested Claude supplies home | **Partially fixed.** Fully classified ancestry works; uncertain ancestry remains unsafe as described above. |

## Other checks

- **Ordinary sends:** Both `.ambiguous` and `.uninspectable` map to `recordUnsupported`, not `.refused`. Added tests explicitly assert `admitsWrite`.
- **Normal shim → CLI:** The direct child reaches `next == root` and supplies its home; the positive registry test pins this.
- **Once-per-runtime refresh:** An early unsuccessful pass deliberately consumes the retry. The fallback still runs. Without the surrounding discovery lifecycle, I cannot establish a new P1, but late child appearance remains a live-validation requirement.
- **Release isolation:** New test seams and the XCTest candidate suppression are inside `#if DEBUG`; no release leakage is shown.
- **Main-thread work:** `@concurrent` explicitly moves locator execution off the caller’s actor. No new definite main-thread blocking issue is established.
- **Deviations:** Unsupported baseline ambiguity and unknown-to-writer promotion remain justified. Neither should block ordinary sends. The accepted file-identity dedupe and reconcile-test omissions introduce no demonstrated new P1 here.

**P3:** Update the report’s earlier sections: they still describe dictionary-order home selection, the old filesystem implementation, and a refresh on every send, despite the appended corrections.

## Recommendations

1. **Block approval on uncertain-ancestry home attribution:** reject unknown intermediate ancestors and add the two-pass nested-CLI regression test.
2. Keep the symlink, uninspectable, send-admission, and refresh fixes.
3. Validate late CLI discovery and send latency live; reconcile the report’s stale descriptions.