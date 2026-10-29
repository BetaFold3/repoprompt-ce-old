# Restart minor fixes — OracleA re-review 1
Scope: read when the task touches restart-spec Step 7-minor review findings (cancelled Codex bash row status).
Authority: Reference
Last-verified: 2026-10-26

Covers: OracleA fresh-chat re-review round 1 of the Step 7-minor item 1 delta (controller ownership), with its own dispositions. Verbatim export follows.

# Oracle Review

The delta adds controller-generation ownership to live bash executions, preserves existing ownership across rebuilds, and leaves restored rows unowned. Vanished processes now settle as `interrupted` unless the attached controller owns them, avoiding both false success after relaunch and an invented exit code. No recovery-classification, intent, shutdown-ordering, or cancellation-step changes appear in the supplied diff.

## Review disposition

- **MINOR-01: closed for the reported restore/reconnect scenario.** Attaching a controller no longer claims restored executions; the poll requires matching ownership. The new regression test and reported fail-first result directly exercise the original failure.
- **MINOR-02: closed.** The `interrupted` fallback preserves an unknown exit code while retaining the existing normalized cancellation presentation.
- **MINOR-03: partially addressed; remaining ordering coverage deferred.** The new test verifies authoritative completion **before** polling, not completion after fallback settlement.

No new P0/P1 finding is established by the supplied changes. Validation results are implementer-reported; this was a static review of the provided excerpts and diff.

## P2 — Consider

### MINOR-04 — Generation-transition coverage remains incomplete

**Evidence:** `CodexAgentModeCoordinator.swift:8730` (`claimLiveBashExecution`), `:8857` (running-update ownership), and `CodexAgentModeCoordinatorLivenessTests.swift:1520–1538`.

**Scenario and impact:** Ownership is stamped from the session’s **current** controller, not the event’s originating controller. If an old controller’s queued event can reach these helpers after replacement, it could incorrectly claim an execution for the replacement and restore false-success settlement. Conversely, a legitimate successor event should claim an execution it actually resumes.

The supplied excerpts do not include event-dispatch generation fencing, so this is a verification gap—not a demonstrated regression. Normal live create/update paths shown do assign ownership; there is no evidence that ordinary attached-controller executions systematically remain unowned.

**Smallest follow-up:** Add focused tests covering controller replacement with no subsequent event, a stale old-controller event after replacement, and ownership preservation through a live-state rebuild. Confirm stale events are rejected at dispatch.

### MINOR-05 — Transport-close fallback can leave a persistent false success

**Evidence:** `CodexAgentModeCoordinator.swift:4848`, `:9638–9660`, and `finalizeLiveBashExecution` in the supplied `:8930–8965` excerpt.

**Scenario and impact:** During active-run transport recovery, the retained controller still matches the execution owner. A vanished process can therefore settle as `finished` without an authoritative outcome. This is **not necessarily temporary**: finalization removes the live execution and schedules persistence, so replacing the controller alone does not correct the terminal row.

**Disposition:** I do **not contest deferral from this bounded round**: this is an acknowledged pre-existing active-run gap, distinct from restored-row ownership.

**Smallest follow-up:** Track it explicitly and test transport closure followed by process disappearance without completion. Any later fix should distinguish an attached owner from one still capable of delivering completion.

## Recommendations

Approve this re-review with **MINOR-01 and MINOR-02 closed**, no established new blocking regressions, and the above P2 follow-ups recorded. Keep the remaining MINOR-03 ordering test deferred, and avoid describing the transport-close settlement as automatically corrected by reconnection.