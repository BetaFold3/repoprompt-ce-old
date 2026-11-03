# Step 5a initial review — OracleA

Scope: read when the task touches lossless-restart ordinary edit-review preservation or its initial findings.
Authority: Reference
Last-verified: 2026-10-23

Snapshot 2026-10-23/1445, staged20 files/+1957/-25, tree c1d037631854b7d4bd6ef9d2cd5ac64378e4b543. Both independent fresh lanes sent together with the same controlled source/patch, acceptance, verified validation and verbatim policy; no cross-lane findings. Returned explicit preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C / OracleA matched. Main read the complete result. Raw body below preserves all content with trailing-whitespace normalization only; original export remains local.

# Oracle Review

The changes add durable preservation of ordinary reviewed `apply_edits` proposals, record `applicationStarted` before accepted writes, preserve unresolved proposals as history, and expose View/Copy/Discard without replay. The persistence and failure-reporting paths are generally well scoped, but owner capture and durable target identity need attention. This assessment is based on the supplied snapshot; the reported fixture results are not live MCP qualification.

## P1 — Should fix

### F1 — Freeze ownership before the new ticket await
**Evidence:** `MCPApplyEditsToolProvider.swift:195–200`; `AgentModeViewModel+EditProposalRecovery.swift:107–128`.

The provider awaits `beginReview` before capturing the session’s ownership facts. If the tab is rebound or its conversation is reset during that suspension, admission captures the **replacement** session/lane/generation. Subsequent checks then validate that replacement rather than detect the change. A missing session also returns `nil`, selecting the unchecked legacy path.

This leaves a gap before the otherwise thorough ownership checks: an old request can acquire a new owner, or lose its recovery requirement.

**Smallest fix:** Capture the existing owner/binding/lane identity and whether recovery is required **before** awaiting `beginReview`; require that captured identity when committing the proposal. Only a session established as untracked at capture time should take the legacy path. Add a test holding this initial ticket await while resetting or replacing the owner.

### F2 — Persist the resolved target, not merely the translated input path
**Evidence:** `MCPApplyEditsToolProvider.swift:111, 202`; `WorkspaceFileEditHost.swift:31–47`; `AgentModeViewModel+EditProposalRecovery.swift:376–385`.

`physicalPath` receives `effectivePath`, which comes from `translateInputPath(request.path)`. Actual file resolution happens separately inside the host, including create-path resolution using the current selection. The supplied flow does not establish that the persisted value is the canonical physical target.

For relative or alias requests that remain unresolved at this point, historical inspection resolves the saved string again under `.visibleWorkspace`, rather than the original lookup scope. Changed roots or selection can therefore produce a comparison against another file—or a misleading missing-file result.

**Smallest fix:** Obtain and retain the canonical target through the same resolution policy used by the preview/write host, and persist that as `physicalPath`. Add a relative-path/multi-root fixture that changes selection before inspection and asserts the actual comparison result; the existing inspection test only checks that a message is returned.

## P2 — Consider

### F3 — Validate generation before accepting an idempotent start
**Evidence:** `AgentRecoveryStore+EditProposals.swift:94–101`.

The `.applicationStarted` branch returns `.unchanged` before checking the proposal’s reset generation. Consequently, a newer binding can successfully “start” an already-started proposal from an older conversation, contrary to the method’s documented contract. The current VM checks reduce practical exposure, but the store boundary itself accepts this invalid transition.

**Smallest fix:** Move the generation guard before the already-started return. Test an old-generation started proposal against a newer binding.

## Recommendations

- Fix F1 and establish canonical target identity for F2 before approving this step.
- Include the inexpensive F3 guard reorder.
- Rerun affected tests with the added boundary cases. Keep live MCP, lifecycle, and release qualification explicitly outstanding rather than inferring it from fixture or source-order checks.
