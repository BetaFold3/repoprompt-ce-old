# Agent Provider Plugin Seam

Current as of 2026-09-15. This document is contributor-facing: use it when you are wiring a new autonomous-agent provider, editing the Claude-compatible runtime, or moving code across the core ↔ plugin boundary.

## Scope and goals

RepoPrompt CE keeps a small, provider-neutral runtime contract in the app and pushes provider-specific protocol/codec/runtime logic into a Swift package product. The first plugin product is `RepoPromptClaudeCompatibleProvider`, which owns the Claude-compatible family (Claude Code, GLM/Zai, Kimi, custom Claude-compatible). The seam preserves:

- public `AgentProviderKind` raw values;
- `AgentProviderBindingID.claude` settings/permission grouping;
- persisted `AgentModel` raw values, option ordering, and provider defaults;
- secure permission documents in `AgentPermissionSecureStore`;
- `.claude` legacy/mirror keys for tool/permission settings.

The seam intentionally stops short of dynamic plugin loading. It is static SwiftPM composition and an internal DTO-based plugin API.

## High-level layering

```
+-------------------------- core (RepoPromptApp target) --------------------------+
|                                                                                |
| AgentMode/UI · transcript · tool tracking · MCP permission · run state         |
|     │                                                                          |
|     │  NativeAgentRuntimeControlling (provider-neutral core contract)          |
|     ▼                                                                          |
| ClaudeCompatibleNativeSessionAdapter ─┐                                        |
| ClaudeCompatibleHeadlessProviderAdapter ├─ Agent Mode adapter trio             |
| ClaudeCompatibleModelCatalogAdapter ──┘                                        |
|     │                                                                          |
|     │  ClaudeCompatiblePluginBridge (feature bridge / Agent-Mode mappings)     |
|     │                                                                          |
|     │  ClaudeCompatibleProviderRuntimeBridge (infrastructure / package import) |
|     ▼                                                                          |
+--------------------- package (RepoPromptClaudeCompatibleProvider) -------------+
|                                                                                |
| Plugin DTOs · prompt delivery · environment builder · catalog · headless args ·|
| launch env resolver · Claude SDK codec/translator (pure logic)                 |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Two thin facades sit between core and the package so lower-level infrastructure files (for example `ClaudeCodeLaunchEnvironmentResolver`) do not depend upward on Agent Mode:

- **`ClaudeCompatibleProviderRuntimeBridge`** (`Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`) is the single core import point for `RepoPromptClaudeCompatibleProvider`. It owns the package's type aliases, DTO conversions, and pure runtime helpers (prompt delivery, environment building, model normalization, headless argument construction, launch-environment resolution, catalog snapshots, stream-result mapping).
- **`ClaudeCompatiblePluginBridge`** (`Sources/RepoPromptAgentCore/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`) is the Agent-Mode-facing facade. It maps `AgentProviderKind` to the package's `ClaudeCompatibleProviderPluginID`, derives availability, builds runtime configs from Agent Mode / discovery contexts, and forwards every other helper to the infrastructure bridge.

Anywhere outside these two files, core code interacts with Claude-compatible plugin DTOs through one of the bridges, not through a raw package import.

## Static dependency setup

The provider package lives in-repo at `Packages/RepoPromptAgentProviders/` and is composed into the root manifest with SwiftPM's path-dependency form:

```swift
// Package.swift (root)
.package(path: "Packages/RepoPromptAgentProviders"),

// RepoPrompt executable target dependencies
.product(name: "RepoPromptClaudeCompatibleProvider", package: "RepoPromptAgentProviders"),
```

The package itself exposes a single library product today:

```swift
// Packages/RepoPromptAgentProviders/Package.swift
products: [
    .library(
        name: "RepoPromptClaudeCompatibleProvider",
        targets: ["RepoPromptClaudeCompatibleProvider"]
    ),
],
```

The package target is Foundation-only and intentionally does **not** import any RepoPrompt app code, persistence layer, or secure storage.

### Test commands

Use coordinated root commands so provider work shares the repository build/test lanes:

```bash
# Root app build and tests (includes the package transitively)
make dev-swift-build PRODUCT=RepoPrompt
make dev-test

# Package-only tests (faster iteration on codec / translator / catalog DTOs)
make dev-provider-test
```

If the developer daemon is unavailable, use the direct SwiftPM commands documented in the [development workflow](../context/workflows/development.md).

### Claude output between runs

A Claude process outlives the run that started it and can resume on its own after a
successful result, for example when a background task finishes. Before 2026-10-11 the
integrated runner's per-run consumer stopped reading the controller's event stream at
completion, so that output stayed buffered until the next user send and then appeared under
the newer user message.

`ClaudeNativeEventRouter` (`Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/`) is now
the single long-lived reader of each controller stream for a tab. It dispatches strictly in
stream order, and each event belongs to the run that was current when the controller emitted
it. A run becomes current at its in-band start marker: just before sending the run's message,
the runner asks the controller to yield `.marker(attemptID)` on its events stream
(`emitEventMarker`), so output emitted earlier is never the run's, even if the app reads it
after the run started. A live run's marker starts it on whichever router reads it, including
one created after the run registered. Runtimes without markers (no stream generations) fall back
to the moment the runner resolves the run's start, still before its message is sent. Routing:

- an event owned by the consuming run goes to that run's handler;
- an event owned by a run whose task is still alive and not released (starting, sending, or
  finalizing) waits for that run, as the stream buffered it before;
- an event owned by no live run is between-run output. It goes straight to the transcript
  through the view model's background path (`handleBackgroundNativeStreamResult`), which
  appends and saves rows but changes no run state, running or reasoning status, or per-turn
  usage finalization. This holds even when a newer run is already consuming: old output is
  never handled as the newer run's response. Background text is applied at once to that
  message's own rows (its streaming row, or the row an interleaved system row ended), never
  through the shared assistant-delta buffer, and its `final_content` replaces only that row,
  never an earlier turn's answer. Every row a background delivery appends (assistant, system,
  tool, error) is recorded as background-owned, and each delivery's lookups skip the other's
  rows of any kind: a run's stream events never continue, replace, or end a background row,
  even one that landed below its user row, and background events never end or split a run's row
  (also before any background row exists). Runtime errors read between runs take the same path.
  A name-only tool-result match stays within its delivery. A background message's current row
  is tracked by identity, not streaming state, so its further text and `final_content` still
  reach it after an interleaved system row or a run's terminal finalization ended its streaming.
  Current rows are kept per source event stream: each router carries its own source ID (one
  stream, one provider launch), every background row records its source, and only output from
  that stream continues, replaces, or retires its row. Lookups skip another stream's rows, and
  one stream's segment end never ends another's row, so a draining router and the current one
  can deliver interleaved without splitting or duplicating each other's message. A run taking
  over a stream (the first event it owns dispatched from that router, in stream order; an
  approval request handed over from before its marker, or a cancellation following it, is not
  one) ends that stream's current message: the rest of it is the run's output. A newer user row
  also retires it. So background output after a newer prompt always starts a new row below that
  prompt and the run's answer, even when the old message's end never reached the background
  path (the process exited, or its end belonged to the next run), and output from a relaunched
  process never joins a row of the process before it. Between runs only the tab's current
  stream (`claudeAuthoritativeEventSourceID`, set when the runner installs a router) updates the
  provider session ID, from `runtimeInit` or `message_stop`: a replaced stream still draining is
  shown but never overwrites the newer launch's ID. The terminal finalization does finalize
  background tool calls still pending with the run's terminal state. Background rows are
  excluded from a run's completion-notification text;
- approval requests are never handled between runs. The router holds them, and everything
  after them, for the next consuming run, which owns approval state. A request cancelled
  before any run saw it is dropped with its cancellation, a cancellation follows the run that
  received its request, and a request still held when the stream ends is discarded with the
  dead process. Showing a between-run approval immediately is not implemented.

Right after the attention capture, the terminal commit barrier calls `releaseProviderOutput`:
the finishing run will not consume again, so output it still owns is shown at once instead of
waiting for its task to return (capturing first keeps background text out of the finished turn's
notification). Before a queued follow-up starts, the barrier also calls
`deliverProviderOutputBeforeFollowUp`: the runner drains routers whose stream was replaced,
emits a drain marker on the current stream and waits until everything before it was delivered,
so that output is shown above the follow-up's user row. A commit retried after a rejected
publication applies the same delivery before it starts the follow-up. Overlapping retries are
serialized by the barrier flag; a publication result is recorded only for the still-current
commit and never over a resolved one, so a losing retry's rejection cannot undo the owner's
acceptance. One commit consumes at most one queued instruction, because the follow-up's attempt
begins asynchronously and the commit stays current meanwhile; a retry of a commit whose
instruction was consumed delivers nothing more. A commit superseded by a newer run attempt
during publication or delivery records no result, skips delivery, starts no follow-up, and
leaves the flag to its new owner. The drain
returns early only when the current head cannot be delivered (an approval held for the next
run, or output of another live run); that is evaluated against current state, not the
processor's last pass.

Cancelling a run detaches it from the router without cancelling the stream's iterator. The
controller replaces its stream only after the old one finished (stdout EOF or shutdown), and
each stream has a generation. A run that is cancelled or superseded before it selects a router
finishes as cancelled without touching the tab's routers. When the tab router reads an older
generation than the subscribed one, the runner first waits for that router to read its finished
stream to the end (a router of a newer stream is never waited on), then reuses it if it
holds events of the subscribing run: when the process exits after the run's message was sent,
the controller emits the run's failure on the old stream before finishing it, and the next
subscription returns a new, empty stream. Such a reused router is only a prefix: if it ends
without the run's terminal event, the run continues on the subscribed stream. Other routers
keep delivering what their streams carry and are revived, never given a second reader, if
their stream becomes current again; output from a controller the tab no longer owns is
dropped.

Known residuals: the transcript is append-only. Output emitted after a run's start marker
belongs to that run, even if the provider produced it for an earlier background task, because
stream order is the only signal available. Output emitted after the user's new row was appended
but before the run's start marker (while the run acquires its lease) is between-run output shown
below the new row, and so is output of a cancelled run that the app reads only after the user's
next message.

The subprocess-free regression test is in
`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift`:
`make dev-test FILTER=AgentModeRunServiceLifecycleTests/testClaudeBackgroundOutputAppearsWithoutNewSendAndKeepsOriginalTurn`.
It drives the real controller, translator, runner, terminal barrier, and view-model stream
handler; only launch/control and user-message writes are faked. It does not reproduce the
incident's prolonged catch-up latency, and live-app behavior has not been verified. The same
file covers a process exit before the run subscribes, continuation on the subscribed stream,
background output during an active run's status, background `final_content` across a system
row or a run's terminal finalization, segment and row isolation between a run and interleaved
background output, between-run runtime errors, and runs never merging into background rows
below their user row. Ownership, marker, approval, and drain rules
are covered by `ClaudeNativeEventRouterTests` in the same directory. The barrier's capture,
release, delivery, and follow-up order, including retried, overlapping, and superseded commits
and one follow-up per commit, is covered in `AgentModeRunServiceLifecycleTests`; exclusion of
background rows from completion notifications is covered in
`AttentionNotificationAdmissionTests`.

### Future external repository

When the provider package is later moved to its own repository, the plan is:

1. Replace the path dependency in the root `Package.swift` with a versioned remote dependency:
   ```swift
   .package(url: "https://github.com/.../RepoPromptAgentProviders.git", from: "x.y.z"),
   ```
2. Document a SwiftPM/Xcode local override for sibling-checkout development rather than re-introducing a required `.package(path:)` in the shared manifest. Two equivalent override options:
   - Xcode → File → Add Package Dependencies → Add Local… pointing at the sibling checkout (Xcode-only override).
   - `swift package edit RepoPromptAgentProviders --path ../RepoPromptAgentProviders` (writes the override into `.swiftpm/`).
3. Keep `Packages/RepoPromptAgentProviders/` in the open-source repo as long as it is the canonical staging location; once split out, mirror updates with versioned releases instead of in-tree edits.

The remote-by-default policy avoids breaking checkouts that do not have a sibling clone, while still giving contributors a low-friction local edit workflow.

## Core vs plugin ownership

| Concern | Owner |
| --- | --- |
| `AgentProviderKind`, `AgentProviderBindingID`, runtime kind strings | core |
| Persisted settings (`UserDefaults`, secure store, `.claude` documents) | core |
| `ClaudeAgentToolPreferences`, `ClaudeCodeCompatibleBackendConfig`, `ClaudeCodeCompatibleBackendStore` | core |
| MCP permission policies, RepoPrompt MCP auto-approval, tool tracking | core |
| Agent Mode transcript mutation, tool-card UI, run-state ownership | core |
| Native process control (`ClaudeNativeProcessSessionController`) | core (this wave) |
| Provider-neutral runtime contract (`NativeAgentRuntimeControlling`) | core |
| Provider-neutral RepoPrompt workflow prompt catalog and renderers (`RepoPromptAgentCore/AI/Prompts/Workflows`) | core |
| Headless wrapper (`ClaudeCodeAgentProvider`) | core (delegates pure rules to package) |
| `AgentModel` raw values, option DTOs, defaults | core (adapter forwards plugin DTOs back to these) |
| Claude family grammar and persisted Anthropic models registry | core (`ClaudeModelFamilyCatalog`, `AnthropicAPIModelsClient`, `AnthropicDiscoveredModelStore`) |
| Dynamic point-release overlay | core; standard Claude Code only (package snapshot remains static; GLM/Kimi/custom catalogs excluded) |
| Plugin IDs (`ClaudeCompatibleProviderPluginID`), runtime variants, backend IDs | package DTOs |
| Claude SDK protocol codec and NDJSON translator | package |
| Prompt delivery rules (XML wrapping, system-prompt overrides) | package |
| Compatible-backend environment builder, removed env keys, no-model raw values | package |
| Launch-environment resolver (slot mapping, model normalization, GLM legacy aliases) | package |
| Headless CLI argument construction | package |
| Model catalog snapshot (string options, default raws, supported effort levels) | package |
| Stream-result DTO (`ClaudeProviderStreamResult`, `ClaudeProviderJSONValue`) | package |
| Usage observation companion (`ClaudeProviderUsageObservation` on `ClaudeProviderStreamResult.usageObservation`) | package; optional, trailing-default `nil`, raw optional counts plus envelope/request/parent-tool identity. Core mirror `AgentProviderUsageObservation` on `AIStreamResult`; the runtime bridge maps both directions. The package remains transport-only; session accounting is core-owned below. See the [usage accounting plan](../context/plans/2026-09-13-agent-usage-and-wait-efficiency-plan.md) §2.2 |

The package never touches `UserDefaults`, `Keychain`, or `AgentPermissionSecureStore`. Secrets and persisted backend configs are read in core, sanitized into plugin DTOs (`ClaudeCompatibleBackendConfig`, `ClaudeCompatibleLaunchEnvironment`), and handed to the package at launch/catalog time through bridge functions and provider closures.

## Claude session accounting and preservation

Phase 2 adds core-owned `AgentUsageAccumulator` under `Features/AgentMode/Runtime/Usage`, separate from context occupancy and `providerTokenUsageByTurn`. It is keyed by persistent RPCE session ID and tracks execution/turn identity, deduplicated request snapshots, finalized summaries and cumulative monetary segments. Qualified logic replaces authoritative totals rather than adding snapshots; unknown components and uncovered terminal work remain partial/unavailable. Monetary rejection does not discard independently accepted token totals or result identity. A turn that crosses a verified reset remains attached to its original segment: its tokens and result identity are retained, but its monetary observation is rejected rather than charged to the new segment. Closed complete segments with dispatched work require a usable baseline/latest checkpoint and a matching terminal result identity; no-turn segments are exempt. Reported cost conversion must exactly preserve the shortest-roundtrip numeric value, so positive underflow and rounding cannot manufacture measured zero. The first place wire precision can be lost is the package DTO boundary: `JSONSerialization` decodes long decimal literals (for example the captured cumulative cost `0.007236599999999999`) as `NSDecimalNumber`, whose `doubleValue` is not the nearest double, so `ClaudeProviderJSONValue(any:)` parses such values from their exact decimal text; the core controller then reads the nearest double and `exactCost(fromReported:)` restores the wire lexeme. Crash-restored open state is retired as interrupted/partial only under an explicitly qualified contract, and segment lookup stays scoped to the active execution and reset generation.

When a segment closes, any still-open turn in that execution/segment makes monetary coverage partial regardless of dispatch position. Crossed-reset monetary rejection also explicitly marks the turn's original segment partial without changing its accepted amount or checkpoint identity. This preserves incomplete coverage when an earlier outstanding turn finishes after a later turn supplied the last checkpoint, including token-only completion or interruption.

**Normal builds count provider-reported figures (Oracle decision 2026-09-15):** `AgentUsageQualification.productionClaude` is `.executionVerified` and `ClaudeNativeUsageContract.activeContracts` carries the runtime-semantics contract `claude-native.provider-reported.v1@2.1.268` (fresh launches at a verified zero baseline, resumed launches at an unknown/prospective baseline, `queued_turn_count` required and bounded at 0, cumulative cost continuing across a same-process compaction boundary). A version without a recorded contract qualifies for token observations only (`claude-native.tokens-only.v1@<version>`: per-result `usage` feeds the cache-hit share, the segment's monetary coverage stays `unavailable`, and no cumulative checkpoint is ever accepted), so unknown versions are never silently promoted to the monetary contract. The contract qualifies semantics, not provenance: the standard first-party provider path is required (compatible and explicitly alternate backends stay excluded), while wrappers, configured executables, environment override keys, code signatures, configuration fingerprints, credential categories and model/effort selection are recorded as diagnostics only and never gate figures. The ownership predicate remains end to end: the controller creates a `ProcessLaunchIdentity` at each successful spawn (token, PID, launch mode, command provenance, resolved and symlink-resolved executable paths, backend, and environment evidence derived from the final spawn dictionary — keys only, never values), binds stdout chunks/EOF to that launch token (input from a replaced process is discarded before framing), registers a launch-local dispatch ordinal only after a successful stdin write, and emits ordered evidence on a dedicated `usageAccountingEvents` stream (`launched`, `runtimeEvidence`, `runtimeBinding` (first `system/init` provenance, diagnostic only), `dispatched`, `counterBoundaryObserved`, live-only `mainRequestUsageAttributed`, `resultAttributed`, `turnClosed`, `blocked`, `launchEnded`). Every completion-lifecycle exit emits `turnClosed` on that stream after any attribution for the turn, and the transcript runner performs no accounting mutation, so closure cannot race a result. A raw result is attributed only when its `result_index` equals the next unattributed ordinal on the current launch after version and provider-session evidence; exact duplicates are no-ops and are not completion boundaries, conflicts/gaps/reorders/missing dispatches block the launch, and indices are never skipped. Result outcome, local commands, `subagent_stats` and `modelUsage` shape are evidence, not ownership: an original error/cancelled result that carries usage is attributed with its status and finalized as `.interrupted` with its accepted totals; an interrupt never ends attribution; a main-line `Agent`/`Task` tool use or `subagent_stats.spawned > 0` marks the result `childActivityObserved`, whereupon core accepts the parent-inclusive cumulative cost exactly once and excludes that result's token triple from the cache-hit share (turn coverage partial, never presented as proven main-loop scope). Core owns the remaining policy: an unexplained cumulative decrease suspends the segment as partial, a queue depth above the bound blocks as unsupported ownership, and the compaction command's zero token triple adds no denominator. Plain `shutdown()` keeps the reusable stream open; deinit cleanup emits a final `launchEnded` and finishes it. `TabSession.ingestNativeUsageAccountingEvent` is the single core ingestion point, fed by a session-owned forwarder that holds only the stream, outlives run attempts, drains a detached controller until its launch ends and then terminates, and is cancelled only on replacement, never-launched removal and session deinit; execution identity is the launch token. Production-shaped accounting is result-only: request-scope snapshots are never attributed to a dispatch ordinal (quarantined to the test-only `.qualified` fixture). The `.unqualified` policy remains a lifecycle-only test/diagnostic policy under which no persisted mutation happens. Phase 3's core usage projection is rendered by the shared `AgentProviderUsageReadout` in the runtime sidebar card and the reachable context-pill popover; it is cached per `TabSession` and invalidated by its accounting state key plus an explicit hydration/replacement generation. A Claude readout with no record explains that nothing was recorded yet, an awaiting execution explains that it is not counting yet, a tokens-only execution explains that cost is not established for that version, and child-affected turns are named. Provider-session identity in a segment is optional install-time provenance and may be absent before runtime initialization. Lifecycle boundaries (2026-09-15; focused validation passed and fresh OracleA/OracleB remediation reviews approved; live validation pending): hydration that replaces the accumulator while the same process stays attached carries the previous verdict (a blocked execution stays blocked) and continues the persisted segment for that execution — its checkpoint remains the baseline, its still-open turns are re-registered, and a zero baseline is never reopened for a process that already has a checkpoint (a persisted non-open segment for the execution fails closed); the controller's `usageAccountingEvents` gives the first subscriber the buffered lifetime stream and every later subscriber a fresh stream (previous finished) bootstrapped in order with the current launch's already-emitted evidence (cleared at `launchEnded`; ended launches are never replayed) because the next `launched` can precede the replacement forwarder's subscription, the session ignores a re-delivered `launched` for the launch it already holds (never a second zero baseline; a launch under a changed accounting owner stays disposed) and the accumulator treats a re-delivered dispatch of a finalized turn and a known result identity as no-ops (review R2), and a session re-attaching the same controller instance while its forwarder still drains keeps that forwarder, launch and execution; stale stdout/EOF discard is keyed on the process launch token, never on accounting state; a turn closed, or an execution ended, while still awaiting its verdict marks an owned record as carrying unmeasured history.

**Bounded latest-request presentation (Claude and Codex):** the compact shared readout now combines the latest live main-loop request's cache-hit share (`CH`) with the existing accumulated session cost. It never labels a finalized Claude result, a Codex cumulative `total`, or a restored session aggregate as the latest request. Claude derives the transient value only from a current-dispatch, provider-session-matched, main-line `assistant.usage` event and deduplicates repeated chunks by Anthropic message ID; events with a non-null `parent_tool_use_id` are native-child/sidechain activity and cannot replace it. The controller emits this evidence live only: it is omitted from the usage-event resubscription buffer, ignored after the owning result closes, cleared when a new turn starts or the launch ends, and never serialized. A newer assistant request with no usage object or missing input/cache counters replaces the earlier value with unavailable rather than retaining it. Every stable request identity is remembered for the execution even when its first event has no usage, so a superseded usage-less identity cannot replay later; only the current identity's observation is retained. Claude and Codex keep separate transient slots so overlapping provider teardown/startup cannot clobber either provider's live value. This transient path does not change the result-only persisted-accounting rule above, result request subtotals, cumulative-cost checkpoints, `ownedRevision`, or session dirty/save behavior.

Codex derives the transient value only from `observation.last` on the newest dispatch-bound, provider-notified turn of the current controller generation. Registering the next dispatch clears the previous value immediately; presentation binds to a provider turn only when that turn consumes the exact still-pending dispatch ticket. A withdrawn ticket, an unbound or repeated turn start, absent/incomplete/inconsistent `last`, inferred or unknown turn identity, an older/settled turn replay, controller replacement, and execution end cannot retain or manufacture a current-request value. Ending a Codex execution clears presentation without disposing or resetting the controller generation's accounting baseline; a same-generation begin remains idempotent. Codex session-average CH remains the token-weighted projection of owned `total` intervals, and accumulated cost remains the sum of those disjoint frozen-priced intervals.

For both providers, a complete zero numerator with a positive denominator displays `0.0%`; missing counters and a zero denominator remain unavailable. The context-pill popover separately names latest-request CH, token-weighted session-average CH, the tracking start, and accumulated session cost. Each metric reports its own complete/partial/unavailable coverage and surfaces only the concrete stored turn, segment, or interval diagnostics relevant to that metric; cost-only continuation limits do not appear as CH causes. Codex tracking start is unavailable until at least one owned Codex interval exists, rather than borrowing a Claude-only record's start. If an older persisted partial marker has no separately recorded reason, the UI says that its historical cause was not recorded rather than guessing. The runtime-sidebar host uses the same projection in its tooltip and accessibility value.

**Codex (plan §4.1):** `CodexNativeSessionController` emits, beside the unchanged `.tokenUsage(AgentContextUsage)`, an optional-preserving `.usageObservation(CodexUsageObservation)` for every `thread/tokenUsage/updated` notification (thread/turn identity with `notified`/`inferredCurrentTurn`/`unknown` provenance, per-controller delivery ordinal, `last`/`total` counters including the schema-optional `cacheWriteInputTokens` exactly as delivered) and `.modelRerouted(CodexModelReroute)` for the installed `model/rerouted` notification. `CodexAgentModeCoordinator` forwards both to `TabSession` before the active-run context guard, freezes a pricing snapshot (`OpenAIPricingProviding.currentSnapshot()`, requested model as an explicit assumption) at each `turn/start` dispatch and binds it to the `turn/started` identity. `AgentUsageAccumulator` (extension in `Runtime/Usage/Codex/CodexUsageAccounting.swift`) keys the Codex execution by controller generation (fresh `thread/start` = verified zero baseline, resumed = unknown/prospective), prices disjoint owned `total` intervals (`ordinary input = I − C − W`, cached, cache-write and reasoning-inclusive output at the frozen Standard/global list rates; each interval is one point estimate in one band — a known context window below the official threshold proves the short band, otherwise the latest request's positive input size (`observation.last`) decides, a band already applied to the open turn is never downgraded by a refinement, and with no such evidence (or when a model lists a long band without a stated threshold) the standard band applies with a named assumption that does not lower coverage; the summed interval never picks the band; a missing necessary rate or inconsistent counters are unavailable, never free), treats an identical `total` as a duplicate no-op, upserts a notified refinement of the open turn from that turn's own baseline, rebaselines prospectively on an unexplained decrease, and leaves rerouted, unbound, unlisted-model, inferred or unknown-turn intervals unpriced (partial) while still counting their tokens toward the cache-hit share. Intervals persist as the optional `codexIntervals` member of the same v1 `providerUsage` record (absent stays absent, so older bytes remain lossless); the compact readout shows the same two labelled values for every scope, `Cache Hit Ratio` (latest request; `observation.last` for Codex) and `API Cost Estimates` (accumulated session cost, two decimals half-up, `<$0.01` for a positive amount that rounds to zero, `—` when unavailable, never a coverage suffix or provider name), while the popover shows the separate session-average CH from cumulative `total` intervals with API-equivalent, not-billed wording and the recorded unmeasured-baseline or unpriced-interval causes. Cadence across resume, fork and compaction is not evidenced on the app-server wire; those intervals stay partial rather than blocking fresh owned intervals. Current accounting rules (2026-09-15; focused validation passed and fresh OracleA/OracleB remediation reviews approved; pricing revised to point estimates 2026-11-01): an absent `cacheWriteInputTokens` is the installed schema default of zero, so uncached input is priced at the input rate (a baseline that lacks the count while the current checkpoint reports it uses zero for the baseline); intervals persist equal lower/upper bounds in the unchanged schema, and a legacy interval an older build priced as a range projects its lower bound with a disclosure in the cost details; absolute counters must be non-negative and `C + W <= I` is validated independently of pricing (inconsistent intervals keep counts, stay unpriced and are excluded from CH); monotonicity is checked against the latest accepted checkpoint before any same-turn refinement and a notified observation for a settled turn is rejected as replay; a reroute invalidates every priced interval of its execution and turn; each priced interval persists `appliedPricing` (basis, source kind, capture/validation dates, dispatch-time staleness, applied rates in both lower/upper slots) so amounts stay explainable without repricing; a dispatched turn that ends without usage (`turn/completed` interrupted/failed, controller replacement/reset, cancel, shutdown) persists an `.unavailable` marker row that makes cost and CH partial until a provably owned late observation upserts it; wire booleans are classified before integer bridging. Lifecycle and ownership rules: checkpoint ownership is ordered by `turn/started` binding order independently of reporting, so an older bound turn's late first report is rejected before any rebaseline (no overlap, no refund); unmeasured markers are tracked apart from the refinable open turn (closing another turn never revokes a provable refinement; a late report replaces its marker in place); a `turn/start` is tracked as dispatched work whether or not a pricing snapshot exists, registration (before the send, since `turn/started` may precede the receipt) returns a `CodexDispatchTicket` whose withdrawal requires proven pre-submission failure under the rule below (`turn/steer` registers nothing); a nil-ID `turn/completed` closes the turn the coordinator's completion correlation validates, marks all outstanding work when it correlates only to an anonymous turn, and leaves accounting untouched when rejected. The send-outcome rule is: a receipt or any `turn/started` accepts the ticket independently of optional turn identity, and only the exact still-unaccepted ticket may be withdrawn after the controller's typed local preflight error proves the request never reached its request executor. JSON-RPC `requestFailed` (also synthesized locally for timeout), cancellation, process loss, response validation, transport-write and generic errors remain delivery-unknown and keep their obligation until lifecycle completion or controller-generation teardown; no JSON-RPC `turn/start` error is currently treated as definitive rejection without narrower evidence.

Phase 6 adds a standard-library-only [offline Claude raw-event analyzer](../../Scripts/analyze_claude_raw_events.py) for explicit existing JSONL files. It uses bounded input, treats only decoded `protocol.inbound.streamPayload` records as canonical, counts but ignores raw/translated duplicate views, and emits privacy-safe aggregate coverage, observed parent request-ID counts, request-level weighted cache split, separate aggregate billed-turn result-usage coverage, and unsummed cumulative cost checkpoints. Missing request fields preserve established observations; invalid or conflicting fields remain excluded, and excluded parent observations make coverage partial without inventing request IDs. It does not infer billed-request uniqueness, native-child splits, live/replay ownership, waits, response bytes/tokens, export behavior, savings or a longer timeout. Those G3 fields and the minimum five matched pairs remain unavailable, and the 120-second default is unchanged. The offline analyzer does not qualify live accounting; current normal-build Claude and Codex behavior is described above. The G3 empirical exit remains incomplete. See the [Phase 6 status](../context/plans/2026-09-13-agent-usage-and-wait-efficiency-plan.md#28-phase-6-offline-evidence-tooling-status-2026-09-14).

`AgentSession.providerUsage` carries an optional supported v1 record or captured raw JSON. `AgentSessionDataCodec` and the feature-private `AgentProviderUsageJSONScanner` capture and reinsert only the top-level usage member, retaining arbitrary numeric lexemes and unknown nested data. Every persisted full/header/run-state/history/stress decode and session save/rewrite uses that codec; generic Codable alone cannot preserve arbitrary JSON numbers and is limited to its documented subset. Duplicate top-level usage keys are rejected as ambiguous. Supported projections require strict members, semantic validation and exact numeric-value comparison; invalid/future values remain opaque, and foreign-origin records remain excluded from destination spend.

Absent stays absent, explicit null remains present, and production saves retain the captured bytes. The existing session writer remains the only persistence owner; codec/encoding failure occurs before replacement writes. Handoff destinations do not inherit source spend, and clear/compaction does not refund history. Older builds may discard the new field on resave; no downgrade round-trip guarantee is made. Focused regression owners are `AgentUsageAccountingTests`, `AgentUsagePersistenceTests`, `AgentUsageRuntimeIntegrationTests` and `ClaudeNativeUsageAttributionTests`; review and validation status are recorded in the active usage plan.

## Claude CLI executable selection

Core owns the user-configurable Claude CLI executable override. Settings persists the applied path under `cliExecutableOverride.claude`; `CLIProvidersSettingsView` presents it in the Claude CLI section, and `APISettingsViewModel` owns draft validation, apply/reset, and probes.

The override is sampled for new local Claude-family sessions and one-shot operations. It covers interactive Agent Mode, headless discovery, Settings probes, and Claude MCP installation for standard Claude Code, GLM, Kimi, and custom Claude-compatible backends. Remote-host sessions ignore the local preference, and Codex executable selection is unaffected.

A configured path is validated before launch. Failure produces a typed error and never falls back to another `claude`; configured launches bypass `CommandPathResolver` and `ResolvedCommandCache`. With an empty setting, automatic resolution retains `.preferShell` login-shell lookup. The two Settings probes also use `.preferShell`, matching the local runtime instead of their former `.fallbackOnly` behavior.

`CLIProcessConfiguration.init` requires every call site to name `command:` explicitly; the parameter has no default value. Wrapper or shim paths apply only to new sessions, must `exec` the real CLI, and must keep stdout transparent for the stream-JSON protocol.

## Bridge responsibilities

### `ClaudeCompatibleProviderRuntimeBridge` (infrastructure)

Path: `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift`.

This is the only file in core that `import RepoPromptClaudeCompatibleProvider`. It is responsible for:

- declaring `ClaudeCompatiblePlugin…` type aliases for every package DTO core code references, so other files can refer to plugin types without importing the package;
- converting core enums/structs to plugin DTOs and back (`pluginRuntimeVariant(for:)`, `pluginBackendID(for:)`, `pluginBackendConfig(from:)`, `runtimeConfig(from:)`, `launchEnvironment(from:)`, `coreLaunchEnvironment(from:)`, etc.);
- forwarding pure runtime helpers from the package: `ClaudeCompatiblePromptDelivery`, `ClaudeCompatibleBackendEnvironmentBuilder`, `ClaudeCompatibleHeadlessRuntime`, `ClaudeCompatibleLaunchEnvironmentResolver`, `ClaudeCompatibleModelCatalog`, `ClaudeCompatibleModelNormalizer`;
- translating package errors (`ClaudeCompatibleProviderError.invalidConfiguration`) into core errors (`AIProviderError.invalidConfiguration`);
- mapping `ClaudeProviderStreamResult` to `AIStreamResult` and back, so plugin DTOs never leak into Agent Mode and core stream results never leak into the package.

Files that depend on this bridge (illustrative):

- `Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift` (stream mapping)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeLaunchEnvironmentResolver.swift` (model normalization, slot mapping, launch resolution)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeCompatibleBackendStore.swift` (env builder)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodePromptDelivery.swift` (decorated user message)
- `Infrastructure/AI/Providers/ClaudeCode/ClaudeAgentToolPreferences.swift` (prompt delivery rules)
- `Infrastructure/AI/Providers/ClaudeCodeAgentProvider.swift` (headless arguments, user-message decoration)

### `ClaudeCompatiblePluginBridge` (Agent Mode feature facade)

Path: `Sources/RepoPromptAgentCore/AgentMode/Providers/ClaudeCompatible/ClaudeCompatiblePluginBridge.swift`.

Responsibilities the infrastructure bridge cannot cleanly own because they require Agent-Mode-only concepts:

- `pluginID(for: AgentProviderKind)` / `agentKind(for: ClaudeCompatiblePluginID)` – the only place Agent Mode's provider kind talks to package IDs.
- `agentModeRuntimeConfig(...)` and `discoveryRuntimeConfig(...)` – build a `ClaudeCompatibleRuntimeConfig` from `ClaudeCodeAgentConfig.agentMode(...)` / `.discovery(...)` while staying tied to `AgentProviderKind`.
- `availability(for:)` – combines `AgentModelCatalog.isAgentAvailable(...)` with package availability shapes.
- `streamResult(from:)` / `providerStreamResult(from:)` – Agent-Mode-facing wrappers re-exported for the adapter trio.

Everything else is a thin pass-through to `ClaudeCompatibleProviderRuntimeBridge`.

## Adapter trio

The Agent Mode side of the bridge ships three small adapters under `Sources/RepoPromptAgentCore/AgentMode/Providers/ClaudeCompatible/`.

### `ClaudeCompatibleNativeSessionAdapter`

- Carries a `ClaudeCompatiblePluginRuntimeConfig` and delegates `NativeAgentRuntimeControlling` to a controller factory closure.
- Today the factory returns a `ClaudeNativeProcessSessionController` (core-owned process control). A future slice can replace the factory body with a package-driven controller without changing the adapter's public shape.
- `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` is the single call site that constructs and hands the adapter to `ClaudeAgentModeCoordinator`.

### `ClaudeCompatibleHeadlessProviderAdapter`

- Wraps a concrete `HeadlessAgentProvider` (currently `ClaudeCodeAgentProvider`) and carries a `ClaudeCompatiblePluginRuntimeConfig` for parity with the interactive adapter.
- `AgentRuntimeProviderService.makeProvider(...)` branches for `.claudeCode | .claudeCodeGLM | .kimiCode | .customClaudeCompatible` build the underlying provider and wrap it in this adapter. Non-Claude providers (Codex, Gemini, OpenCode, Cursor) bypass the adapter.

### `ClaudeCompatibleModelCatalogAdapter`

- Asks the package for a `ClaudeCompatibleModelCatalogSnapshot`, then canonicalizes raw values back onto `AgentModel.resolvedModel(...)` and existing GLM legacy aliases.
- Owns the public Agent-Mode-facing helpers `AgentModelCatalog` forwards to for Claude-compatible branches: `defaultModelRaw(for:)`, `options(for:)`, `isValid(rawModel:for:availability:)`, `claudeEffort(...)`, plus compatible-backend display/description lookups.
- Keeps `AgentModel` raw values and validation semantics stable so persisted user selections survive the seam.

## Provider-neutral native runtime contract

Path: `Sources/RepoPromptAgentCore/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift`.

This is an **app-internal** contract, not the external plugin API. It still uses core models (`AIStreamResult`, `AgentApprovalRequest`, `AgentApprovalDecision`) because adapters translate plugin DTOs first. The current shape:

```swift
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }
    var requiresReplacementAfterTerminalStartupFailure: Bool { get async }
    // Ordered usage-accounting evidence; defaults to an already-finished stream.
    var usageAccountingEvents: AsyncStream<NativeUsageAccountingEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    func sendUserMessage(_ text: String) async throws -> UUID
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
    // RepoPrompt MCP health of the current launch; defaults to `.unknown` (never recovered).
    var currentRepoPromptMCPHealth: NativeAgentRuntimeRepoPromptMCPHealth { get async }
    // Bounded wait for fresh connected evidence; the default never reports connected.
    func awaitRepoPromptMCPConnectedEvidence(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval
    ) async -> NativeAgentRuntimeRepoPromptMCPProbeOutcome
}
```

Protocol-extension defaults (`emitEventMarker(_:)`, the MCP health members, and similar) are statically dispatched when called on a concrete controller type that doesn't declare them in its own body; call through `any NativeAgentRuntimeControlling` in tests, as the runner does, so the actor's witnesses are used.

The associated event/session/turn types are currently `typealias`es over the Claude-native runtime DTOs (`NativeAgentRuntimeEvent = ClaudeNativeProcessSessionController.Event`, etc.). When a second native provider arrives, the aliases will become proper neutral DTOs and the Claude controller will conform via its own mapping. Until then the alias layer keeps the seam ergonomic without forcing churn on coordinators, runners, and tab-session storage.

`ClaudeSessionControlling` is retained as a backwards-compatible alias for existing Claude call sites.


## Oh My Pi managed ACP integration

Oh My Pi (OMP) is implemented as an app-internal ACP provider under `Sources/RepoPromptAgentCore/AI/Providers/OhMyPi/`, not through the Claude-compatible package seam. Its stable identities are `ACPProviderID.ohMyPi`, `AgentProviderKind.ohMyPi`, and `AgentProviderBindingID.ohMyPi` (raw `"ohMyPi"`); the executable is `omp`, the runtime kind is `"omp_acp"`, and the verified MCP `clientInfo.name` is `"omp-coding-agent"`. OMP preserves expected-PID and pre-prompt Agent Mode MCP routing.

RepoPrompt owns one fixed OMP launch/preflight profile shared by Agent Mode and Oracle one-shots. New processes receive exactly:

```text
omp acp --no-tools --no-extensions --no-skills --no-rules --approval-mode yolo
```

There is no argument passthrough or per-flag opt-out. Preflight resolves a trusted executable (including the OMP/Bun home-bin hint), separately requires `omp acp --help` to exit successfully, validates every managed global flag in `omp --help`, and rejects versions older than the locally captured `17.2.12` baseline. OMP 17.2.12's ACP subcommand help contains only subcommand usage, so it is not used as evidence for global flags.

Interactive Agent Mode and Agent Mode headless runs inject exactly one command-shaped RepoPrompt stdio MCP server; model discovery uses no MCP server and does not dispatch a prompt. Oracle one-shots instead use `OhMyPiCLIProvider` through the same trusted-executable resolver, fixed argv, managed-flag validation, and version floor, but with RepoPrompt MCP disabled, no workspace or resume, a no-tools system suffix, and ACP approval requests rejected by the headless `.declineUnsupported` policy. A nonblank persisted Agent Mode provider session ID selects `session/load`, while a blank or absent ID selects `session/new`. OMP resume is exact-or-error: a failed load never falls back to a fresh session after transcript replay has been withheld. Models are dynamic ACP `configOptions` data stored in `AgentACPModelRegistry`; the Agent Mode catalog retains `Default` as its sole static sentinel, while the Oracle `AIModel` catalog has no static OMP fallback. RepoPrompt sends OMP's `thinking` option only when the resolved source destination has an explicit entry for the exact wire model ID. The complete capped map is independently owned by each model preset, Agent Mode tab/session, and Prompt destination; key absence remains Default and sends nothing. Request assembly attaches the typed option from that source map, with no provider-global preference lookup.

The OMP permission binding has its own RepoPrompt MCP capability grant and a fixed managed-barebones profile. ACP duplicate approval is allowed only for an exact known RepoPrompt server identity and/or an explicit server-prefixed canonical RepoPrompt tool name; substring server matches and unrecognized requests retain the existing interactive behavior. This optimization does not change the server-side MCP permission decision.

OMP is a supported catalog provider in DEBUG and RELEASE. Window availability is gated by `APISettingsViewModel.isOhMyPiConnected`; a DEBUG qualification lease is an OR override. A successful connection test enables Agent Mode, MCP `list_agents`/`agent_run`, Context Builder, and registry-backed Oracle picker entries, including current-process cached-provider validation and dynamic model subscriptions. The Oracle picker is empty when no dynamic OMP snapshot exists; it never manufactures `Default`, and a persisted OMP selection still decodes and displays while disconnected. `AgentProviderBindingID.publicSettingsCases` remains excluded because the fixed managed OMP profile has no mutable generic setting. Recommendations and task-label resolution remain excluded. MCP-enabled Agent Mode headless OMP waits for the already-registered routing signal before sending its first prompt, while `MCPBootstrapLease` remains the routing cleanup owner. For prompt dispatch, the route check is skipped exactly when `includeRepoPromptMCPServer` is false; model discovery does not send a prompt and therefore never traverses this pre-prompt gate.

Focused Oracle coverage lives in `OhMyPiModelCatalogTests`, `OhMyPiCLIProviderTests`, `OhMyPiACPHeadlessAgentProviderTests`, `HeadlessCLIStreamBridgeTests`, and `CursorCLIProviderTests`.

The hidden DEBUG qualification path remains strict and separate from ordinary public starts. If any qualification lease/context is supplied, owner process, connection, workspace, generation, receipt, Apply Edits scope, and provider identity checks all fail closed; a lease never authorizes a non-OMP target. The six live qualification gates and cross-process `session/load` MCP re-registration have passed. OMP has no supported CE timeout override today; do not add a speculative one.

## ACP provider MCP tool-call timeouts

RepoPrompt CE cannot impose one MCP tool-call timeout across external ACP providers; configure the provider where supported.

- **OpenCode:** Timeout values are milliseconds. For a 10,000-second call, set `"timeout": 10000000` on the existing RepoPrompt MCP server entry, preserving its `type`, `command`, and `environment` fields.
- **Cursor Agent:** Current builds expose no supported ACP, CLI, environment, or configuration override that RepoPrompt CE can set to 10,000 seconds. Do not add a speculative CE timeout control; add one only if Cursor documents a supported configuration surface.

## How a new provider plugs in

The recommended pattern when adding (for example) a hypothetical `acmeAgent` family:

1. **Decide the runtime shape.**
   - Interactive native CLI: implement `NativeAgentRuntimeControlling` for the new family, building an adapter analogous to `ClaudeCompatibleNativeSessionAdapter`.
   - Headless-only CLI: build a `HeadlessAgentProvider` and (optionally) wrap it in a per-family adapter for parity. One-shot AI-query adapters can reuse `HeadlessCLIStreamBridge` while retaining provider-specific prompt, config, model, and event semantics.
   - ACP-based: follow `Sources/RepoPromptAgentCore/AgentMode/Providers/ACP/ACPAgentProvider.swift` instead — ACP runtimes do not yet flow through the Claude-compatible plugin seam.

2. **Add (or reuse) a provider package.**
   - For an external family with its own SDK/codec, add a new library product under `Packages/RepoPromptAgentProviders/Sources/RepoPromptAcmeProvider/` and register a Swift target in the package manifest.
   - Keep DTOs Foundation-only. Use a `Sendable` JSON value type rather than `[String: Any]`.
   - Add package-level tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptAcmeProviderTests/` covering codec, translator, prompt delivery, and catalog snapshots.

3. **Wire the package into core through a bridge.**
   - Add one infrastructure file that imports the new package and declares `Acme…` type aliases, DTO conversions, and pure-helper forwarders. Mirror `ClaudeCompatibleProviderRuntimeBridge`.
   - Add an Agent-Mode-facing facade if the new family needs `AgentProviderKind` mappings, availability rules, or runtime-config builders.

4. **Add the adapter trio.**
   - `AcmeNativeSessionAdapter` (if interactive), `AcmeHeadlessProviderAdapter`, `AcmeModelCatalogAdapter`.
   - The native adapter conforms to `NativeAgentRuntimeControlling` and delegates to a factory closure so the controller implementation can move between core and the package later.

5. **Extend the runtime/factory wiring.**
   - Add the new cases to `AgentProviderKind` and the supporting maps (`commandName`, `displayName`, `mcpClientNameHint`, `runtimeKind`, `usesClaudeNativeRuntime` / new flags, `claudeRuntimeVariant` if relevant, `agentDescription`).
   - Extend `AgentProviderBindingID` if the new family needs its own permission/settings grouping; otherwise reuse an existing binding ID and keep secure-store documents grouped accordingly.
   - Add a branch in `AgentRuntimeProviderService.makeProvider(...)` that builds the headless provider and wraps it in the new adapter.
   - For interactive runs, add a sibling of `AgentModeViewModel.makeClaudeCompatibleNativeController(...)` that constructs the adapter; pass it through `ClaudeAgentModeCoordinator`'s factory or add a coordinator analogue if the new family needs distinct steering rules.

6. **Plug into the model catalog.**
   - Forward the new family's branches in `AgentModelCatalog` to `AcmeModelCatalogAdapter` so option ordering, defaults, validation, display names, and discovery payloads come from the package while preserving `AgentModel` raw values for persisted user selections.

7. **Keep persistence in core.**
   - Settings/backend stores live under `Infrastructure/AI/Providers/Acme/` and are sanitized into plugin DTOs at launch time.
   - Secrets pass through `@Sendable` provider closures (see `ClaudeCompatibleLaunchEnvironmentResolver`'s `zaiSecretProvider`/`backendSecretProvider`) rather than being read inside the package.

8. **Add tests.**
   - Package-level tests for pure logic in the new product.
   - Root app tests under `Tests/RepoPromptTests/` for: adapter-to-controller wiring, model catalog snapshots (option order, defaults, raw values), launch-environment resolution, and any new permission/binding rules.

## Validation

Standard checks for changes that touch the seam:

```bash
# Root build (includes the path-dependency package)
make dev-swift-build PRODUCT=RepoPrompt

# Focused suites used during Work Items 1–9
make dev-test FILTER='ClaudeSDKNDJSONTranslatorTests|ClaudeCompatibleBackendEnvironmentTests|ClaudeNativeApprovalAndResumeTests|ClaudeCompatibleModelCatalogTests|ClaudeCompatiblePluginBridgeTests'

# Package-only iteration
make dev-provider-test
```

Add the relevant focused suite before any catalog/codec change, and snapshot model catalogs across `claudeCode`, `claudeCodeGLM`, `kimiCode`, and `customClaudeCompatible` before touching `AgentModelCatalog` branches.

## References

- `Package.swift` — root manifest and product wiring.
- `Packages/RepoPromptAgentProviders/Package.swift` — provider package manifest.
- `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/` — plugin DTOs, codec, translator, prompt delivery, environment builder, catalog, headless arg builder, launch-env resolver.
- `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` — single package import point.
- `Sources/RepoPromptAgentCore/AI/Providers/HeadlessCLIStreamBridge.swift` and `Sources/RepoPromptAgentCore/AI/Providers/OhMyPi/OhMyPiCLIProvider.swift` — shared one-shot lifecycle plus the tool-free OMP Oracle adapter.
- `Sources/RepoPromptAgentCore/AgentMode/Providers/ClaudeCompatible/` — Agent-Mode facade and adapter trio.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift` — provider-neutral runtime contract.
- `Sources/RepoPromptAgentCore/AI/Prompts/Workflows/` — provider-neutral RepoPrompt workflow prompt catalog, metadata, variants, and renderers shared by installs and MCP prompt registration.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift` — `AgentProviderKind` and headless factory.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` — `makeClaudeCompatibleNativeController(...)`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift` — interactive Claude-compatible coordinator.
- SwiftPM package manifest docs: <https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html>
- Xcode local package override workflow: <https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package>
