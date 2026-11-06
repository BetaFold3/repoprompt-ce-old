# Inline charts and newspaper briefings — technical spec

Scope: read when the task touches opt-in rich presentation tools, inline charts or newspaper briefings, approved-host article images, or durable rich transcript artifacts.
Authority: Reference
Last-verified: 2026-11-04

## Goal and status
Let an assistant gather information with its existing tools, then publish attractive line/bar charts and complete newspaper briefings directly in Agent Mode's transcript. Existing content remains readable offline and after restart.
**All five implementation steps are complete; live reacceptance passed for Claude/Codex/OMP publication, responsive inline layout and restart retention, with remaining validation gaps accepted by the owner.** OracleE and OracleD received identical initial evidence/policy, then two argument-exchange rounds. One material disagreement remains (D1). Step counters below now record implementation re-review rounds.
Evidence directory (local, ignored, not committed): `docs/investigations/2026-11-04-rich-presentation/evidence/`. It contains scouts, exact requests/replies, finding dispositions, and documentation-check results; none belongs in this spec.
Follow the [review policy](../review-policy.md) and [validation workflow](../workflows/validation.md). Automated and live validation, owner-accepted gaps and advisory review deferrals are recorded in the evidence directory.

## Decisions
- The owner requires both charts and complete briefings fully inline, not Preview-only.
- The owner selected line and bar charts for the first version.
- The owner requires app-fetched optional remote article images.
- The owner selected workspace-specific enablement, off by default, effective next agent run.
- The owner accepts exact approved image hosts configured per workspace, including residual DNS/TLS/proxy trust; an empty list yields placeholders.
- The owner requires independent copied/branched conversations to retain artifacts after source deletion.
- The owner includes all trusted local Agent Mode runs, including workers, Explore and Knowledge; general external MCP clients are excluded.
- The owner requested a technical spec, not implementation.
- On 2026-11-05, the owner chose bounded storage support: refuse rich creation and artifact-bearing handoffs when resolved workspace and session storage disagree, accept the resulting global-custom-storage limitation, and leave existing session persistence unchanged (D2).
- On 2026-11-05, the owner deferred live acceptance and chose to leave the current Dev app untouched; provider/UI/restart and advisory performance checks remain unverified (D3).
- On 2026-11-06, the owner reported rebuilding/relaunching, confirmed workspace Rich Presentation enabled with empty approved image hosts, and approved Claude/Codex/OMP live acceptance sessions.
- On 2026-11-06, the owner chose to rebuild/relaunch the daily integration app with the reviewed Step 5 fixes before live reacceptance.
- On 2026-11-06, after confirming responsive layout, restart retention and OMP operation, the owner accepted the documented remaining live-validation gaps: Knowledge-profile output, creation-disabled history, independent handoff/source deletion, and matched long-history/performance comparison.

## Non-goals
No scraping/scheduling, arbitrary HTML/JavaScript, WebKit changes, MCP Apps hosting, general structured-result migration, new branch UI, or native Codex conversation-branching implementation. No background image refresh, redirects, authenticated downloads, automatic retries, animation/SVG, advanced chart types, embedded briefing charts, new export formats, or cross-session shared assets.
These cuts keep the increment about presentation; acquisition remains the assistant's job, and one native renderer avoids webview height/navigation machinery.

## Interfaces and admission
**A1 (assumed):** one `present_rich` tool with two typed variants; SwiftUI newspaper composition and Swift Charts, pending a first compilation check. Plain-text content avoids executing or interpreting agent markup.
```text
Source = {label: string, url?: HTTPS_URL}
ImageRequest = {url: string, alt: string, credit?: string}
Chart = {kind: "chart", chart_type: "line"|"bar", x_label: string, unit: string,
         x: [string], series: [{name: string, y: [number|null]}], sources: [Source]}
Article = {headline: string, body: string, sources: [Source], image?: ImageRequest}
Briefing = {kind: "briefing", date: YYYY-MM-DD, deck?: string,
            sections: [{heading: string, articles: [Article]}]}
Input = {version: 1, title: string, content: Chart|Briefing}
Reference = {version: 1, artifact_id: UUID, kind: "chart"|"briefing", title: string,
             fallback_text: string, warnings: [{section_index: int, article_index: int, code: string}]}
Result = {presentation: Reference}
```
The input is an object, not JSON-in-a-string. Return the reference JSON through the existing text-result mechanism; do not depend on MCP `structuredContent`. Decode only verified tool-result/ACP wrappers, never artifact-looking assistant prose.
**A2 (assumed schema/limits):** reject unsupported versions/fields and malformed data before downloading. Limit serialized input to 256 KiB; title/headline 160 characters; labels 120; deck 1,200; body 12,000; URL 2,048; alt/credit 240; 1–4 sources per chart/article; 1–6 sections, 1–12 articles total, and at most four image requests. Reject excess with field-specific recovery, never silently truncate accepted content.
Charts have 1–4 uniquely named series and 1–512 x values; y lengths match x, numbers are finite, and each series has a non-null value. Line x values are RFC 3339 timestamps strictly increasing by actual instant, plotted with real temporal spacing and labeled UTC; nulls break lines. Bar x values are unique ordered categories; bars are grouped with a zero baseline. One unit, linear scale, no smoothing or mixed axes prevents misleading trends/comparisons.
All visible strings are plain text; require nonempty titles, headings, headlines, bodies and source labels, preserving paragraphs and article order. Source URLs are optional for local benchmark evidence (do not invent links); when present they require HTTPS without userinfo and open only on user click through the existing external-link handler. Failed image requests do not invalidate the article's text.
The app generates a clearly labeled fallback summary of at most 2 KiB; it is not the full document. Fatal errors use the existing MCP error envelope with a named cause and correction: denied, invalid context/input, busy, cancelled, storage moved/failed. Successful results never point to an incomplete artifact.

## Authorization and publication
**A3 (assumed attempt semantics):** store workspace `{enabled, approved_image_hosts}` in `GlobalSettingsDocument` through its existing save/error policy; absent fields mean false/empty. Only Settings edits host approval, not this tool. Failed settings saves do not silently enable permissions.
Capture both values in existing in-memory run-attempt/lease state. A newly admitted attempt resamples, even if Claude reuses the same process run ID; same-attempt reconnect/steering keeps the snapshot. Cold recovery admits a new attempt. Unprovable authority refuses rich creation with “Start a new agent run”; no new persisted policy store.
Grant a dedicated capability through existing listing AND call checks, Knowledge allowlist and Explore advertisement. General external/unbound/Oracle clients receive no grant. Worker output belongs to its own persisted session; no automatic publication into the parent.
Resolve workspace/session/attempt/tool-call identity from the trusted bound connection and exact session, never arguments, selected-tab fallback, or a caller-supplied path. Revalidate originating attempt, session tombstone and storage identity before publication to prevent wrong-session or deleted-session writes.
**A4 (assumed publication/lifetime):** one bounded call validates, fetches optional images, stages the complete immutable artifact and atomically installs it before returning a reference. Network/decode work stays outside the session gate and off the main actor; coordinate final install with the existing session deletion gate. Preserve existing cancellation/watchdog handling.
Allow two publication jobs app-wide; excess returns busy rather than an unbounded queue. Run cancellation/deletion cancels work; preference changes do not revoke an admitted attempt. Discard late decode results; no post-publication image mutation.
No automatic retry or deduplication ledger: a lost reply has uncertain publication, and a deliberate new call may create another artifact. Tell the agent to inspect the transcript rather than blindly resend. Clean the current failed staging operation; crash residue may remain until session deletion, with no background sweeper or power-loss/fsync guarantee.

## Article image boundary
Exact approved lowercase ASCII DNS hosts only: reject wildcards, IP literals, localhost/local and single-label names, ambiguous authority/userinfo, non-HTTPS schemes and ports other than absent/443. Approval of an article host does not approve its CDN. Fetch only explicitly supplied image URLs.
Use a dedicated isolated ephemeral transport: no cookies, credential storage, disk cache, Authorization, Referer, workspace identifiers or agent-selected headers; normal TLS verification, no other authentication challenges, no redirects, HTTP 200 only.
This trusts approved hosts and the Mac's DNS/TLS/proxy routing; it does NOT establish public-address confinement. No DNS-preflight safety claim or custom connection-pinning stack. Settings discloses that publishers receive the source IP and full path/query; diagnostics redact queries.
**A5 (assumed safety bounds):** two downloads and one raster decode app-wide; 4 MiB streamed/decompressed bytes per image, 16 MiB aggregate per artifact, and a 20-second image-phase deadline. These contain stalls and memory spikes; they are configurable design limits, not measured SLAs.
Verify complete single-frame JPEG/PNG using ImageIO, actual format and compatible MIME; reject other formats, animation, truncation and overflow-checked dimensions above 24 million pixels. Off-main, downsample to a 1,600-pixel longest edge, normalize to metadata-free sRGB JPEG on white, cap output at 4 MiB, and discard originals. No unrestricted decoder fallback.
Record either local asset ID/dimensions/alt/credit/origin or a terminal failure code: invalid_url, host_not_approved, redirect_rejected, fetch_failed, deadline, too_large, invalid_image. Preserve signed query bytes only during the request, not in stored manifests. A failed image shows a labeled placeholder while all accepted text remains.
An executing native decode retains its concurrency permit until it finishes even after cancellation, preventing repeated cancellations from exceeding the bound.

## Storage, transcript and copies
Use `<resolved workspace storage>/agent_rich_artifacts/<sessionID>/<artifactID>/` for a versioned manifest and generated image filenames. Manifest stores validated content, terminal image outcomes and originating attempt/tool-call provenance. References resolve relative to the containing session; no absolute or source-session paths. Reject escaped/symlink asset paths on reads.
Retain published artifacts until their session is deleted; no automatic successful-artifact eviction, shared ownership, hashes or session quota. Disk failure is explicit and existing artifacts remain intact. Tombstone-first deletion removes only that session's tree, including residue; late completion must not recreate it.
Add default-empty ordered `richPresentations` to the existing `AgentTranscriptTurn`: bounded Reference plus original activity ID/order and artifact ID. Capture before destructive compaction and retain across all tiers. This field, not raw tool results or memory sidecars, is the durable presentation authority.
Normalize supported text/ACP results to the small versioned reference through sanitization until capture; no blanket raw-payload bypass or pipeline-wide reorder. Repeated sanitization/capture must be idempotent. Rebuilds and handoff migration retain turn references even when original tool activities are gone.
Derive exactly one outer rich block from each retained reference, outside collapsed activity groups; preserve its original order and stable session/activity/artifact identity. Suppress duplicate success-card content; retain existing progress/errors. Model replay/text-only consumers receive the labeled summary, not complete document reinjection.
In `prepareHandoffHeadless`, after destination identity allocation but before migrated transcript exposure, independently copy artifacts selected by the handoff cutoff, including compacted references. Filesystem copy-on-write is acceptable; source-dependent links are not. Same-session duplicate tabs remain shared, not independent copies. Future native branching must use this contract, but is not implemented here.
**D1 provisional recommendation:** if copying a required artifact fails, abort that handoff with repair/retry guidance, keep the source unchanged, and remove unpublished destination residue. Do not replace a complete briefing/chart with its short fallback. This choice remains contested after two rounds.
Existing whole-workspace moves carry the tree; invalidate cached roots on move/rename and revalidate storage identity at commit. Refuse publication if storage changed mid-call instead of recreating the old root. No new migration subsystem.

## Inline presentation
**A6 (assumed UI):** a native full-content block with a newspaper masthead/date/deck, section headings and ordered article rows; two columns at widths ≥760 points, otherwise one. Charts use a 300-point plot, legend, units/UTC label, source links and accessible data. Preserve text selection and theme/accessibility behavior.
No ten-line collapse, pagination, nested scrolling or inner lazy stack. Existing transcript scrolling owns navigation. Load immutable manifests and local images off-main, reserve image geometry from stored dimensions, and use a cost-bounded decoded-image cache; never fetch on render/reload.
Missing/corrupt images show placeholders; missing/unsupported manifests show title, labeled fallback and restore/republish guidance. Disabling creation never hides history. Unsupported older binaries have no promised rich-data write-round-trip compatibility; preserve session files and artifact trees together before downgrade.

## Implementation steps
Paths below abbreviate `Sources/RepoPrompt` as App and `Sources/RepoPromptAgentCore` as Core. Proposed tests are not existing validation evidence.
### Step 1 — Types, settings and attempt authority
- Change: Core models/validator; App `GlobalSettingsDocument`/`GlobalSettingsManager` and workspace Settings; run-service, Claude/Codex attempt/lease inputs; dedicated capability, gated tools, Knowledge/Explore rules. Compile minimal native chart integration to avoid an unproven renderer dependency.
- Validation: proposed `RichPresentationPolicyTests` and schema cases cover missing fields/save failure, all profiles, direct-call denial, reused process ID with a new attempt, reconnect and mid-attempt edits; `make dev-swift-build PRODUCT=RepoPrompt` proves Charts linkage.
- Done when: settings, advertisement and execution agree for each attempt; no active-tab fallback or retroactive host changes.
Step 1 — done | rounds 1/2 | open: none | downgraded: none | assumed: A1,A2,A3 | deferred: advisory P3 follow-ups and Step 4 activation checks in step1-dispositions.md
### Step 2 — Bounded image acquisition
- Change: App image-fetch service using existing HTTP injection/isolation patterns and ImageIO; Core value outcomes. No changes to preview network policy.
- Validation: proposed `RichPresentationImageFetcherTests` covers exact hosts, redirect/auth isolation, deadline/cancellation, lying lengths and byte/pixel/format boundaries; controlled transport fixtures distinguish actual URLSession behavior from mocks.
- Done when: failures yield terminal placeholders, text survives, and no unbounded or post-publication work exists.
Step 2 — done | rounds 1/2 | open: none | downgraded: none | assumed: A4,A5; strict no-trailer images | deferred: entropy-corruption and live transport limits in step2-dispositions.md
### Step 3 — Durable publication and independent copies
- Change: Core artifact service/store at `AgentSessionDataService` storage/deletion gate; trusted MCP owner resolver; App handoff and root-change seams. No dependency on concurrently changing document-attachment work.
- Validation: proposed `RichPresentationLifecycleTests` covers partial writes, deletion/cancellation/storage move during fetch, worker-session reload, compacted-cutoff copy then source deletion, copy failure, and custom-storage movement.
- Done when: bytes precede references, copies survive source deletion, no late task recreates deleted/stale storage, and D1's copy-failure behavior is settled.
Step 3 — done | rounds 2/2 | open: none | downgraded: none | assumed: A4 | deferred: D2 storage limitation, native branching, advisory findings and Step 4 gates in step3-final.md
### Step 4 — Tool and complete inline history
- Change: `present_rich` provider via `MCPWindowToolRuntime` with freshness none; canonical names/group/catalog, capabilities/grants, admission/execution contracts and recognition; Core turn model/sanitizer/compactor; App outer block renderer. Advertise only once storage and full-inline retention are integrated.
- Validation: `AgentToolResultPersistencePolicyTests`, `AgentTranscriptGroupInspectionTests`, catalog/admission tests and one end-to-end fixture: publish → sanitize twice including ACP → save → all retention tiers → reload → render exactly once, with missing assets and creation disabled.
- Done when: complete content stays outer-inline with stable ordering and no historical network traffic or duplicate success body.
Step 4 — done | rounds 1/2 | open: none | downgraded: none | assumed: A1,A2,A6; existing outer history reveal | deferred: advisory findings and live acceptance in step4-final.md
### Step 5 — Acceptance and durable guidance
- Change: fix only observed integration defects and update this owning spec's status/contract; keep raw evidence outside it.
- Validation: affected `make dev-test FILTER=<Suite>`, `make dev-lint`, product build and `make guardrails`; context checker plus its negative suite. With immediate owner approval, exercise Claude/Codex/OMP tool refresh, worker/Knowledge output, long history, resizing, selection, restart, handoff and image denial in the Dev app.
- Done when: full-inline normal use works and required security/data-retention checks pass; record provider/live gaps honestly. Compare scroll/layout/memory behavior against a text baseline under matched conditions, report uncertainty on the noisy host, and let the owner accept advisory results.
Step 5 — done | rounds 0/2 | open: none | downgraded: none | assumed: A1–A6; 760-point content width | deferred: owner-accepted validation gaps in step5-reacceptance-2026-11-06.md; hosted wiring test in step5-dispositions.md

## Disagreements
- **Resolved:** native rendering and one tool replace the proposed chart/WebKit split; full-inline layout needs no webview sizing lifecycle.
- **Resolved:** owner-selected approved hosts avoid arbitrary-origin networking; independent copies and all local profiles replace origin-dependent copies and profile exclusions.
- **Resolved by source:** attempts, not process IDs, own policy; durable turn references survive compaction. Cut policy files, dedup ledgers, raw archives, fsync and speculative input adapters.
- **D1 unresolved after 2/2 rounds:** one position favors continuing a handoff with a loud fallback to avoid blocking it; the other refuses an incomplete destination to preserve the full result. Recommend refusal: the fallback is a short summary, not the lost chart data or briefing. Only Step 3's failure behavior waits on this choice.

## Open Questions
- **D1:** owner choice remains between degraded handoff and abort/retry; provisional recommendation is abort/retry, not an owner Decision.
- **assumed A1–A6:** one tool/native renderer; plain-text versioned schema, UTC/grouped chart semantics and listed limits; per-attempt policy boundary; immutable within-call publication/session lifetime with no auto-retry or eviction; JPEG/PNG-only bounded normalized images; stated responsive layout/cache and downgrade limitation.
- No image hostnames were supplied; the initial list is empty and the owner adds actual publisher/CDN hosts in Settings. This does not block charts or text briefings.
- First Charts compile, actual tool-wrapper fixtures, same-attempt provider catalog refresh and live full-inline behavior are implementation gates, not established capabilities.
