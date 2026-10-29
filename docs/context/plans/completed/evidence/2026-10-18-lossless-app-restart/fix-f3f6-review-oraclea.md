# Step 7-F3F6 — OracleA initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F3F6 (recovery banner header and quit-failure dialog wording) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F3/F6, local fix-f3f6-review.diff, worker report); preset identity verified from the result.

# Oracle Review

The changes address F3 by separating local and elsewhere counts without changing banner visibility, and F6 by replacing raw failures with shared presentation text. Cocoa/POSIX classification uses typed codes rather than string parsing; the shown changes preserve failure branches, admission outcomes, and quit blocking. Tests cover the requested count cases and principal storage-error wording. No P0/P1 finding is established by the supplied diff; validation results remain worker-reported.

## P2 — Consider

### F3F6-01 — Permission guidance is inaccurate for some classified errors

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryFailureWording.swift:35–46,60–63`.

- **Failure scenario:** A read-only volume (`EROFS` or `NSFileWriteVolumeReadOnlyError`) produces advice to change folder permissions. A read-permission failure produces a claim that the app cannot *write*.
- **Impact:** The message avoids raw errors, but can direct the user toward an ineffective remedy or misdescribe the failed operation.
- **Smallest fix:** Keep the three existing categories, but make the permission clause operation-neutral and mention volume writability—for example: “RepoPrompt couldn't access its data folder for this operation; check the folder's permissions and whether the disk is writable.” Add wording assertions for read-denied and read-only errors.

### F3F6-02 — The final evidence document leaves context validation failing

**Evidence:** `docs/context/plans/evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md:96–98`.

- **Failure scenario:** After adding this report, `Scripts/check-agent-context` reports it as unreachable. The reported successful guardrails run predates the report.
- **Impact:** The final snapshot is not fully covered by the claimed passing validation, and its context check currently fails.
- **Smallest fix:** Have the owning agent link the report from the plan’s Step 7-F3F6 status line, then rerun the affected check. The worker’s instruction not to edit the spec explains—but does not resolve—the outstanding integration task.

## Recommendations

- Address the two small follow-ups; no blocking code defect is demonstrated here.
- Treat the logging audit as **partially verified**: the new diagnostics mark raw details private, but the supplied excerpts do not establish logging coverage for every removed interpolation or prove that error descriptions never contain user content.
- Before closing the step, verify that consumers outside the supplied excerpts do not depend on the changed message strings. A live permission-denied quit check would provide useful end-to-end confirmation, but its absence alone is not a finding.