# Phase 1b shutdown re-review 2 — OracleA

Scope: read when the task touches final review of R4 shutdown preservation and window lifecycle fixes.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat: `restart-shutdown-r2-orac-1B35C6`. Frozen tree: `9f938f44cc977a9a0697033c71ff2ee7bfcd56c5`. Each lane received only its own R1 findings and dispositions.

# Oracle Review

The delta closes the cross-request preparation race by serializing Stage A per view model, and retains failed question-removal IDs for retry before subsequent preservation. It also publishes the freeze through the observed UI stores and places window lifecycle callbacks on a stable container. **No remaining P0/P1 is identified in the supplied delta.** This is a static review of the supplied snapshot; validation results are reported evidence, not independently executed checks.

## Prior-finding status

| Finding | Status | Review |
|---|---|---|
| **R4-01-R1 — Successor question erased by predecessor cleanup** | **Closed** | `AgentModeViewModel+Shutdown.swift:220–230` captures the request identity and joins the preceding preparation across requests. Lines `262–267` then join its removal tail and retry failed removals before preservation. Consequently, stale bookkeeping and removal enqueueing at `347–365` occur before the successor captures/upserts Q—not after it. |
| **R4-01-R2 — Failed removals lose retry ownership** | **Closed within the stated live-lane scope** | `AgentModeViewModel+Shutdown.swift:130–178` records removal outcomes, retains failed IDs with their lane identity, and removes them only following successful receipts. Persistent retry failure blocks the next preparation before upserts. Retired/deallocated-lane handling remains the explicitly disclosed limitation. |
| **R4-01 — Original wholesale replacement** | **Remains addressed** | The ID-scoped preservation logic remains intact; the outstanding cross-request defect is now closed. |
| **R4-02** | **Remains addressed** | Sealed admission and the accepted delayed-clean-ACK interpretation are unchanged. |
| **R4-03 / R4-04 / R4-05 / R4-06** | **Remain addressed** | No regression identified in the supplied changes. |

The two real-VM supersession regressions exercise the relevant suspension **after question persistence**, and check both ownership and persisted question/answer contents after draining cleanup. The reported mutation check—10 assertions failing when predecessor chaining was removed—provides useful evidence that these tests detect the reviewed race. They are not end-to-end live shutdown acceptance.

## Delta regression assessment

- **Window lifecycle:** `WindowContentView.swift:117–130` structurally separates host callbacks from conditional content. The offscreen fixture verifies the new host’s behavior. Because the old bare-conditional control also avoided outer disappearance, this is **defensive structural protection, not a demonstrated reproduction and repair of the old bug**.
- **Freeze propagation:** Composer and answer-card snapshots now carry the freeze, with synchronous publication on begin/end. The text-view delegate consults the live refusal closure before normal text mutations, and image paste checks the live freeze before preparing attachments.
- **Deadline:** Waiting for predecessor work does not itself bypass the coordinator’s independent absolute deadline or late-completion fences. A stalled predecessor prevents successor success rather than allowing preservation to overtake cleanup.

No new actionable P2 findings identified.

## Recommendations

- Accept this round’s closure of **R4-01-R1** and **R4-01-R2**; no further code-review round is warranted by this delta.
- Keep **O3 live acceptance explicitly pending**, including real WindowGroup/New Window/tab behavior and provider shutdown.
- Record the evidence boundaries accurately: offscreen lifecycle verification, store-publication testing, and compile/neighbor-suite coverage do not establish full live UI acceptance or completion of Phases 2–4.
