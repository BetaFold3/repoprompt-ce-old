# Step 4d7 — OracleA planning

Scope: read when the task touches prospective Claude agreement proof retention, safe refusal and remaining pre-live closure for lossless restart Step 4d7.
Authority: Reference
Last-verified: 2026-10-24

Independent fresh planning; exact preset identity verified and complete reply read by main. Response follows.

## Continuation after safety audit

# Oracle Plan

## Summary

**Yes—the minimal ownership-consumption contract is safe under MC1 and strengthened MC2.** A retained digest proves an original entry’s identity, not completion, current native-file validity, or permission to dispatch. Fresh recovery independently revalidates those entries before importing or continuing. Use the targeted change: consume ownership only after exact agreement; leave refusal and invalidation otherwise unchanged. My earlier agreed-key cache, refusal scopes, and sticky-classifier changes are unnecessary. This conclusion uses the supplied source and main’s reported checks; no additional validation was performed here.

## Current-state analysis

`AgentModeViewModel.swift:20365–20416` records newly inserted ledger keys under the producer. Refusal removes that producer’s entire remaining ownership set and clears its digests. Successful agreements currently consume nothing, causing later failures to revoke earlier completed evidence.

The recovery boundary supplies the necessary independent authority:

- `ClaudeSessionHistoryReader.decode`, lines 370–493, validates parsing, graph and prefix fences, then projects **all entries** and checks **all applicable ledger entries before frontier filtering**.
- `reconcileRecoveryHistory` supplies the interrupted attempt’s baseline, dispatch-window fences, saved target and record-cursor fence. It subsequently checks unchanged ownership/ledger and canonical backing, saves rows plus receipt, then advances the cursor.
- Claude observations remain completion-unconfirmed.
- Ordinary manual-send baseline admission deliberately differs: it passes `ledger: nil` and can proceed with unsupported qualification. This plan neither changes that behavior nor describes it as verified recovery.

Thus later unsupported output is not evidence that an earlier entry’s historical identity proof was false. Conversely, keeping that proof cannot make changed native history pass recovery.

## Design

### Exact agreement consumes revocation ownership

Keep all existing types and signatures, including:

- `resultAgreement(localItemID:text:)`
- `readAgreement(call:resultRow:answer:)`
- `refuseClaudeLiveTranscript(producer:session:)`

On successful agreement, subtract only the exchange’s exact ledger keys intersected with `claudeLiveTranscriptOwnedKeys[producer]`. Remove an empty producer-map entry. Do not change ledger rows, digests, canonical items, receipts, cursors or refusal state.

Perform validation and subtraction synchronously on the existing main-actor owner path, with no suspension between them. No save is necessary for this transient-only mutation. Duplicate agreement is idempotent; imported or other-producer rows confer no ownership.

For **single text**, replace the current nonnil-digest/suffix check at lines 20195–20208:

1. Reject an already-refused producer.
2. Find exactly one applicable Claude ledger item for the current conversation and agreement’s `localItemID`; reject missing or ambiguous association.
3. Reconstruct the expected `singleTextAssistantRow` using that item’s native session ID, native entry ID and agreement text.
4. Require exact equality of the projected ledger identity, row kind, ordinal, local ID and digest with the stored item. Require an unambiguous matching ledger key.
5. Require the exact, unique, complete canonical payload across persisted transcript plus suffix, reusing `holdsClaudeLiveTranscriptRow`/`holdsCanonicalPayload`.
6. Only then consume its owned key.

Reconstruction is comparison-only: never assign its digest to the ledger or insert a replacement proof. Failure follows existing refusal behavior.

For **Read**, retain the existing complete-chain checks at lines 20179–20192. Only after all three succeed, consume the owned intersection of call, result and answer keys. Never consume a partial chain.

**No typed `CompleteText` carrier is necessary:** deterministic projection plus exact ledger and canonical equality supplies the required binding without changing producer interfaces.

### Attribution and subsequent contradictions

Preserve the existing single-text result classification, including accepted noncontradictory nil attribution. Consumption establishes only exact historical row identity; it does not establish result attribution, dispatch association or completion. Requiring affirmative attribution would narrow an existing acceptance path without addressing a demonstrated retention failure. Keep Read’s stricter attribution unchanged.

Later refusal still latches permanently and invalidates every **remaining unagreed** owned key. It does not recover ownership of agreed keys.

For an old-key contradiction:

- **Native unchanged:** fresh reader and canonical comparison may validate and deduplicate the historical row. That is correct.
- **Native changed, missing, retracted or unsupported:** fresh recovery rejects through parsing/semantic checks, fences or whole-ledger comparison, including before the frontier.
- **Canonical changed:** canonical backing preflight rejects even if native validation passes.

Under MC1, there is no demonstrated case where retaining an agreed identity proof makes those checks pass incorrectly. Extra revocation state would implement a different policy, not repair a shown safety gap.

### Hydration and refusal copy

Do not add a controller-present guard or alter payload comparison. Main’s trace found no normal trigger: already-loaded loading returns, rebind checks ownership/activity, and Reload Latest requires quiescence plus consent.

If small within the existing harness, pin these real entry-point invariants. Keep forced `loaded=false` hydration conservative: summary-only canonical state must fail live agreement. This is a documented forced condition, not a new mandatory architecture blocker.

Change only the three action-scoped Claude changed/unproven/unsupported messages to explicitly include **“Nothing was imported or sent.”** Leave shared `recoveryHistoryText` and ordinary baseline messages unchanged.

### Acceptance tests

Use real owner-path fixtures plus reader negatives:

- Exact text/Read agreement preserves its prefix after later refusal; an unfinished later chain loses its digests.
- Failed, dropped or post-refusal agreement consumes nothing.
- Wrong nonnull digest, ambiguous association, duplicate canonical payload and streaming/incomplete canonical content fail.
- Imported/other-producer keys remain untouched; repeated agreement is harmless.
- Existing nil-attribution text acceptance consumes only after strengthened checks; contradictory attribution still refuses.
- Old-key contradiction with unchanged native history deduplicates; changed/missing/proofless/retracted history before the frontier blocks recovery.
- Save/reload retains agreed proofs without duplicate import; previously cleared proofs remain invalid.
- Each changed action message corresponds to zero dispatch calls.

## File-by-file impact

- **`AgentModeViewModel.swift`**: strengthen text agreement; consume exact ownership after successful text/Read agreement. No classifier or session-state additions.
- **`AgentModeViewModel+RecoveryActions.swift`**: modify only the three action-scoped refusal strings.
- **`Tests/RepoPromptTests/AgentMode/Recovery/`**: extend existing owner/reader suites with the acceptance cases. Exact suite filenames are not supplied; identify them before editing.
- **Existing lossless-restart plan/evidence files**: record this narrowed contract, validation provenance and pending live gates.

Reader, import preflight and stale-reset production files remain unchanged.

## Implementation order

1. Land strengthened text validation, ownership consumption and owner tests atomically.
2. Add reader/save-reload negatives and action-copy regressions; add small hydration invariant tests if available.
3. Main requests OracleA/B reviews on the same snapshot with the policy attached verbatim; follow required validation and local-commit rules.
4. Keep production qualification OFF and final live acceptance explicitly pending.

## Recommendations

Implement this minimal prospective fix; no new owner contract decision is needed. Cut extra caches, refusal scopes, classifier escalation and speculative hydration guards. Do not repair old proofs or weaken R7. Defer actual-profile capture to one isolated final qualification package: all supported family/provider discovery and marker gates, separate fresh-session-ID qualification, and actual MCP/permission/spawn/hook behavior remain pending. Safe refusal is valid safety closure—not completion of eligible one-click Resume.

## Initial guidance (superseded where noted)

# Oracle Plan

## Summary

Use a **targeted prospective change**, not history repair: distinguish permanent refusal of future live qualification from revocation of proofs for an unfinished exchange. Protect proofs only after exact terminal agreement, while retaining launch ownership so affirmative contradictions can still revoke them. Separately trace active-session hydration before changing it. Improve refusal text now; leave production qualification and final live verification explicitly pending.

This plan uses the supplied excerpts and reported HEAD `34bdb02a`; no repository inspection, tests, or reviews were performed.

## Current-state analysis

The relevant flow is:

1. `ClaudeLiveTranscriptProducerState` classifies raw stdout against translated results and the recorded outbound UUID.
2. It attaches deterministic reader projections to text/tool events; successful exchanges emit `resultAgreement` or `readAgreement`.
3. On the main actor, `AgentModeViewModel.applyClaudeLiveTranscriptEvidence` checks projection, conversation identity, canonical payload, prerequisites, and display eligibility.
4. `insertClaudeLiveTranscriptRow` updates the row, ledger, and transient producer ownership synchronously, then schedules the existing serialized save.
5. Every refusal currently calls `refuseClaudeLiveTranscript`, which removes **all** owned keys and clears their digests—even keys from earlier completed dispatches.
6. `ClaudeSessionHistoryReader.ledgerConflict` rejects absent entries, changed row-key sets, and digest differences, including a stored `nil` digest. Recovery converts that rejection into failure rather than dispatch.

The confirmed defect is therefore **launch-wide revocation for failures whose demonstrated scope is only subsequent output**. Existing agreement evidence, canonical projections, ownership tracking, and reader checks should be extended rather than duplicated.

Two constraints matter:

- `resultAgreement` currently checks only `session.items` and a nonnil digest, unlike the Read chain’s exact canonical check.
- Once disqualified, the producer short-circuits before checking semantic markers and session identity. Merely changing refusal scope would miss later affirmative contradictions.

Hydration’s actual replacement path is not supplied. Its causal reachability remains unproven; changing hydration state ownership now would be speculative.

## Design

### 1. Mandatory bounded inspection before editing

Obtain only:

- `AgentTabSession` declarations and reset/cleanup sites for `claudeLiveTranscriptOwnedKeys`, refused producers, transcript, and suffix items.
- The native-controller classification, suppression, malformed-line, launch-drain, and delivery paths.
- Complete reader ordering: prefix-fence validation, parsing, `ledgerConflict`, import boundary filtering, and candidate construction.
- Recovery commit/revalidation and hydration replacement entry points.

**Required safety finding:** reconciliation validates every ledger-known entry and applicable stored prefix before accepting an import or permitting continuation—not merely rows after the frontier. The supplied `ledgerConflict` body supports this, but its inputs and invocation ordering are missing.

If that finding fails, **block proof protection**, fix the validation boundary first, and do not weaken the reader. This is a prerequisite, not an optional investigation.

### 2. Prospective proof protection

Keep existing `claudeLiveTranscriptOwnedKeys` as ownership of **all newly inserted keys**, including completed exchanges. Add one transient per-session map:

- `claudeLiveTranscriptAgreedKeys: [UUID: Set<String>]`
- Keys are a subset of that producer’s owned keys.
- No encoding, journal, cursor, receipt, or persisted schema change.
- Use the same lifecycle/reset authority as existing ownership; do not clear either map independently while its producer can still deliver events.

Add an internal refusal scope with exactly two cases:

- `activeExchange`: invalidate owned keys minus agreed keys.
- `entireProducer`: invalidate all owned keys.

Change the private interface from:

`refuseClaudeLiveTranscript(producer:session:)`

to:

`refuseClaudeLiveTranscript(producer:scope:session:)`

Both scopes permanently refuse future qualification. Remove only invalidated keys from ownership and agreement tracking; retain protected ownership so a later contradiction can invalidate it. Existing ledger invalidation and serialized saving remain unchanged. Repeated refusal is idempotent.

**Agreement transition**

An accepted terminal agreement protects only its exact exchange keys, intersected with that producer’s ownership. Imported and other-producer keys never become owned.

For text-only exchanges, change the package-internal evidence case from:

`resultAgreement(localItemID:text:)`

to:

`resultAgreement(ClaudeLiveTranscriptCompleteText)`

Require `matchesProjection` and `holdsClaudeLiveTranscriptRow`, using persisted transcript plus suffix, just as the Read agreement does. A summary is not an exact payload.

For Read exchanges, protect call, result, and answer keys only after the existing complete-chain agreement check succeeds.

Agreement does not establish R7 completion, advance a cursor, or authorize dispatch. It only limits subsequent local proof revocation. A dropped agreement protects nothing; duplicate agreement is idempotent.

### 3. Refusal and contradiction boundaries

Use `activeExchange` for inability to establish a new exchange: unsupported shapes, missing attribution, translation mismatch, missing delivery, background rejection, suppression, unidentified/overlapping outbound, and missing prerequisites.

Use `entireProducer` for:

- Session mismatch.
- Recognized semantic retraction/invalidation markers.
- Launch/drain ambiguity.
- A conflicting existing ledger entry or deterministic-ID collision.
- A canonical payload conflict involving a protected key.
- Re-observation of a previously agreed native entry by that producer.

For a mismatch confined to an unfinished exchange, invalidate that exchange, not earlier agreements. Distinguish missing prerequisites from conflicting existing authority; do not classify every guard failure identically.

**Old-key protection:** add a transient `Set<String>` of agreed native entry IDs to `ClaudeLiveTranscriptProducerState`. Populate it when emitting a successful agreement. Before the sticky-disqualification early return, check session mismatch, semantic markers, and reuse of an agreed top-level native entry ID. Reuse conservatively disqualifies the entire producer, even if the repeated payload looks identical; no general replay support is introduced.

Add a diagnostic reason such as `agreedEntryReobserved`. A later stronger contradiction must emit that reason even when an earlier refusal reason remains latched. Otherwise the owner would receive only the original narrow refusal.

This is bounded contradiction detection, **not** a claim that unknown shapes cannot rewrite earlier history. Unknown payloads permanently stop qualification; complete native-ledger and prefix verification remains mandatory at recovery. Never derive replacement proofs from current native history or summaries.

All producer mutations remain on its existing serialized controller execution context; all owner mutations remain synchronous on the main actor. No new tasks or cancellation behavior are needed.

### 4. Active-chain hydration: separate source closure

Trace:

`hydration request → asynchronous load → freshness check → canonical replacement → next live evidence`

Reproduce replacement between Read call/result and result/answer, including stale load completion and buffered live delivery.

If reachable, the selected remedy is **preventing replacement of active canonical owner state**, not permitting summary equality:

- Reuse the existing run/delivery generation and ownership guards.
- Reject a hydration application that would replace canonical state owned by the active stream.
- Keep current canonical rows authoritative; a stale loaded snapshot must not be applied later.
- Once ownership ends, any needed reload must be fresh.

The actual method names, generation authority, and affected files must come from the trace. Do not introduce another “active” boolean before locating them.

Closure requires either a failing-before/passing-after owner-path test or evidence that existing guards make replacement unreachable. Proof protection may land first, but it does not close this issue.

### 5. Honest recovery refusal

For changed, unproven, unsupported, and unavailable Claude history, explicitly communicate:

> Nothing was imported or sent.

Apply this at the failed recovery-observation boundary, where the action has halted. Do not reuse action-specific wording in dispatch-baseline diagnostics, whose send may legitimately proceed.

Also validate the existing UI distinguishes unavailable/unqualified recovery from verified Resume. Do not add another dispatch path, automatic fallback, or “try anyway.”

### 6. Safety acceptance

Use real canonical-owner fixtures and reader negatives:

- Completed text and Read exchanges survive a later unsupported payload or unidentified outbound.
- An unfinished later exchange loses its proofs; earlier agreed proofs remain.
- Dropped/refused agreement protects nothing.
- Missing prerequisites and missing delivered rows reject subsequent identification.
- Session mismatch, semantic invalidation, old-entry reuse, and protected-payload conflict revoke all still-owned proofs—including contradictions arriving after a narrow refusal.
- Imported and other-producer proofs remain untouched.
- Duplicate accepted rows/agreements do not duplicate rows, accounting, or ownership.
- Summary-only canonical payload never satisfies live agreement.
- Rewritten, missing, proofless, or changed-row-set history **before the import frontier** blocks import and dispatch.
- Save/reload preserves protected digests, never restores cleared digests, and maintains existing lossy-representation rules.
- Recovery failure invokes normal dispatch zero times.

No raw-output retention or history repair is part of these tests.

## File-by-file impact

| File | Change and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeLiveTranscriptQualification.swift` | Strengthen text agreement evidence; track agreed entry IDs; detect strong contradictions before sticky refusal; preserve stronger subsequent notifications. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Exact agreement validation, protection transition, explicit refusal scopes, and differentiated guard failures. Land atomically with evidence changes. |
| `AgentTabSession` declaration/lifecycle file—path not supplied | Add transient agreed-key map and align cleanup with existing ownership. Locate before implementation. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Action-failure wording only; no dispatch change. |
| `Tests/RepoPromptTests/AgentMode/Recovery/` | Extend existing qualification/owner/reader suites; add bounded retention and hydration regression cases. Existing filenames require inspection. |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Record prospective limitation and pending gates without claiming feature completion. |

`ClaudeSessionHistoryReader.swift` and `AgentProcessRegistrySupport.swift` should remain unchanged unless the mandatory ordering inspection discovers a source defect. Hydration files enter scope only after tracing.

## Risks and migration

There is no schema migration. Existing cleared digests remain cleared; affected conversations may remain safely ineligible.

Rollback restores broader revocation behavior. The existing version-7 downgrade limitation remains: older builds may discard recovery metadata.

The main risk is protecting an exchange without sufficient authority. Exact canonical agreement, retained revocation ownership, and unchanged whole-history validation are all required.

## Implementation order

1. Complete the bounded source trace and confirm reader prerequisites.
2. Land producer evidence, owner protection/refusal, transient state, and regression tests **atomically**.
3. Close reachable hydration replacement separately; otherwise record evidence of unreachability.
4. Land truthful refusal wording and zero-dispatch tests.
5. Main agent requests fresh OracleA/B reviews on the same snapshot, attaching the supplied review policy verbatim; follow its bounded re-review and commit rules.
6. Keep qualification activation and final live acceptance pending.

## Recommendations

- **Implement now:** prospective protection, scoped revocation, old-key contradiction handling, and explicit no-send refusal.
- **Do not defer unresolved source safety:** reader validation ordering and active hydration reachability.
- **Defer captures to one isolated live-qualification package.** Another empty-MCP capture cannot close actual permission, MCP, spawn, startup-hook, or marker prerequisites.
- Registration still requires **every supported family/provider pair**; fresh-session-ID qualification is separate. Claude-only success cannot activate it.
- No new owner contract decision is needed for this bounded fix. Narrowing R7 or coupled registry activation would require explicit owner approval and is not recommended.
- Safe refusal closes a safety boundary, **not eligible one-click Resume**. Final live verification and required qualification remain pending.
