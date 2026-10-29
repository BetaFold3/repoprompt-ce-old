# Step 4b — late retained-helper stop recovery

Scope: read when the task touches the bounded late-stop recovery implementation, validation or review disposition.
Authority: Reference
Last-verified: 2026-10-23

## Scope and result

This follows signed baseline ff475f0b and [remaining pre-live scope](pre-live-work.md). A possibly armed helper whose stop is unknown still blocks automated Restart activation. This step only repairs the permanent wedge after the exact retained helper is actually proven stopped. Production gates remain OFF and O3 live acceptance pending. [Worker report](phase4b-helper-stop-worker.md) records the source contract and initial validation.

The four changed source files are ProcessRelaunchHelper.swift (latched replay-safe, cancellable positive stop proof), AppRelaunchCoordinator.swift (release only the retained matching helper), AgentLifecycleShutdownCoordinator.swift (fenced proof observation, old presentation invalidation, restored failure choices) and WindowStatesManager+LifecycleShutdown.swift (sheet/app-modal dismissal). Existing explicit manual Retry starts its normal fresh attempt; the notification itself never renews a deadline, spawns, quits, retries, saves or marks clean.

## Review

Initial A/B requests ran together on the same seven-file snapshot 2026-10-23/1204 (+560/-16), current source/tests, explicit acceptance criteria, validation and verbatim policy. Both exact preset UUID/name identities matched. Main read both complete outputs: [OracleA](phase4b-helper-stop-oraclea.md), [OracleB](phase4b-helper-stop-oracleb.md). Both accept with no scoped P0/P1. They did not independently run validation.

Cheap correction made after review: A R1 / B S4b-P3-02 identified that consuming a latched exit did not preserve its typed proof on a repeated abort. Main read the exact branch, set helperExited from the actual proof before finishing, and extended the regression to require exitObserved on repeated abort. This changes the evidence label, not proof eligibility or ownership. Main also extended the existing ignored-informational-answer test to deliver proof afterward and exercise explicit Quit Anyway. No extra review round is run just for P2/P3; affected validation is rerun.

Deferred:
- B S4b-P2-01: app-modal dismissal may present the replacement before the old modal loop unwinds. Keep the no-parent-window case explicitly in O3; no data-safety regression was identified, and production Restart remains disabled.
- B S4b-P2-02: the realistic OK-then-proof sequence now has assertions. Driver late-aborted release and unreachable request-ending observation-cancellation coverage remain deferred; session cancellation/correlated acknowledgement and driver exit release are covered.
- B S4b-P3-01: buffered unsolicited aborted behavior predates this change; the real helper sends only a reply. No protocol hardening is added.
- B S4b-P3-03/04: pre-existing repeated messages and small factoring are optional polish, deferred.

## Validation

Worker's final source-validating suites passed 75 tests: ProcessRelaunchHelperTests 29 (beefe9e7-d206-486a-a55e-1c9f28b92f47), AppRelaunchCoordinatorTests 11 (fa053a91-be5c-414e-8cef-72d6d7dc01ec), AgentLifecycleShutdownCoordinatorTests 35 (bcddf575-6876-45d9-9493-e1a85920e2ab). Lint bcac2a33-da73-453b-89fe-9dec38bc6d1f and compile-only app/MCP builds 3ec398e3-11bc-4f37-af09-67f64cb34e98 / 64f1f222-76aa-4b58-9c71-8cb207cfaa54 passed. Main directly checked every completed/exit-0 ticket. The worker's nine artifact reruns were unnecessary extra flake checks, not additional source validation; no repeat campaign is selected.

The first main post-review combined FILTER containing unescaped pipe characters was misinterpreted by the Make recipe's shell. It returned error 127/Make exit 2 with command-not-found and a broken output pipe; no pass is claimed. Active-job listing was empty afterward. Main reruns the three supported single-suite commands separately, plus lint and both compile-only builds.

Post-correction source validation passed all 75 tests again: ProcessRelaunchHelperTests d353d904-6931-422c-a341-b5d64f31607c, AppRelaunchCoordinatorTests 013a17b6-7396-4418-8b28-af66b3f63e3d, AgentLifecycleShutdownCoordinatorTests 8730a033-5012-48de-b6dc-ad149ee6ce9c. Lint 6d123503-1826-4ed2-8cb4-8a1d3511695f and compile-only RepoPrompt be7532bc-c43b-4d86-882c-c1f25c03d551 / repoprompt-mcp 17c97279-875f-4bce-9d1f-0ebe2dd0cb05 passed. Main ran and waited for all six commands. Context checker and its 23-case negative suite passed; the temporary response-depth warnings are resolved by the owning Step 4b link. Only the existing 24-route AGENTS warning remains. Guardrails passed before staging; final staged checks follow.

No root test suite, packaging, visible app lifecycle, provider/helper/MCP executable runtime, runtime-data/home/credential/process inspection, signalling, dev-format, ledger mutation or live acceptance ran. Real AppKit modal behavior and OS exit observation remain unverified.

## Final checkpoint boundary

Main passed staged whitespace, make guardrails and .githooks/pre-commit after staging all 18 intended files. The scoped read-only audit initially could not read main-tab Git artifacts; no verdict was inferred. Its own authorized immutable staged snapshot 2026-10-23/1212 then covered MAP lines 1–143 and every patch line 1–2135, exactly 18 files/+1772/-17, with no unexpected hunk. Main verified the staged tree stayed 14171438891f6401319482666e69a0be69d15ca3 during that audit, read the owning plan/allowlist diff, and verified all six retained Oracle bodies against their original exports (only documented trailing-whitespace normalization). The only subsequent edit is this evidence paragraph, read/restaged separately. No source changed after the validated minor correction. Original unrelated dirt remains excluded; no push or history rewrite. Normal signing failed with `1Password: failed to fill whole buffer` and `failed to write commit object`; no commit was created. O8 authorizes a per-invocation unsigned local fallback, without changing signing configuration.

## Maintainer-guidance check

The source-owned invariant is that later positive stop proof restores usability without weakening no-relaunch safety while uncertainty remains. Existing helper/session/shutdown owners are retained; event-driven observation adds no poller, persisted authority or provider work. Unknown-stop R4 policy and Claude identity remain full-contract blockers, not silently closed by this source step.
