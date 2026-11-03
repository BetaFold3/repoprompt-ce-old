# 9-live fix 4 (Claude history location): OracleA review, round 0

Scope: read when the task touches where recovery finds a Claude conversation's history, Claude process classification in the process registry, or the Claude dispatch baseline.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 0) of the Step 4 diff, copied from its export; the fixes are in fix-9live-claude-home-worker.md


## Verdict

**Request changes:** one P1 bounded-search violation. No P0 identified. Review is limited to the supplied diff; reported validation was not independently verified.

### P1 — A symlinked `projects` directory escapes the bounded search

**Evidence:** `ClaudeHistoryLocator.FileSystem.live.subdirectories` calls:

```swift
FileManager.default.contentsOfDirectory(at: directory, ...)
```

`locate` supplies `<home>/projects` without checking whether **that directory itself** is a symlink. Listing a symlinked directory follows its destination, regardless of how the returned children are filtered.

**Failure scenario:** A candidate contains:

```text
candidate-home/projects -> /some/other/account/projects
```

The locator enumerates the other account’s project directories and checks their conversation files. It can return `.unique(candidateHome)` even though the matching file resides outside that home. This violates the plan’s “no symlink walking” restriction. A downstream reader might reject the location, but the locator has already performed the out-of-scope filesystem access.

The intentional support for **home aliases** does not require accepting symlinks beneath the home.

**Smallest fix:** After resolving/deduplicating the candidate home, reject a symlinked `projects` directory before enumeration. Explicitly enforce the same policy for project entries and the target file rather than relying on undocumented assumptions about resource-value filtering.

**Test:** Add a temporary candidate whose `projects` is a symlink to an external fixture containing the exact UUID filename. Assert it produces no hit. Separately pin rejection of symlinked project directories.

### P2 — Unreadable candidates are silently treated as absent

**Evidence:** The filesystem abstraction defines `subdirectories == nil` as both “unreadable” and “absent,” and `locate` handles both with:

```swift
guard let projectDirectories = fileSystem.subdirectories(projects) else { continue }
```

**Failure scenario:** Candidate A is inaccessible; candidate B contains a copied conversation file. The locator reports B as unique without establishing that A lacks the same conversation. This does not prove the promised uniqueness across candidates.

This is a concrete lookup ambiguity, **not evidence that the downstream reconciliation guards can be bypassed**.

**Smallest fix:** Distinguish absent directories from failed inspection. Preserve an indeterminate/error outcome and refuse history association when a candidate could not be inspected. At baseline, record unsupported so the ordinary send remains allowed.

**Test:** Inject an unreadable candidate plus one readable hit; assert the result is not `.unique`.

### P2 — Tests omit two newly introduced transitions

The supplied tests establish initial native-installer classification and a second home lookup, but not:

- **Unknown → writer:** The positive registry test discovers the child with its qualifying path and marker already available. It does not first persist `.unknown`, then reveal the qualifying evidence and verify the upgrade and home extraction.
- **The actual refresh dependency:** `testBaselineRetriesTheRecordedHomeOnceThenCaptures` uses an override that deliberately skips registry refresh. Its second lookup succeeds independently of discovery. It would still pass if the production refresh call were removed.

**Smallest fix:** Add a two-pass registry test for the upgrade and an integration test—or an injectable refresh spy—that makes home availability depend on exactly one refresh. A reconcile-path ambiguity test would also cheaply pin the separate error mapping, which is currently untested.

## Deviations and other checks

- **Ambiguous baseline recorded as unsupported: correct.** It refuses recovery evidence, not the user’s ordinary send. The new ambiguity test explicitly checks `admission.admitsWrite`.
- **Unknown → writer upgrade: justified.** Previously unavailable executable/environment evidence can become readable. The native-installer rule requires a Claude family and the record’s own runtime marker. The supplied negative tests cover a Codex family and a markerless descendant.
- **Release hooks:** All new override declarations and uses shown are guarded by `#if DEBUG`.
- **Main-thread blocking:** No definite regression established from the supplied material. The filesystem work uses a `nonisolated async` wrapper; its executor behavior should be verified against the project’s Swift concurrency settings, which are not included.
- **Root stability:** Sharing the resolver gives baseline and reconciliation the same *selection logic*, not necessarily the same root over time. The report should retain that distinction; the existing cursor file-identity check remains important.

## Recommendations

1. **Fix symlinked-`projects` traversal before approval**, with a real-filesystem regression test.
2. Distinguish failed inspection from absence before claiming a unique fallback home.
3. Add unknown-to-writer and refresh-dependent tests; preferably cover reconciliation ambiguity too.
4. Keep both deviations: unsupported baseline ambiguity and unknown-to-writer promotion. Neither warrants blocking ordinary sends.