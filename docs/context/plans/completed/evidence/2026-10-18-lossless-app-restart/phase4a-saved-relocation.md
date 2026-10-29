# O11 same-ID saved-input relocation — bounded follow-up

Scope: read when the task touches canonical movement/reconstruction and dispatch of an older conclusively unsent saved input.
Authority: Reference
Last-verified: 2026-10-23

## Owner scope and state

Implementation base: `deb4ae5335cab845d61be64d63d992eb3e885bb0`. O11 explicitly selects moving or reconstructing the SAME unsent message at the conversation's current end, retaining its deterministic user-item ID, payload/provenance and saved chronology. A failed send leaves it unsent there; uncertainty after possible handoff is not reclassified as unsent. Unrelated requests, output, execution evidence and references must remain intact.

This is a newly owner-selected bounded follow-up, not reopening the capped whole-Phase-4 review. Full Phase 4 remains blocked. All production registry/Stop/fresh-Claude-ID/Resume/history/Restart gates remain off, O3 live acceptance is pending, and no app/provider/helper/MCP live operation or packaging ran. Claude native identity, automated Restart policy, optional polish and retention are out of scope.

**Bounded inactive source work complete on 2026-10-23 under O12.** The owner explicitly selects OracleA and OracleB for review, and prohibits OracleC unless explicitly asked. No OracleC call was made after O12. Both required independent re-reviews close all P0/P1 on snapshot `2026-10-23/0845`, in one re-review round. This approves only the bounded inactive source follow-up, not full Phase 4, activation or live acceptance.

## Implementation and direct inspection

Main used one Pair session `61F8347E-AD1A-4560-9E76-D46D357B5E8F`, without a workflow or child agents. [OracleE planning](phase4a-relocation-plan-oraclee.md) rejected the initial regroup/rekey proposal. Historical turn H and its span identities stay historical; only unsent item A moves, and a new independent execution turn E receives A as its request. These letters describe existing model identities, not new authorities.

The candidate uses the existing canonical owner, paired hydration, normal owner save and normal dispatch. Preparation installs the canonical and working projection, requires a real covering `.written` receipt before the queue receipt/provider byte, rechecks action/owner/destination after awaits and requires a transient saved-placement proof at synchronous submit. Suppressed/non-writing/reset-only saves cannot authorize dispatch. New run/dispatch/terminal/restore joins resolve E; historical joins are not rewritten. Main directly read these changes, the ownership reconciliation and the save-coverage checks; this is not proof of all preservation behavior.

The final pre-mutation/pre-reuse refusal checks every retained full envelope, not only the moved item's old turn: each must have one deterministic span and no foreign mid-turn user activity. Unsupported shapes keep Edit available. This is deliberate bounded refusal, not multi-span support. A proposed production canonical-replay comparator was cut before the reviewed snapshot in favor of this small shape check. The worker added exact unrelated-envelope and hydration regressions, and historical completed/cancelled/failed timing/terminal metadata is preserved without freezing a live new execution. Main directly checked these load-bearing source/tests and the existing nil-preserves-terminal rule. Restrictions and complete tickets remain in [the worker evidence](phase4a-saved-relocation-worker.md).

Before any activation, note that pre-O11 binaries lack the new reconciliation and can regroup/rekey independent turn/request identities when re-saving a relocated session. Downgrading/re-saving affected sessions is not qualified. Do not build a compatibility layer or activate this candidate based on fixture results.

## Validation evidence

All commands use coordinated development operations. Main verified these conductor tickets terminal with exit 0:
- `6d2eec90-dbb8-4aaf-a36d-10aba896847b`: `make dev-test FILTER=AgentTranscriptRefreshDiagnosticsTests`, 35 tests, zero failures.
- `11459c85-6a34-4904-8d3c-334055fbbd6d`: `FILTER=AgentRecoveryVMProducerAdmissionTests`, 34/0.
- `7f28ff5a-58dc-4138-93aa-ea85ef237db3`: `FILTER=AgentRunTerminalCauseTests`, 16/0.
- `b2ef75d5-5be8-4aa1-8ada-33374c99620a`: `FILTER=AgentTranscriptRawInputReuseLifecycleTests`, 13/0.
- `4923e4ef-b1dd-45a1-8650-1cae770c18fe`: `FILTER=AgentSourceItemIncrementalCommitTests`, 9/0.
- `17bdac65-ccac-47b6-b49a-b682b7d46cec`: `make dev-lint`, pass.
- `405cc529-d16f-439e-9706-1da0c3e46642`: `make dev-swift-build PRODUCT=RepoPrompt`, compile-only pass.

The final three test suites preceded formatting-only edits; the first two, build and lint followed them. Earlier test-compile, test-expectation and formatting failures are retained in worker evidence, not reported as passes. The frozen ledger is untouched.

The worker started an unrequested full-root `make dev-test`; main cancelled ticket `bdd68376-1e18-4dc2-916f-f16d0e9faa1f` using conductor. Terminal state was canceled, exit 130, after 21m36s; it is **not a pass**. Partial output contains other-suite failures not triaged here. No replacement full-root run is planned. Live checks, packaging and production activation were not run.

## Initial frozen reviews and historical credential blocker (superseded by O12)

Main froze exactly 13 O11 source/test changes against the base in RepoPrompt Git snapshot `2026-10-22/2214`, `_git_data/repos/repoprompt-ce-personal-t-27030497/2026-10-22/2214` (1612 additions, 246 deletions). The curated context excluded original unrelated dirt, earlier lane opinions and planning exports. Three fresh independent review requests were sent in one batch with explicit presets and the same requirements, validation, full review policy, source and diff. No source edits followed.

- [OracleA raw initial review](phase4a-saved-relocation-oraclea.md): completed, exact preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` / OracleA verified. Operation `C742426C-8AC9-4C0B-9D3A-7BF88ABB4B65`, chat `o11-saved-relocation-ini-B2D17B`.
- [OracleB raw initial review](phase4a-saved-relocation-oracleb.md): completed, exact preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` / OracleB verified. Operation `D56AFFE1-19E3-4E1E-BC4A-75D9195CB636`, chat `o11-saved-relocation-ini-966020`.
- OracleC: exact preset `6FC689D2-03FA-43F1-A0BF-56570ADF836B` / OracleC verified, but **failed before a review** with HTTP 401 / `invalid_api_key`. Initial operation `32998833-67F5-450D-A56F-5E7E93311A5D`, chat `o11-saved-relocation-ini-3D798A`; one fresh retry on the same frozen snapshot also failed, operation `049DD742-C4DE-4BBD-ADC7-A2B9ADF45F0B`, chat `o11-saved-relocation-ora-3B05F5`. No reviewer was substituted, credentials were not inspected or changed, and no failure output is treated as an opinion.

At the 2026-10-22 stopping point, main read both successful responses but did not synthesize or resolve them after the third lane failed. O12 on 2026-10-23 removed that blocker and authorized the A/B-only completion recorded below.

Main asked the owner whether to repair OracleC (recommended) or explicitly waive the third review for this bounded step. The question timed out after 302 seconds with no answer. That timeout was **not** an owner Decision or waiver. O12 subsequently superseded the question explicitly; the failed third lane is not required and must not be retried without a new explicit owner request.

## Remediation, final validation and required reviews (2026-10-23)

The same Pair session implemented bounded fixes and completed all initiated jobs. Main verified terminal exit 0 for:
- `2839b8de-5e8d-408a-b276-8cd573a4ec48`: canonical refresh diagnostics, 38/0.
- `e6587b29-e706-4f4b-878e-8e8038e1e8ba`: recovery VM admission, 36/0.
- `a7a72fbf-29ea-449f-ba04-578623079245`: terminal cause/join, 16/0.
- `f1fd583b-9de3-4ca8-8dba-c333c227f3fd`: raw-input reuse lifecycle, 13/0.
- `0de56fd1-0e4c-41d9-939f-a69227d09ac4`: incremental source-item commit, 9/0.
- `f35f1a24-05c6-4f26-850a-b552ce51b54a`: coordinated lint, pass.
- `8ce40fd9-62f1-470a-b41f-09876c1fdc30`: compile-only RepoPrompt build, pass.

That is 112 focused tests. The last three suites preceded formatting-only changes; the first two, lint and compile followed them. No full-root repeat, packaging or live operation ran. Earlier test setup/cache-equality and style failures are retained in worker evidence; main inspected the corrected refusal assertions and envelope-field comparisons rather than treating worker assertions as proof.

Main froze the same 13-file scope in Git snapshot `2026-10-23/0845` (+1973/-246). Only two source files and two test files changed after the initial snapshot: canonical preflight/closed-envelope metadata/final-only ownership, paired hydration guard, and their regressions. Both fresh review requests were sent together with explicit A/B presets, identical controlled source/diff/validation, full policy, and only each lane's own prior findings and dispositions. Main verified both returned IDs/names, read full exports and then synthesized results:
- [OracleA R1](phase4a-saved-relocation-oraclea-r1.md): O11-01 P0 and O11-02 P1 resolved; pass, no open P0/P1 or new findings.
- [OracleB R1](phase4a-saved-relocation-oracleb-r1.md): P1-2 hydration fixed/closed. P1-1 alleged nil-reset downgraded to a P2 test gap and closed; issuing reviewer explicitly accepts without contest, because `finalizeTurn` retains the existing state when passed nil. P2-2 incremental ownership fixed/closed. No open P0/P1; clear to commit bounded work.
- B P2-1 remains deferred: speculative later non-import-shaped execution envelopes are not supported; current live importer does not create them and preparation refuses unsupported full turns.
- B P2-3 older-binary re-save limitation is documented above and accepted as sufficient before activation.
- New B P2-A frontier fixture is deferred, without another review loop: main read `AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse` at source 6207–6225. Its validation checks version/count/turn IDs/tier shape, not request or summary content; relocation preserves those inputs and the compactor reuses the validated frozen prefix. This supports preservation by source inspection, but is not a valid-frontier relocation fixture or end-to-end cold-load result.
- New B P3-1 conservative refusals may be frequent: observe only during separately approved O3 acceptance; Edit remains available.
- New B P3-2 optional removal of the remaining full-turn array traversal is deferred as polish, with no timing claim.

Remaining validation limits are explicit: actual DataService cold-load end-to-end and genuine overlapping save-writer execution were not separately exercised, the prior full-root run is cancelled/untriaged, and nothing ran live. Both lanes accept these qualifications for the bounded source checkpoint; no activation is authorized. One re-review round was used, not the original whole-Phase-4 cap.

## Resume / stopping boundary

The prior credential-blocked stopping boundary is superseded by O12 and the bounded A/B source review is complete. Never call OracleC unless the owner explicitly asks. Remaining full-Phase-4 work is the previously identified Claude native-history identity/merge and armed-helper qualification boundary, not another O11 review round. Keep production gates and O3 live acceptance pending; do not repeat the full-root campaign or expand into optional retention/polish.

Final checks passed: `Scripts/check-agent-context` (only the existing 24-route AGENTS warning), `Scripts/test-check-agent-context` (23/0), `make guardrails`, and `.githooks/pre-commit`. Main staged exactly the 13 reviewed source/test files plus the plan/status, linked evidence, the historical investigation supersession note and the seven exact evidence allowlist entries, and read the entire staged diff. No unrelated dirt, ledger, package/release metadata or signing configuration is included. The Pair session and all initiated jobs are terminal; Oracle operations are delivered. This local checkpoint contains the source/status/evidence together; its commit hash and signature status are Git metadata, reported to the owner after creation. O8 permits per-invocation unsigned fallback on signer failure; no amend or push is authorized by this work.
