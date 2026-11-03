# Step4d3 — canonical payload protection and single-text live identity

Scope: read when the task touches Claude recovery canonical payload comparison, identified-row mutation protection, or the bounded single-text live carrier.
Authority: Reference
Last-verified: 2026-10-23

## Checkpoint and planning

Step4d2 is committed as `bf1fce5a24b41ede88b0cffe5c9e0c81e34def18`, unsigned under O8 after normal signing failed with 1Password “failed to fill whole buffer”, Git128. No signing configuration changed or push occurred. Main read the complete initial staged source diff (188407 characters), the462-line repair delta and the complete documentation delta before committing21intendedfiles. Focused source validation and A/B re-review1 passed; final docchecker23/23, guardrails, diffcheck and precommit passed. Original unrelated dirt stayed unstaged.

Fresh independent [OracleA](phase4d3-plan-oraclea.md) and [OracleB](phase4d3-plan-oracleb.md) planning returned the exact expected presetIDs/names. Main read both full responses. A's operationF36C3701-74B6-498C-BB49-9DCB0CFE1933; B's operation316A91CC-9A8D-4921-9BBD-F90F1D5E7136. These are plans, not source reviews.

## Selected bounded sequence (implementation assumptions, not owner Decisions)

1. **Step4d3a now:** retain the already-built ordered full native projection transiently through preflight, separately from new rows to append. Compare each mapped ledger row with actual canonical payload and relative order across persisted turns and mutable suffix before overlap/dedup acceptance. Missing, ambiguous, compacted or incomplete payload refuses. Compare supported semantic fields, not timestamp/streaming/sequence presentation. Exact serialized tool fields are conservative until broader tool qualification; do not add a normalization framework or hydrate arbitrary artifacts. Protect every Claude-associated local assistant ID even without a valid digest at the actual active/background delta and final-content mutation sites. An equal final text is unchanged; unequal text is a new visible unidentified row, never replacement. Keep existing ownership, pointer retirement and notification semantics. No carrier, new gate, persisted marker or other tool-mutation redesign in this slice. Payload checks detect changed tool rows; universal live-tool immutability is not claimed.
2. **Step4d3b next:** use A's existing-ledger insertion and proof invalidation, with whole-event evidence through existing DTO/bridge/controller/router and a default-off built-in-only path. No additional persistent qualification collection/marker, no terminal-only proof commit (that would leave interrupted output unassociated). Protect and persist row/proof coherently under existing save ownership; no new journal. Revisit exact semantic signal classification using supplied public declarations and captured event types, not broad benign assumptions. Unsupported output remains visible. This was the initial implementation sequence; Step 4d3b is now implemented and reviewed as recorded below, still inactive.

B's added sticky revocation member and clean-terminal-only identity are not selected: the existing optional proof can carry durable refusal without a new authority, and the goal includes interrupted output. Neither lane's broad tool/metadata suggestions establish installed-profile qualification. No field, row-ID algorithm or invocation-ID change is adopted without inspecting its current source.

Main verified the scout's key seams: reader has full ordered rows before suppression; before this step, canonical preflight checked ID sets; transcript activities expose actual tool semantics through toItem; before this step, final_content replaced a selected assistant payload. The scoped worker used existing helpers and avoided rendered/windowed projections.

## Controller-only scope reduction (before Step4d3b implementation)

This section and the next source check record the pre-implementation Step 4d3b scope decision. Implementation and review results follow below.

Both planning lanes accepted attaching a core-only immutable evidence companion inside the native controller, where the same raw payload and translated AIStreamResults already meet. Main verified both returned inherited preset identities and read both full responses. B's first stream failed with message_missing; one retry succeeded. Full continuations are retained with each lane's plan. Cut package DTO, translator, bridge and mirror changes; preserve legacy output/accounting/completion order. Main verified controller2434–2518 and its automatic/default-backend/no-routing-overrides eligibility924–932.

The classifier must inspect every raw envelope before suppression, including arrays with no translated results. A complete envelope accompanies its one matching content result; disqualification cannot disappear through filtering. Producer qualification is monotonic over activeStdoutLaunchToken, reset only at actual new producer installation, never perturn or consumer reset. Main verified launch installation1359–1362. Existing NativeItem optional proofs remain the durable authority: missingdigests already refuse in4d2. No new persisted revocation field, and no token-to-row collection is needed when conservative owned-conversation proof invalidation suffices. Never regenerate an invalidated proof from a later duplicate. No broad “all system/rate-limit events benign”; exact supported shapes only. Owner-side canonical identity/payload and final-text agreement remain required, no backward search across ownership boundaries.

Keep the existing serialized scheduled-save boundary. Main verified14951 checks owner and14994–15008 schedules fresh content after a stale snapshot. A committed invalidation must not be overwritten by an older save; before the first invalidation commit, a crash can retain oldproofs. This known window is not closed by proof clearing and cannot be called immediate crash-safe revocation. No journal or new barrier in this inactive slice; activation stays blocked. Non-success/abort output conservatively disqualifies, under delegated judgement rather than another owner question.

Step4d3a first validation passed reader34, reconciliation40, owning lifecycle195, compile, format-check and lint; main independently checked logs and ticketexit0. The requested background test filename is an extension, so its filter was rejected with no override and the actual AgentModeRunServiceLifecycleTests suite ran instead. Main read the complete46257-character8filediff. Beforeinitialreview, main requested two bounded completions: fullcanonicalID dedup (not suffix-only) and user/order anchors without comparing transformed provider/local input text. Fullknown-history refusal after compaction remains deliberate; no retention/hydration expansion.

## Offline capture check

A dedicated read-only worker inspected only the already-authorized O19 private copies. Main independently repeated an allowlist-only parser: stdout has3command_lifecycle,1system,1user,1assistant,1rate_limit_event,1result and0stream_event; exactly one assistant exists in both live/native copies; exact content, reader-semantic digest and result.result equality are true. No new provider prompt or process was launched. This establishes only the observed one-text shape's compatibility, not whole-file acceptance, tools, thinking, multiblock or resume.

The further bounded tool/resume-capture question timed out without approval. No further prompt is authorized by that question. Restricted/safe-mode controls are documented, but managed hooks/additional-directory confinement remains unproven; no new capture runs. Production registry/recovery/Resume/restart activation remains OFF and final live acceptance remains pending.

## Additional source and offline-shape checks for Step4d3b

Main checked controller943–985: it already has outboundUserMessageUUID and exact provider-bound text before encode/sendLine; successfulwrite and beginTurnTracking share one nonsuspending actor step. A bounded transient replay association can be recorded there, rather than guessing the latest user. Scoped source search found only the reverse-bridge declaration and its unused PluginBridge forwarding declaration, no downstream callers; core-native evidence need not round-trip through the package. The4d2 reader's ledgerConflict523–543 rejects every known entry whose digest is nil or mismatched, confirming proof invalidation refuses without another marker.

Allowlist-only inspection of the already-approved newcapture (no credential/config values, native opaque blobs, or new prompts): command_lifecycle states were queued/started/completed with exactly command_uuid/session_id/state/type/uuid keys; system subtype was init. User replay fields were isReplay(bool), message(object with role/content strings), parent_tool_use_id(null), session_id/timestamp/type/uuid(strings). Assistant fields were message, parent_tool_use_id(null), request_id/session_id/timestamp/type/user_message_uuid/uuid(strings), user_message_uuids(array); its message contains content(array), id/model/role/type(strings), usage(object), input_transformations(array), and null container/context_management/diagnostics/stop_details/stop_reason/stop_sequence. Rate-limit event has type/session_id/uuid and rate_limit_info; info contains status(allowed), rateLimitType/overageStatus/overageDisabledReason(strings), isUsingOverage(bool), resetsAt(number), unifiedWindows(object). Success result has result(string), subtype(success), is_error(false), session_id/uuid, user_message_uuid/user_message_uuids, numeric result_index/durations/cost/timing/count fields, usage/modelUsage/subagent_stats objects, permission_denials array and api_error_status(null), plus stop_reason/terminal_reason/fast-mode strings. These observed fields are not blanket future schemas or semantic authorization; unknown or replacement-bearing shapes still refuse. Raw identifiers, auth values and metadata payloads are not retained.

## Step4d3a initial review snapshot

The completed8source/testfiles are frozen and staged as `2026-10-23/2226` (+833/−18); no commit yet. Main independently verified finalreconciliation42/42 edfdb5bd, compile4da0a053, formate16d7fa3 and lint2841ba32, with unchangedreader34 and lifecycle195 results. The addedorder/placement negativecontrol failed5assertions beforethefixeswere restored. FreshA/B initialreviews were sent together with exactpresetIDs, samefrozencontext, no cross-lane findings and fullreviewpolicy. At that point the review was pending and no implementation worker was running. Useranchorcomparison and fullcanonicalID plannerdedup were completed beforethissnapshot, notdeferred.

## Initial review disposition

Both initialreviewresults on2226 returned exactexplicitA/B identities andwere readinfull. A R1 and B F1 describe the same genuineP1: cross-user/outputorder checking rejects unchanged replay afterappend-at-end recovery ofinterleavedsteeredhistory. Main accepts the defect and selects B option(a): cut the newlyintroduced cross-grouporder guarantee, retain separate relativeorder amongmappedprovideroutputs and amonguseranchors, and preserve theexistingappend-only recoverycontract. This is a reversibleimplementationassumption, notanownerDecision; userdelegatedjudgment andexistingarchitecturefavor cuttingtheextra restriction ratherthan insertion/reordering or newlyblockingworkingsteeredimports. A's proposedrefusalbeforefirstimport is notselected because it would unnecessarilyregress the4d2 steeredimport positivecontrol. Neither P1 was downgraded or rejected; each lane later received its own finding verbatim and the repair evidence in re-review 1. Main read the complete 65093-character staged 8-file diff. The existing Pair then made only this repair and the economical real-builder coverage; optional B F2/F4/F5 were deferred. All gates stayed OFF.

## Re-review1 snapshot

Repairsource is frozen as `2026-10-23/2241`,2files +147/−29 against staged2226. The earlier2240artifact accidentallyincluded worker evidence throughautomaticselection; it wasnotused forreview. Mainread thewhole2filedelta, verifiedreconciliation43/43 ticket804a6d70, compile1f5a9ada,formataaf33246 andlintec257e33 exit0. A negativecontrol failed10assertions, restoredfinalpassverified. Main accepts the economicalrealbuilder correction: turncopies maymatch onlytheexistingnormalizedToolName(expected) transform, suffixcopiesremainexact; mainverifiedtoolExecution builder1765–1840. No new normalizationframework. FreshA/B re-review1 senttogether withsame2filedelta/context, fullpolicy andeachlane'sownP1verbatim. No rawother-lane reviewselected. At that point results were pending and no worker was running; both results are recorded below.

## Validation boundary

Step 4d3a ran the existing reader and reconciliation suites (the background-transcript filter was rejected, so the owning lifecycle suite ran instead), compile-only RepoPrompt, format-check and lint. No full suite, packaging, provider, visible app or lifecycle operation ran. All new source evidence is fixture/offline evidence. Main alone runs A/B review and commits after acceptance.

Step4d3a worker evidence: [phase4d3a-worker.md](phase4d3a-worker.md). Initial reviews (verbatim): [OracleA](phase4d3a-review-oraclea.md) and [OracleB](phase4d3a-review-oracleb.md).

The option (a) repair is unstaged on top of the staged 2226 snapshot:
- Output rows and user anchors are each order-checked only among themselves.
- The pure claim and payload tests accept the importer's `[first, steer, reply]` and still refuse reordered outputs or constituents.
- A real view-model two-dispatch regression covers four cases: the first import, a no-op unchanged reconcile, a no-op lost-CAS replay, and an accepted append-only import.
- A cheap real-builder tool round trip (B F3) accepts only the builder's normalized tool name on turn copies.
- Reconciliation passed 43/43.

See [initial-review repairs](phase4d3a-worker.md#initial-review-repairs).

## Step4d3b implementation boundary

Step4d3a checkpoint is `60132a4b8b8d83c3e21804452a98bc18b396c7cf`, unsigned underO8 after the precedingcheckpoint's signingfailure; no new signingattempt or configurationchange. All18intendedfiles committed, originalunrelateddirtunchanged. Main inspectedinitialstagedsource+repair, fullplanning/reviewresponses, finalnotes andworker evidence; allfourreviewcopies verifiedbyte-identical toexports. Initialstageddiffcheck foundthree trailingMarkdownwhitespace linesinplanningexports; mainnormalizedonlythatwhitespace, markedthecopiesaccordingly andreran diffcheck, docchecker23/23, guardrails/precommit successfully. No sourcechangedafterreview.

Proceed with the controller-only scope reduction above as one coherent inactive Step4d3b. Reuse existing reader semanticprojection and deterministicrowidentity; do not copy algorithms or mint importreceipt/cursorforliveoutput. Corecompanion andownerhandling mustlandtogether. Controllerlaunchlatch resets onlyonrealproducerreplacement. Existingownersave capturesrow+proof orproofinvalidation coherently; no immediatedurabilityclaim. Conservativeowned-conversation invalidation clears typedandrawdigest, preserveskeys/rows/unknownmembers, neverhealsfromduplicate. Recognizedsuccessresult stillrequires exactfinaltextagreement, including suppressed/emptytranslated cases. Unsupported/non-success/abort/partial/tool/thinking/multiblock/unknownsemanticoutput remainslegacyvisible anddisqualifies.

The worker mustinspectexistingturn/backgroundownership beforepositivequalification; where exactownedturn cannotbeestablished, refuseidentity ratherthanguess. No newpersistentmap, tool-IDchange, automaticresend, providerprompt, privatecapture/configread, app/helper/lifecycle action, packageDTO or bridgechange. Injectedqualificationdefaultfalse withnoproductioncaller; existingregistry/Resume/restartgatesunchangedOFF. Tests are sourcefixturesonly. Any genuinelynewauthority/durabilityrequirement comesbacktomain beforeexpansion.

Step 4d3b worker evidence: [phase4d3b-worker.md](phase4d3b-worker.md). Initial review findings, verbatim: [OracleA](phase4d3b-review-oraclea.md), [OracleB](phase4d3b-review-oracleb.md).

## Step 4d3b initial review and repair scope

Main read the entire 106939-character staged 11-file source/test diff (+1681/−3), frozen as 2026-10-23/2349. Independent fresh A/B initial reviews returned the expected explicit preset identities; main read both full replies. A R1/P1 identifies missing owner notification for direct disqualification, and A R2/P1 identifies unclassified EOF-flushed payloads. Both are accepted for repair by the same Pair; B F2 describes the same EOF defect. No P1 is downgraded or rejected.

B F1 is retained as an activation blocker, not owner acceptance: conservative proof clearing can permanently refuse later recovery even for ordinary unsupported tool/steering output. Keep this inactive slice and the already-selected no-new-map architecture; do not enable the flag or claim the complete Claude profile. B F3 requires checking the existing reconcile commit fence and correcting its stale comment. Cheap B F5/F6 consistency/session guards and F7 test clarification are in scope. B F4 real-forwarder coverage is requested only if an existing harness makes it small; otherwise it remains explicitly required before activation rather than new test tooling. All gates remain OFF.

Main independently verified initial tickets: qualification7/7 (7bfd7cca), reader35/35 (2d467b75), lifecycle197/197 (00327396), reconciliation45/45 (c680050c), usage16/16 (64bba687), compile1b393a5f, formatf5d8e23e, lintd01baa19. These are fixture/source checks, not live qualification.

## Step 4d3b re-review 1 snapshot

The worker completed the repair; no worker remains running. Main inspected the entire six-file repair and the final controller adjustment. The frozen delta is `2026-10-24/0010` (+328/−8), relative to the staged initial snapshot. Main confirmed the existing history-only merge compares `providerHistoryRecovery` with `ledgerAtStart` after its read, so the suspected overwrite already refuses. The real controller-to-runner-to-owner regression now covers insertion and later malformed-line/EOF proof invalidation. The fatal decode path refuses before its shutdown await; an overlapping replacement starts disqualified, and the old EOF drain cannot select or retire its state. Mid-drain replacement is source-inspected, not directly fixture-tested.

Main independently verified final compile (50636fda), qualification 8/8 (3493e42c), lifecycle 199/199 (272ce871), usage 16/16 (d62bd435), format 0/2177 (de6387c8) and lint (5f87c72c). Reader 35/35 (3fc21435) and reconciliation 45/45 (ed99d0ec) passed before the last controller-only adjustment and were not rerun afterward. Main also ran the agent-context checker and its 23 tests, guardrails, diff whitespace checks and the pre-commit hook successfully; the existing route-count warning remains. Full-suite, packaging, live provider, visible app and final acceptance were not run.

Fresh independent A/B re-review 1 was sent together on that delta with the full policy. A received only its own R1/R2 verbatim and the repair disposition; B had no open P0/P1 and received a regression-only request. Results were pending at this note's creation. No source changes will be made while review is pending.

## Step4d3b first-pass integration findings

The firstworkerpass compiled andreported fivegreensuites (qualification6, reader35, lifecycle198, reconciliation45, usage16); main has notyetverifiedallfinaltickets orruninitialreview. The newtestdrain initiallyhitthe180sdeadline because directconcreteactor calls selected asyncprotocoldefault marker/subscriptionmethods; testsnowusetheprotocolinterface asproductionrunner does, withgenerationcheck. Temporarydiagnosticsremovedperworker; finalverificationwillcheck.

Mainreadall363classifierlines, VMdelta andworkerevidence, thenfound the qualifier requireduserreplay whileactualcontrollerarguments3880–3887 omit --replay-user-messages. Main requires optionalcorroboratingreplay, unchangedCLIargs andpositivecurrent-ownedoutbound attribution for no-replay output; providedcallerUUIDattributes mustmatch ratherthanonlytypecheck. Main's additionalofflineallowlistchecks ofexistingO19copies verifiedassistant/resultcallerUUIDattributesand singletonarrays matchthecaller, input_transformations andpermission_denials areempty, terminal_reason=completed,stop_reason=end_turn,safety_stops=0. No newprompts. Theworkerwillalsofailclosedon nonemptytransformations andunknowninit/resultkeys usingobservedkeysets. Maincutsbothaddedtool_resultguardsandtheirtest asoutside thesingletextgoal; pendingtool finalizationremainsunchanged andtoolqualificationexplicitlypending. Existingcanonicalpayloadchecks stilldetectchangedtoolrows. AllClaude-proof invalidation scope, suffix-onlylate-duplicate refusal andpresavecrashwindow remainexplicitboundedlimits, notnewauthorities.

## Step 4d3a completion

Step 4d3a is done for its bounded source scope only, committed as `60132a4b8b8d83c3e21804452a98bc18b396c7cf` under the authorized unsigned option.

**Re-review 1.** Re-review 1 (verbatim: [OracleA](phase4d3a-review-oraclea-r1.md), [OracleB](phase4d3a-review-oracleb-r1.md)) returned the exact verified A/B preset identities. Both lanes closed the P1 (A R1/B F1) and found no new P0/P1. B's two new P3s are deferred with no action, and no P3-only review loop will run:
- the nil-normalizer fallback in the turn-copy tool-name check;
- the doc comment on the mostly redundant claimed-anchor order.

**Contract.** The canonical payload preflight is bounded. Provider output and user anchors are order-checked separately, following option (a), which keeps the append-at-end import contract. Turn copies also accept the builder's normalized tool name.

**Main's reading.** Before the reviews, main read the entire 65093-character staged 8-file initial diff and the whole 2-file repair delta (+147/−29).

**Latest validation:**

| Suite or check | Result | Source state |
|---|---|---|
| Reconciliation | 43/43 | repair delta |
| Reader | 34/34 | initial snapshot; reader sources unchanged by the repair |
| Owning lifecycle | 195/195 | initial snapshot; lifecycle sources unchanged by the repair |
| Compile, format-check, lint | passed | repair delta |

Step 4d3b source is implemented and reviewed; broader provider qualification, production activation and live acceptance remain pending (O3). All gates stay OFF.

## Step 4d3b completion and remaining boundary

Subsequent source correction: [Step 4d3c](phase4d3c.md) supersedes the all-tab proof-clearing rule below with transient per-producer owned-key invalidation. Its evidence also records the hydration lifetime correction. Earlier limitations below describe the Step 4d3b checkpoint, not the updated scoped rule.

Both re-review 1 replies returned the expected explicit A/B preset identities; main read them in full. [OracleA](phase4d3b-review-oraclea-r1.md) closed R1/R2 and [OracleB](phase4d3b-review-oracleb-r1.md) found no P0/P1 regression. No contest remains. The source snapshot is unchanged after re-review. Main reran both carried-over suites on the final source: reader 35/35, ticket `aae1fb1f-2992-4567-a43f-939e5105e67c`; reconciliation 45/45, ticket `86bd89f0-aefd-41e8-8c6d-2cff510a6635`. Both coordinated commands completed with exit 0.

Deferred, with no further review round: A R3 deterministic replacement-during-drain coverage; B R1-P2-1 conversation-ID ordering as another trigger of all-tab proof invalidation; B R1-P3-1 projection reuse, R1-P3-2/3 additional drain comments, and R1-P3-4 tighter test-local time bounds. These are activation/coverage or optional polish, not grounds to expand this inactive step. The existing conductor deadline still bounds a test hang. The owner requested optional polish be deferred. Initial B F1 remains an activation blocker: ordinary unsupported output can invalidate every Claude proof and prevent later recovery. No owner acceptance of that limitation is inferred.

This completes only the bounded inactive single-text source slice. It does not complete Phase 4 or qualify installed Claude tools, thinking, multiblock, resume or fork. Further credentialed capture was not approved after the earlier question timed out; all four previously approved prompts are consumed. Default-context managed-hook/additional-directory confinement is still unproven. No more prompts, credential inspection or visible app lifecycle actions ran. Keep recovery/registry/Resume/restart activation OFF and final live acceptance pending. The next dependent action is a renewed, explicitly bounded provider qualification capture; do not substitute fixtures for that evidence.

The earlier diagnosis remains specific: all attempts used `/Users/tnguyen/.local/bin/claude`; the dedicated worker found a non-default inherited `CLAUDE_CONFIG_DIR`, and the owner-approved child-only removal produced a real ALPHA-7 reply. No global environment, account, settings or product launch configuration was changed. Its notes and controlled evidence are checkpointed in `3fd836a9`.

Before checkpointing, main inspected all staged source through the initial full diff and complete repair delta, then the complete 76383-character eight-file documentation/guardrail diff. That final read caught a missing newline between two plan status lines; only that formatting was repaired. The final intended set is 19 files. Main reran the context checker (existing route-count warning only), its 23 tests, guardrails, whitespace checks and pre-commit successfully. No source changed after A/B acceptance. Use the owner-authorized unsigned option (O8); no new signing attempt, identity/configuration change or push is required for this checkpoint.

Checkpoint: `f6f205e5433fdcad09d3a8195957272fc5fbf29b` (`Add inactive Claude live transcript identity qualification`), unsigned as authorized, contains the 19 intended files. No push occurred and only the original unrelated working-tree changes remain. A strict byte comparison of the review copies failed because each evidence file adds one conventional terminal newline absent from the export. The shell command did not gate the commit on that assertion, so the checkpoint proceeded. A follow-up comparison confirmed all four responses are exactly equal after removing terminal newlines; no finding text differs. This is a documentation-format difference, not an unreviewed source change. No workers remain running.
