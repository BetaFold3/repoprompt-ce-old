# Step 4d4 initial OracleB review

Scope: read when the task touches the exact native mode reader review.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/0904. Main verified the returned preset identity. Response follows verbatim, with a terminal newline.

# Oracle Review



# Step 4d4 review: exact Claude `mode` record acceptance (snapshot 2026-10-24/0904)

## Summary

The change adds one strict parser, `parseModeRecord`, reached through a new `case "mode":` in `parseEntry`. It accepts exactly one record shape as non-projected metadata: `{type:"mode", mode:"normal", sessionId:<this session>}`. It refuses everything else using existing error cases:

- A `uuid` or `parentUuid` key, even when null, refuses with `operationalRecord("mode")`.
- A missing, null, non-string or different `sessionId` refuses with `sessionMismatch`.
- Any extra key, including retraction markers like `supersedes`, refuses with `metadata(<first key in sorted order>)`.
- A missing, null, non-string or non-`"normal"` mode value refuses with `metadata("mode")`.

`mode` is deliberately kept out of `operationalTypes`. Native IDs, digests, tool pairing, prefix fences, ledger checks and the live classifier are untouched.

I traced the four new fixture tests against the decoder:

- **Line number:** `first.count + second.count - 1` is the correct 1-based line of the mode record.
- **Escaped slashes:** `\/` in `toolInputJSON` matches `JSONSerialization`'s default slash escaping.
- **Validation count:** `validationRows.count == 12` is 3 exchanges × 4 rows.
- **Check order:** tool-result validation runs before branch validation, so the wrong-parent cases surface as `toolAssociation` rather than `ambiguousBranch`.

The resume test checks a byte-exact prefix, imports only the three-row resumed exchange, and confirms that a replay appends nothing. **I found no P0 or P1 issues.** The boundary is as narrow as the source contract asks.

## P2

### P2-01: Wrong label on the "attachment between call and result" fixture case
- **Evidence:** in `ClaudeSessionHistoryReaderTests.swift`, `testO20WrongToolResultIdSourceOrParentRefusesTheWholeCandidate` contains `refusal { $0["parentUuid"] = "o20-n3-1" }` with the message `"an attachment between call and result"`.
- **Scenario:** `o20-n3-1` is the `budget_usd` attachment that comes *before* the call (it is the call's parent). Re-parenting the result onto it makes the result a sibling of the call. It does not put an attachment between them. The case still refuses correctly, but it tests a different shape than its label says.
- **Impact:** the actual O20 interposed shape is not covered by the O20 fixture: a new attachment parented on `o20-u3a`, with the result parented on that attachment. The generic `interposed` case in `testAttachmentsKeepEveryGraphSafeguard` already guards this behavior, so this is a coverage and labeling gap, not a defect.
- **Smallest fix:** either relabel the case ("result re-parented onto a pre-call attachment"), or add the real interposed variant: insert `attachment("o20-x", parent: "o20-u3a", type: "date")` into `second` and set the result's `parentUuid = "o20-x"`, expecting the same `unassociated` refusal.

## P3

### P3-01: Doc comments still describe every skipped record as "operational, unread"
- **Evidence:**
  - The doc comment above `parseEntry` reads "`nil` = an operational record (validated to carry no graph identity, otherwise unread)."
  - The `.success(nil)` branch in `decode` is commented "An operational record: no graph identity, skipped unread."
- **Impact:** both comments now also cover the `mode` record, which is fully read and validated, not skipped unread. That contradicts the new header note that `mode` "is deliberately not an operational type."
- **Fix:** reword both to "an operational record or the exact `mode` metadata record (no graph identity, never projected)."

### P3-02: `operationalRecord("mode")` is reused for a type documented as non-operational
- **Evidence:** the doc comment on `Unsupported.operationalRecord` says "An operational record carrying `uuid`/`parentUuid` graph identity." The `uuid`/`parentUuid` guard in `parseModeRecord` returns `.operationalRecord("mode", line:)`.
- **Impact:** this is cosmetic. Reusing an existing case is what the contract asked for, but anyone reading diagnostics may conclude `mode` is in `operationalTypes`.
- **Fix:** broaden that case's doc comment to "an operational or exact-metadata record carrying graph identity." Don't add a new error case.

### P3-03: O20 fixture omits some operational records listed in the capture layout
- **Evidence:** compare `o20Exchange` with the native layout in `phase4d-tool-resume-capture.md`:
  - Exchange 1 omits `api-request-shape` (ordinal 12) and has one `api-request-blob` per gap where the capture shows ×2 (ordinals 13–14 and 21–22).
  - Exchange 2 omits `atis-latch` between the pre-assistant `last-prompt` and the final assistant (ordinal 40).
- **Impact:** none on behavior. These record types are skipped unread wherever they appear, and other tests cover them. But the doc comment says "Hand-written from the sanitized … O20 observations," which implies more fidelity than the fixture has. The notable placement is `atis-latch` sitting between `last-prompt` and an assistant entry.
- **Fix:** either add those records to match the recorded ordinals, or soften the doc comment to "modeled on" and name the omissions.

### P3-04: Small duplication with the operational-type branch
- **Evidence:** `parseModeRecord`'s `uuid`/`parentUuid` guard repeats the guard in the `operationalTypes` branch of `parseEntry`.
- **Impact:** negligible at two call sites. The session rule really does differ (required for `mode`, optional for operational records), so a shared helper would save little.
- **Recommendation:** leave as is. This is noted only so a third exact-shape record type triggers extraction rather than a third copy.

## Recommendations
- Nothing blocks the commit. P2-01 is cheap (a relabel, or one extra fixture case), so fix it in this step if convenient; otherwise defer it.
- Fold P3-01 and P3-02 into the same small comment-only edit if you touch the file. P3-03 and P3-04 can be listed as deferred.
- The scope claims hold: no change to native IDs or digests, tool pairing, fences, ledger, live classifier, schema or routing. Acceptance is limited to the single exact observed `mode` shape. Nothing here supports a general native-format or no-replay app qualification, and the code and comments don't claim one.
