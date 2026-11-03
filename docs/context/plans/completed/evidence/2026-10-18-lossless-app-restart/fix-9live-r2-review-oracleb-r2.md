# 9-live round-2 fixes: OracleB review, round 2
Scope: read when the task touches the round-2 live-check fixes (Claude history shapes and claim, Codex full item view, recovery wording).
Authority: Reference
Last-verified: 2026-10-29
Covers: OracleB review round 2 of the S1, S3, S4 and S5 fixes

# Re-review round 2 (final): 9-live round-2 fixes

I traced both changed behaviors and found **no P0 or P1 code defects**. The one remaining P1 is a **gate** (something to confirm in a live run), not a code bug.

## What I checked

### 1. The thinking-envelope keys

`ClaudeLiveTranscriptQualification.swift:370-372`, `:520-528` and `:645-667`.

- **The two new keys are accepted only on thinking envelopes.** `thinkingKeys` is used only inside `classifyThinking`. Text, Read-call and Read-result envelopes still use their own key sets, so a text envelope that carries `thinking_display` still refuses. The test pins this.
- **Bad values refuse.** A non-string display, or a duration that is a string, a boolean or a negative number, is refused as `unsupportedAssistant`. JSON can't produce NaN, so the `>= 0` check is complete.
- **Benign means no state change.** The thinking envelope's own entry ID is never recorded, and the text row's identity uses only the entry ID and the text. So a native thinking entry sitting between the prompt and the text in history can't change the live ledger key or digest, and the round-1 no-duplicate result still holds.
- **The routing doesn't let anything new through.**
  - Thinking is accepted only while the turn is `.dispatched` or `.readReturned`.
  - Thinking while waiting for a Read result, or after the answer, still refuses with `unownedAssistant`.
  - Multi-block envelopes, `redacted_thinking` and sidechain thinking (non-null `parent_tool_use_id`) still refuse.
  - Unattributed thinking from a turn the CLI starts on its own is harmless. The text that follows must still carry attribution on an unreplayed dispatch, or it refuses with `unattributedAssistant`.
- **The translator assumption** (thinking translates to `usage` only) is a compile-time constant. It was also confirmed on all 7 real thinking envelopes in the K1/E7 stdout logs. If it ever changes, the producer refuses, so it fails closed.

### 2. Configured-path identity eligibility

`ClaudeNativeProcessSessionController.swift:~1047-1051` and `resolveLiveTranscriptEligibility` at `~:4067`.

- **The rest of the rule is unchanged.** Eligibility still requires `.defaultClaude`, an empty `environmentOverrideKeys`, and an admission that claims the send. `.programmaticOverride` and compatible backends stay ineligible, and the tests pin both. A retry still carries no `uuid`.
- **The check covers only RepoPrompt's own environment.** `environmentOverrideKeys` is computed from the environment RepoPrompt hands to the wrapper. Anything the shim sets for its child, such as `CLAUDE_CONFIG_DIR`, is outside the check by design. That is exactly what the owner accepted.
- **Every way a wrapper can misbehave ends in a refusal:**

  | Wrapper behavior | Result |
  |---|---|
  | Drops or rewrites the `uuid` | Claim unmatched |
  | Rewrites the text | Digest mismatch |
  | Injects its own user turn | The native user entries no longer equal the claimed IDs in order, and live attribution refuses with `attributionMismatch` |
  | Prints non-protocol lines on stdout | `malformedLine` or `unsupportedPayload`; the producer refuses and its proofs are invalidated |
  | Changes session ID on failover | `sessionMismatch` |
  | Leaves two copies of the session file | Ambiguous |
  | Rewrites earlier history | Prefix mismatch |

  None of these imports anything or sends anything.
- **Ordinary output is unchanged.** Making a configured path live-eligible adds evidence only. `testGateOffAndIneligibleLaunchesMatchLegacyOutputAndEligibleAddsOnlyEvidence` pins that the configured run's results match the automatic run's.

## P1 (gate, not a code defect)

### The claimed send through the shim has never been seen live, and S1 only pays off if it works end to end

**Files:** `ClaudeNativeProcessSessionController.swift:~1047` (eligibility), `ClaudeLiveTranscriptQualification.swift:~540-548` (`unattributedAssistant` on an unreplayed dispatch).

None of the K1/E7 frames carried a `uuid`, so four links are only inferred:

1. **The shim forwards the `uuid` unchanged.** This comes from reading the shim's code, not from a run.
2. **CLI 2.1.302 writes it as the native prompt entry's `uuid`.** This was shown in O19, but that run was direct and first-party, not through the shim.
3. **The text envelope after a thinking envelope carries `user_message_uuid`/`user_message_uuids` naming the claim.** The real thinking envelopes had no attribution, which is expected because nothing was claimed. Whether the *text* envelope of a thinking turn is attributed once a claim exists is unproven. If it isn't, every thinking turn refuses with `unattributedAssistant`. That is safe, but the live rows get no proofs, so Reconcile refuses on overlap and S1 delivers nothing.
4. **Mid-turn account failover.** This is the first time the shim's failover path will see `uuid` frames. If the replacement child resumes from a copy of a history file that already holds the claimed entry, the CLI either:
   - writes a second entry with the same `uuid` (the reader refuses it as a conflicting duplicate), or
   - drops the re-delivered turn as already processed.

   The second outcome would be a **lost send in ordinary use, not a recovery refusal**. Nothing here protects against it, and I couldn't confirm the CLI's duplicate-`uuid` behavior from the evidence.

**Suggestion:** treat links 1–3 as the first step of the live re-check, below. Check link 4 once on purpose before relying on failover under capture.

## Recommendations

1. **Run the live re-check in this order, comparing IDs and structure only:**
   - **a.** One plain thinking → text turn through the shim. Confirm:
     - the stdin frame (`protocol.outbound.raw`) carries the `uuid`;
     - the native prompt entry's `uuid` equals `dispatchBaselines[].outboundUserMessage.uuid`;
     - the text envelope carries both attribution fields naming that `uuid`;
     - the live producer is still qualified at the result, with no disqualification carrier.
   - **b.** Kill after the answer is shown. Expect Reconcile to give `.imported(rowCount: 0)` and the reply to appear once.
   - **c.** Kill mid-thinking. Expect zero rows with the claim matched.
   - **d.** A Claude tool turn (K3/K4). Expect a safe refusal.

   Record the saved reason on any refusal.
2. **Force one shim failover with capture on.** Check that the turn is still answered (not dropped as a duplicate) and that Reconcile refuses or imports without a duplicate row. If the CLI drops re-delivered frames with a known `uuid`, the shim needs to deliver held turns differently, or capture must be turned off for failover. That is the shim owner's decision.
3. **Small clean-up, optional:** the doc comments on `markEligible` (`ClaudeLiveTranscriptQualification.swift`, "automatic command, default backend…") and the file header still describe the eligibility rule as automatic-only. Update them to match `outboundUserMessageIdentityEligible`.
4. **`deferred_tools_record` and `silent_turn_reminder`:** no change. Decide once the new reason text shows how often they actually block a live session.