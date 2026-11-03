import Foundation

// MARK: - Codex accounting inputs (plan §4.1)

/// How the thread behind a Codex controller generation came to exist. A fresh `thread/start`
/// has a verified zero counter baseline; a resumed thread inherits unknown usage, so its first
/// observed cumulative total only starts prospective tracking.
enum CodexThreadOrigin: Equatable {
    case fresh
    case resumed
}

/// Immutable pricing basis captured at dispatch: the requested model (an explicit assumption,
/// never observed routing) and the pricing snapshot current at that moment. A later catalog
/// refresh affects later dispatches only.
struct CodexDispatchBasis: Equatable {
    let requestedModelID: String?
    let pricing: OpenAIPricingSnapshot
}

/// Receipt for one registered dispatch. A caller hands it back (`withdrawCodexDispatch`) only
/// after a proven pre-submit failure or definitive provider rejection, so delivery-unknown work
/// remains covered; an accepted or turn-bound ticket is a no-op.
struct CodexDispatchTicket: Equatable {
    let executionID: UUID
    let serial: UInt64
}

/// In-memory Codex ownership state of the accumulator (never persisted). Intervals and the
/// unmeasured-history flag live on the shared `AgentProviderUsageRecord`.
struct CodexUsageAccountingState: Equatable {
    /// The turn that owns the latest accepted checkpoint and may still refine it. Only accepted
    /// usage moves it; unmeasured-work markers never do (review R2: a marker for another turn
    /// must not revoke this turn's provable refinement ownership).
    struct OpenTurn: Equatable {
        let turnID: String
        let baselineTotal: CodexUsageObservation.Counters
        /// Interval a same-turn refinement upserts; `nil` after a prospective rebaseline, where the
        /// next same-turn observation appends a new interval from `baselineTotal`.
        let intervalIndex: Int?
        /// Highest context band applied to this turn's pricing so far. A refinement may upgrade
        /// short → long but never downgrades, so a turn's displayed cost never decreases.
        var appliedBandKind: OpenAIPricingContextBand.Kind?
    }

    var activeExecutionID: UUID?
    var baselineKnown = false
    /// Latest accepted cumulative checkpoint. Monotonicity is checked against it for every
    /// observation, independently of the baseline a same-turn refinement is priced from.
    var lastAcceptedTotal: CodexUsageObservation.Counters?
    var lastOrdinal = 0
    var openTurn: OpenTurn?
    /// A dispatch is awaiting its `turn/started` binding. Tracked independently of the
    /// optional pricing snapshot: an unpriced dispatch is still dispatched work (review R2).
    var pendingDispatchTicket: CodexDispatchTicket?
    /// Provider acceptance is separate from optional turn identity. A nil-ID `turn/started` or
    /// the typed start receipt sets this bit and prevents a later contradictory failure from
    /// withdrawing potentially incurred work (review R3).
    var pendingDispatchAccepted = false
    var nextDispatchSerial: UInt64 = 0
    var pendingDispatchBasis: CodexDispatchBasis?
    var basisByTurnID: [String: CodexDispatchBasis] = [:]
    /// Binding order of every turn identity `turn/started` reported on this execution, whether or
    /// not the turn ever reported usage. Checkpoint ownership is ordered by it: a notified
    /// observation for a turn bound before the turn owning the latest accepted checkpoint is
    /// demonstrably older and is rejected before any rebaselining (review R2, OracleA P0#1).
    var bindingOrdinalByTurnID: [String: Int] = [:]
    var nextBindingOrdinal = 0
    /// Binding ordinal of the turn that owns the latest accepted (or prospective) checkpoint.
    var lastAcceptedTurnOrdinal: Int?
    var reroutedTurnIDs: [String: String] = [:]
    /// A reroute observed before any turn identity is bound applies to the next bound turn.
    var pendingRerouteModel: String?
    /// Notified turns that already produced an accepted checkpoint. An observation naming one of
    /// them while another turn is open is an older-turn replay and is rejected, never rebaselined.
    var settledTurnIDs: Set<String> = []
    /// Bound turns whose dispatched work has not produced any accepted usage observation yet.
    var turnIDsAwaitingUsage: Set<String> = []
    /// Outstanding unmeasured-work markers by turn (index into `codexIntervals`). A provably owned
    /// late observation upserts the marker instead of appending; kept apart from `openTurn`.
    var unmeasuredMarkerIndexByTurnID: [String: Int] = [:]
}

/// Locally calculated API-equivalent point estimate for the session (sum of disjoint owned
/// intervals). Legacy persisted intervals priced as a range by an older build contribute their
/// lower bound, the `W = 0` / standard-band corner of that legacy range. Never an invoice.
struct CodexCostEstimate: Equatable {
    var amount: Decimal
    var currency: String
    var coverage: AgentProviderUsageRecord.Coverage
}

/// Provenance of the pricing frozen into priced intervals, for the readout's details.
struct CodexPricingProvenance: Equatable {
    var pricingVersions: [String]
    var earliestCapturedAt: Date?
    var latestCapturedAt: Date?
    var latestValidatedAt: Date?
    /// Priced intervals whose dispatch-time snapshot was already stale (validation older than the
    /// refresh interval, or a failed refresh since).
    var staleIntervalCount: Int
}

// MARK: - Arithmetic

enum CodexUsagePricing {
    static let currency = "USD"
    static let million = Decimal(1_000_000)

    struct Delta: Equatable {
        var input: Int64?
        var cached: Int64?
        var cacheWrite: Int64?
        var output: Int64?
        var reasoningOutput: Int64?

        var hasNegativeComponent: Bool {
            [input, cached, cacheWrite, output, reasoningOutput].contains { ($0 ?? 0) < 0 }
        }
    }

    enum Estimate: Equatable {
        case point(Decimal)
        case unavailable(String)
    }

    struct Applied: Equatable {
        let estimate: Estimate
        /// `all`, `shortContext` or `longContext`; `nil` when no band could be applied.
        let bandKind: String?
        /// The one rate set actually applied; `nil` when no band could be applied.
        let appliedRates: OpenAIPricingRates?
        /// A stated pricing assumption for the details (it never lowers coverage).
        let assumption: String?

        init(estimate: Estimate, bandKind: String?, appliedRates: OpenAIPricingRates? = nil, assumption: String? = nil) {
            self.estimate = estimate
            self.bandKind = bandKind
            self.appliedRates = appliedRates
            self.assumption = assumption
        }
    }

    /// Diagnostic for a model listing short and long bands without an official qualifier.
    static let unstatedContextThresholdAssumption = "long-context qualifier not stated; standard-context rates applied"
    /// Diagnostic for a banded model when neither the context window nor the latest request size
    /// proves the band.
    static let unknownRequestSizeAssumption = "latest request size unavailable; standard-context rates applied"

    /// Prices one owned interval as a single point: `ordinary input = I − C − W` at the input
    /// rate, `C` at the cached-input rate, `W` at the cache-write rate and reasoning-inclusive
    /// output at the output rate, all from the frozen Standard/global list prices. An absent
    /// cache-write count is the installed v2 schema default of zero (the provider reported no
    /// cache-write component). Counts must be non-negative and `C + W <= I`; a rate that an
    /// included non-zero component needs must be listed, otherwise the interval is unavailable,
    /// never free.
    ///
    /// Context band (model with a stated threshold), in order:
    /// 1. `minimumBand == .longContext` (the open turn was already priced long) keeps the long
    ///    band: refinements never downgrade a turn.
    /// 2. A known `modelContextWindow` below the threshold proves no request can reach the long
    ///    band: short.
    /// 3. A positive `requestContextTokens` (the latest request's total input,
    ///    `observation.last.inputTokens`, which the official `<272K context` qualifier applies
    ///    to): short below the threshold, long at or above it. Zero or negative is missing.
    /// 4. Otherwise the standard (short) band with `unknownRequestSizeAssumption`; the summed
    ///    interval is never used, because it spans many requests.
    /// A model listing a long band without a stated threshold uses the standard band and names
    /// that assumption. Assumptions never lower coverage.
    static func estimate(
        _ delta: Delta,
        requestContextTokens: Int64? = nil,
        modelContextWindow: Int64? = nil,
        minimumBand: OpenAIPricingContextBand.Kind? = nil,
        resolution: OpenAIModelPricingResolution
    ) -> Applied {
        guard let input = delta.input, let output = delta.output else {
            return Applied(estimate: .unavailable("input or output count missing"), bandKind: nil)
        }
        guard let cached = delta.cached else {
            return Applied(estimate: .unavailable("cached input count missing"), bandKind: nil)
        }
        let cacheWrite = delta.cacheWrite ?? 0
        guard input >= 0, cached >= 0, output >= 0, cacheWrite >= 0 else {
            return Applied(estimate: .unavailable("negative counter"), bandKind: nil)
        }
        let (cacheSide, overflow) = cached.addingReportingOverflow(cacheWrite)
        guard !overflow, cacheSide <= input else {
            return Applied(estimate: .unavailable("cached and cache-write input exceed input"), bandKind: nil)
        }
        let band: OpenAIPricingContextBand
        var assumption: String?
        switch selectBand(
            resolution.pricing,
            requestContextTokens: requestContextTokens.flatMap { $0 > 0 ? $0 : nil },
            modelContextWindow: modelContextWindow.flatMap { $0 > 0 ? $0 : nil },
            minimumBand: minimumBand
        ) {
        case let .success(selection):
            band = selection.band
            assumption = selection.assumption
        case let .failure(reason):
            return Applied(estimate: .unavailable(reason.message), bandKind: nil)
        }
        return Applied(
            estimate: price(input: input, cached: cached, cacheWrite: cacheWrite, output: output, rates: band.rates),
            bandKind: band.kind.rawValue,
            appliedRates: band.rates,
            assumption: assumption
        )
    }

    private struct BandSelectionFailure: Error {
        let message: String
    }

    /// The one band that applies to the interval (see `estimate` for the evidence order).
    private static func selectBand(
        _ pricing: OpenAIModelPricing,
        requestContextTokens: Int64?,
        modelContextWindow: Int64?,
        minimumBand: OpenAIPricingContextBand.Kind?
    ) -> Result<(band: OpenAIPricingContextBand, assumption: String?), BandSelectionFailure> {
        if let flat = pricing.flatRates {
            return .success((OpenAIPricingContextBand(kind: .all, rates: flat), nil))
        }
        func listed(_ kind: OpenAIPricingContextBand.Kind) -> OpenAIPricingContextBand? {
            pricing.bands.first { $0.kind == kind }
        }
        guard let threshold = pricing.contextThresholdTokens.map(Int64.init) else {
            guard let standard = listed(.shortContext) else {
                return .failure(.init(message: "no standard-context rates listed"))
            }
            // Only a listed long band makes the missing qualifier an assumption worth naming.
            return .success((standard, listed(.longContext) == nil ? nil : unstatedContextThresholdAssumption))
        }
        let wanted: OpenAIPricingContextBand.Kind
        var assumption: String?
        if minimumBand == .longContext {
            wanted = .longContext
        } else if let modelContextWindow, modelContextWindow < threshold {
            wanted = .shortContext
        } else if let requestContextTokens {
            wanted = requestContextTokens < threshold ? .shortContext : .longContext
        } else {
            wanted = .shortContext
            assumption = unknownRequestSizeAssumption
        }
        guard let band = listed(wanted) else {
            return .failure(.init(message: "no listed rates for the request's context band"))
        }
        return .success((band, assumption))
    }

    private static func price(input: Int64, cached: Int64, cacheWrite: Int64, output: Int64, rates: OpenAIPricingRates) -> Estimate {
        guard let inputRate = rates.input else { return .unavailable("input rate not listed") }
        guard let outputRate = rates.output else { return .unavailable("output rate not listed") }
        var total = Decimal(0)
        let ordinary = input - cached - cacheWrite
        total += Decimal(ordinary) * inputRate
        if cached > 0 {
            guard let cachedRate = rates.cachedInput else { return .unavailable("cached input rate not listed") }
            total += Decimal(cached) * cachedRate
        }
        if cacheWrite > 0 {
            guard let cacheWriteRate = rates.cacheWrite else { return .unavailable("cache write rate not listed") }
            total += Decimal(cacheWrite) * cacheWriteRate
        }
        total += Decimal(output) * outputRate
        return .point(total / million)
    }

    /// `current − baseline` per component; `nil` when either side is missing. Overflow is unavailable.
    /// A cache-write count absent from the baseline but present now uses the schema default 0 for
    /// the baseline, so writes a provider starts reporting mid-session are neither dropped from
    /// `C + W <= I` nor priced as ordinary input. A currently absent count stays absent.
    static func delta(from baseline: CodexUsageObservation.Counters, to current: CodexUsageObservation.Counters) -> Delta? {
        func component(_ from: Int?, _ to: Int?) -> Int64?? {
            guard let from, let to else { return .some(nil) }
            let (value, overflow) = Int64(to).subtractingReportingOverflow(Int64(from))
            return overflow ? nil : .some(value)
        }
        let baselineCacheWrite = current.cacheWriteInputTokens == nil ? baseline.cacheWriteInputTokens : (baseline.cacheWriteInputTokens ?? 0)
        guard let input = component(baseline.inputTokens, current.inputTokens),
              let cached = component(baseline.cachedInputTokens, current.cachedInputTokens),
              let cacheWrite = component(baselineCacheWrite, current.cacheWriteInputTokens),
              let output = component(baseline.outputTokens, current.outputTokens),
              let reasoning = component(baseline.reasoningOutputTokens, current.reasoningOutputTokens)
        else { return nil }
        return Delta(input: input, cached: cached, cacheWrite: cacheWrite, output: output, reasoningOutput: reasoning)
    }

    /// Absolute checkpoints are non-negative integers; anything else is not accounting authority.
    static func isValidCheckpoint(_ counters: CodexUsageObservation.Counters) -> Bool {
        ![counters.inputTokens, counters.cachedInputTokens, counters.cacheWriteInputTokens, counters.outputTokens, counters.reasoningOutputTokens, counters.totalTokens]
            .contains { ($0 ?? 0) < 0 }
    }

    /// `C + W <= I` on an interval's counts (writes unknown count as zero for the check).
    static func hasConsistentInputSubsets(input: Int64?, cached: Int64?, cacheWrite: Int64?) -> Bool {
        guard let input, let cached else { return true }
        let (cacheSide, overflow) = cached.addingReportingOverflow(cacheWrite ?? 0)
        return !overflow && cacheSide <= input
    }
}

// MARK: - Accumulator: owned Codex counter intervals

extension AgentUsageAccumulator {
    static let codexProviderName = "codex"
    static let codexUnmeasuredTurnDiagnostic = "turn ended without any usage notification; its work is unmeasured"
    static let codexUnmeasuredDispatchDiagnostic = "dispatched work was never bound to a turn before the execution ended; it is unmeasured"
    static let codexUnmeasuredAnonymousTurnDiagnostic = "dispatched work ended in a turn completion without a turn identity; it is unmeasured"
    static let codexLatestAwaitingUsageDetail = "Unavailable: the latest Codex dispatch has not reported observation.last request counters yet."

    /// Registers the controller generation as the Codex execution. A new generation resets
    /// in-memory ownership after marking the previous generation's still-uncovered dispatched
    /// work; persisted intervals are untouched. Idempotent for the same generation.
    mutating func beginCodexExecution(executionID: UUID, threadOrigin: CodexThreadOrigin) {
        guard codexState.activeExecutionID != executionID else { return }
        if let previous = codexState.activeExecutionID {
            markUnmeasuredCodexWork(
                executionID: previous,
                unboundDispatchDiagnostic: Self.codexUnmeasuredDispatchDiagnostic
            )
        }
        resetLatestRequestCacheHit(source: .codexLast)
        codexState = CodexUsageAccountingState()
        codexState.activeExecutionID = executionID
        codexState.baselineKnown = threadOrigin == .fresh
    }

    /// Registers an attempted dispatch on this execution and captures its immutable pricing basis
    /// when a snapshot is available. Dispatch tracking never depends on pricing: an unpriced
    /// dispatch is still bound, awaited and marked unmeasured when it ends without usage — it is
    /// merely unpriced. A still-unbound earlier dispatch is uncovered work and is marked before
    /// being replaced. The returned ticket scopes later acceptance or definitive rejection.
    @discardableResult
    mutating func registerCodexDispatch(executionID: UUID, requestedModelID: String?, pricing: OpenAIPricingSnapshot?) -> CodexDispatchTicket? {
        guard executionID == codexState.activeExecutionID else { return nil }
        if codexState.pendingDispatchTicket != nil {
            appendUnmeasuredMarker(executionID: executionID, turnID: nil, diagnostic: Self.codexUnmeasuredDispatchDiagnostic)
        }
        let ticket = CodexDispatchTicket(executionID: executionID, serial: codexState.nextDispatchSerial)
        codexState.nextDispatchSerial &+= 1
        codexState.pendingDispatchTicket = ticket
        codexState.pendingDispatchAccepted = false
        codexState.pendingDispatchBasis = pricing.map { CodexDispatchBasis(requestedModelID: requestedModelID, pricing: $0) }
        setLatestRequestCacheHit(.init(
            source: .codexLast,
            executionID: executionID,
            turnID: nil,
            requestID: "dispatch:\(ticket.serial)",
            share: nil,
            detail: Self.codexLatestAwaitingUsageDetail
        ))
        return ticket
    }

    /// Records acceptance proven by the typed start receipt. Only the exact current ticket can
    /// mutate the pending dispatch; a stale receipt cannot accept a successor.
    mutating func acceptCodexDispatch(_ ticket: CodexDispatchTicket?) {
        guard let ticket, ticket.executionID == codexState.activeExecutionID,
              codexState.pendingDispatchTicket == ticket
        else { return }
        codexState.pendingDispatchAccepted = true
    }

    /// Records acceptance proven by `turn/started` before inspecting its optional identity.
    /// Lifecycle notifications do not carry the local ticket, so they apply to the sole pending
    /// dispatch on the active controller generation.
    mutating func acceptCurrentCodexDispatch(executionID: UUID) {
        guard executionID == codexState.activeExecutionID,
              codexState.pendingDispatchTicket != nil
        else { return }
        codexState.pendingDispatchAccepted = true
    }

    /// Withdraws only a dispatch whose caller proved pre-send failure or definitive rejection.
    /// An exact ticket already accepted, consumed by a binding, superseded by a later dispatch or
    /// belonging to another execution is a no-op.
    mutating func withdrawCodexDispatch(_ ticket: CodexDispatchTicket?) {
        guard let ticket, ticket.executionID == codexState.activeExecutionID,
              codexState.pendingDispatchTicket == ticket,
              !codexState.pendingDispatchAccepted
        else { return }
        codexState.pendingDispatchTicket = nil
        codexState.pendingDispatchAccepted = false
        codexState.pendingDispatchBasis = nil
        if var latest = latestRequestCacheHit(for: .codexLast),
           latest.requestID == "dispatch:\(ticket.serial)"
        {
            latest.detail = "Unavailable: the latest Codex dispatch was definitively not submitted, so it has no request usage."
            setLatestRequestCacheHit(latest)
        }
    }

    /// Binds the pending dispatch (and its optional pricing basis) to the provider turn identity
    /// reported by `turn/started`, and records the turn's binding order whether or not a dispatch
    /// was pending. Re-binding a known turn keeps its original order and basis.
    mutating func bindCodexTurn(executionID: UUID, turnID: String) {
        guard executionID == codexState.activeExecutionID else { return }
        let pendingTicket = codexState.pendingDispatchTicket
        if codexState.bindingOrdinalByTurnID[turnID] == nil {
            codexState.bindingOrdinalByTurnID[turnID] = codexState.nextBindingOrdinal
            codexState.nextBindingOrdinal += 1
        }
        if pendingTicket != nil {
            if let pending = codexState.pendingDispatchBasis, codexState.basisByTurnID[turnID] == nil {
                codexState.basisByTurnID[turnID] = pending
            }
            if !codexState.settledTurnIDs.contains(turnID) {
                codexState.turnIDsAwaitingUsage.insert(turnID)
            }
        }
        codexState.pendingDispatchTicket = nil
        codexState.pendingDispatchAccepted = false
        codexState.pendingDispatchBasis = nil
        if let pendingTicket,
           var latest = latestRequestCacheHit(for: .codexLast),
           latest.requestID == "dispatch:\(pendingTicket.serial)",
           latest.turnID == nil
        {
            latest.turnID = turnID
            setLatestRequestCacheHit(latest)
        }
        if let rerouted = codexState.pendingRerouteModel, codexState.reroutedTurnIDs[turnID] == nil {
            codexState.reroutedTurnIDs[turnID] = rerouted
        }
        codexState.pendingRerouteModel = nil
    }

    /// The provider reported the turn terminal (completed, interrupted or failed). Dispatched
    /// work that never produced a usage observation is recorded as unmeasured, never as zero;
    /// a provably owned late observation for that turn still upserts the marker. The marker never
    /// touches `openTurn`: another turn's provable refinement ownership is unaffected.
    mutating func closeCodexTurn(executionID: UUID, turnID: String) {
        guard executionID == codexState.activeExecutionID else { return }
        guard codexState.turnIDsAwaitingUsage.remove(turnID) != nil else { return }
        if let index = appendUnmeasuredMarker(executionID: executionID, turnID: turnID, diagnostic: Self.codexUnmeasuredTurnDiagnostic) {
            codexState.unmeasuredMarkerIndexByTurnID[turnID] = index
        }
        if var latest = latestRequestCacheHit(for: .codexLast),
           latest.turnID == turnID,
           latest.share == nil,
           latest.detail == Self.codexLatestAwaitingUsageDetail
        {
            latest.detail = "Unavailable: the latest Codex turn ended without an observation.last request-usage report."
            setLatestRequestCacheHit(latest)
        }
    }

    /// The provider reported a turn terminal without a turn identity and the coordinator could
    /// not correlate it to a known turn. Outstanding dispatched work cannot be told apart from
    /// the completed turn, so all of it is recorded as unmeasured (a provably owned late
    /// observation for a bound turn still upserts its marker). Nothing outstanding is a no-op.
    mutating func closeUnidentifiedCodexTurn(executionID: UUID) {
        guard executionID == codexState.activeExecutionID else { return }
        markUnmeasuredCodexWork(executionID: executionID, unboundDispatchDiagnostic: Self.codexUnmeasuredAnonymousTurnDiagnostic)
    }

    /// The controller generation is ending (cancellation, failure, shutdown or replacement).
    /// Accepted amounts stay; every still-uncovered dispatch or bound turn becomes unmeasured.
    mutating func endCodexExecution(executionID: UUID) {
        guard executionID == codexState.activeExecutionID else { return }
        markUnmeasuredCodexWork(executionID: executionID, unboundDispatchDiagnostic: Self.codexUnmeasuredDispatchDiagnostic)
        resetLatestRequestCacheHit(source: .codexLast)
    }

    private mutating func markUnmeasuredCodexWork(executionID: UUID, unboundDispatchDiagnostic: String) {
        for turnID in codexState.turnIDsAwaitingUsage.sorted() {
            if let index = appendUnmeasuredMarker(executionID: executionID, turnID: turnID, diagnostic: Self.codexUnmeasuredTurnDiagnostic) {
                codexState.unmeasuredMarkerIndexByTurnID[turnID] = index
            }
        }
        codexState.turnIDsAwaitingUsage.removeAll()
        if codexState.pendingDispatchTicket != nil {
            appendUnmeasuredMarker(executionID: executionID, turnID: nil, diagnostic: unboundDispatchDiagnostic)
            codexState.pendingDispatchTicket = nil
            codexState.pendingDispatchAccepted = false
            codexState.pendingDispatchBasis = nil
        }
    }

    @discardableResult
    private mutating func appendUnmeasuredMarker(executionID: UUID, turnID: String?, diagnostic: String) -> Int? {
        guard qualification != .unqualified, eligibility == .eligible else { return nil }
        materializeRecordIfNeeded(at: Date())
        guard record != nil else { return nil }
        let marker = AgentProviderUsageRecord.CodexUsageInterval(
            executionID: executionID,
            turnID: turnID,
            turnAttribution: turnID == nil ? CodexUsageObservation.TurnAttribution.unknown.rawValue : CodexUsageObservation.TurnAttribution.notified.rawValue,
            ordinal: codexState.lastOrdinal,
            coverage: .unavailable,
            diagnostic: diagnostic
        )
        appendCodexInterval(marker, markUnmeasured: false)
        return (record?.codexIntervals?.count ?? 1) - 1
    }

    /// A known reroute makes every affected interval's cost partial/unpriced (requested-model
    /// pricing would be an unproven assumption); token counts stay owned. Intervals already
    /// priced for the named turn are invalidated too, however late the reroute arrives.
    mutating func noteCodexReroute(executionID: UUID, reroute: CodexModelReroute) {
        guard executionID == codexState.activeExecutionID else { return }
        var affectedIndices: [Int] = []
        if let turnID = reroute.turnID {
            codexState.reroutedTurnIDs[turnID] = reroute.toModel
            for (index, interval) in (record?.codexIntervals ?? []).enumerated()
                where interval.executionID == executionID
                && interval.turnID == turnID
                && interval.turnAttribution == CodexUsageObservation.TurnAttribution.notified.rawValue
                && interval.estimatedCostLowerUSD != nil
            {
                affectedIndices.append(index)
            }
        } else {
            codexState.pendingRerouteModel = reroute.toModel
            if let open = codexState.openTurn, let openIndex = open.intervalIndex, let intervals = record?.codexIntervals,
               intervals.indices.contains(openIndex), intervals[openIndex].estimatedCostLowerUSD != nil
            {
                affectedIndices.append(openIndex)
            }
        }
        guard !affectedIndices.isEmpty, var intervals = record?.codexIntervals else { return }
        for index in affectedIndices {
            intervals[index].estimatedCostLowerUSD = nil
            intervals[index].estimatedCostUpperUSD = nil
            intervals[index].appliedPricing = nil
            intervals[index].coverage = .partial
            intervals[index].diagnostic = "model rerouted to \(reroute.toModel); interval not priced"
        }
        record?.codexIntervals = intervals
        bumpRevision()
    }

    /// Ingests one cumulative `total` observation as a disjoint owned interval since the previous
    /// accepted checkpoint. Duplicates and older-turn replays are no-ops; a notified refinement
    /// of the open turn upserts that turn's interval from the turn's own baseline; an unknown
    /// inherited baseline or a decrease against the latest checkpoint starts prospective tracking
    /// (nothing charged, unmeasured history).
    ///
    /// Older-turn rejection uses binding order, not reporting history: a notified observation for
    /// a turn bound before the turn that owns the latest accepted checkpoint is demonstrably
    /// older (its first report arrived late) and is rejected with no state change — never
    /// rebaselined, so a later turn's interval cannot overlap it. Its work stays covered by the
    /// later turn's accepted interval (partial/unavailable coverage, never a double count).
    @discardableResult
    mutating func observeCodexUsage(_ observation: CodexUsageObservation, executionID: UUID, at now: Date) -> AgentUsageIngestOutcome {
        guard qualification != .unqualified else { return .rejected(.unqualifiedContract) }
        guard eligibility == .eligible else { return .rejected(.ineligibleOwner) }
        guard executionID == codexState.activeExecutionID else { return .rejected(.disposedExecution) }
        guard observation.ordinal > codexState.lastOrdinal else { return .rejected(.duplicateResult) }
        codexState.lastOrdinal = observation.ordinal
        let notifiedTurnID = observation.turnAttribution == .notified ? observation.turnID : nil
        if let notifiedTurnID, codexState.settledTurnIDs.contains(notifiedTurnID),
           codexState.openTurn?.turnID != notifiedTurnID
        {
            return .rejected(.replayedOrSynthetic)
        }
        if let notifiedTurnID, let ordinal = codexState.bindingOrdinalByTurnID[notifiedTurnID],
           let latest = codexState.lastAcceptedTurnOrdinal, ordinal < latest
        {
            return .rejected(.replayedOrSynthetic)
        }

        // observation.last is the request-level authority. It is projected separately from the
        // cumulative total interval below and only for the newest provider-notified,
        // dispatch-bound turn. Missing last clears the prior request value instead of retaining it.
        if let notifiedTurnID,
           codexState.bindingOrdinalByTurnID[notifiedTurnID] == codexState.nextBindingOrdinal - 1,
           let latest = latestRequestCacheHit(for: .codexLast),
           latest.turnID == notifiedTurnID
        {
            setLatestRequestCacheHit(Self.codexLatestRequestProjection(
                counters: observation.last,
                executionID: executionID,
                turnID: notifiedTurnID
            ))
        } else if observation.turnAttribution != .notified,
                  var latest = latestRequestCacheHit(for: .codexLast)
        {
            latest.share = nil
            latest.detail = "Unavailable: Codex reported observation.last without a provider-notified current turn identity, so it is not shown as latest-request CH."
            setLatestRequestCacheHit(latest)
        }

        guard let total = observation.total, !total.isEmpty else { return .rejected(.unidentifiedObservation) }
        guard CodexUsagePricing.isValidCheckpoint(total) else { return .rejected(.unidentifiedObservation) }
        if total == codexState.lastAcceptedTotal {
            return .accepted
        }
        materializeRecordIfNeeded(at: now)
        guard record != nil else { return .rejected(.ineligibleOwner) }

        var interval = AgentProviderUsageRecord.CodexUsageInterval(
            executionID: executionID,
            threadID: observation.threadID,
            turnID: observation.turnID,
            turnAttribution: observation.turnAttribution.rawValue,
            ordinal: observation.ordinal,
            coverage: .partial
        )
        let previous: CodexUsageObservation.Counters? = codexState.lastAcceptedTotal ?? (codexState.baselineKnown ? .zero : nil)
        guard let previous else {
            rebaselineProspectively(to: total, notifiedTurnID: notifiedTurnID)
            interval.diagnostic = "inherited usage baseline unknown; this checkpoint starts prospective tracking"
            appendCodexInterval(interval, markUnmeasured: true)
            return .accepted
        }

        // Monotonicity against the latest accepted checkpoint, independent of the upsert baseline.
        guard let checkpointDelta = CodexUsagePricing.delta(from: previous, to: total) else {
            rebaselineProspectively(to: total, notifiedTurnID: notifiedTurnID)
            interval.diagnostic = "counter arithmetic overflowed; rebaselined prospectively"
            appendCodexInterval(interval, markUnmeasured: true)
            return .acceptedWithMonetaryRejection(.invalidCost)
        }
        if checkpointDelta.hasNegativeComponent {
            rebaselineProspectively(to: total, notifiedTurnID: notifiedTurnID)
            interval.diagnostic = "cumulative counters decreased below the last accepted checkpoint; rebaselined prospectively"
            appendCodexInterval(interval, markUnmeasured: true)
            return .acceptedWithMonetaryRejection(.unexplainedDecrease)
        }

        var baseline = previous
        var upsertIndex: Int?
        var bandFloor: OpenAIPricingContextBand.Kind?
        if let notifiedTurnID, let open = codexState.openTurn, open.turnID == notifiedTurnID {
            baseline = open.baselineTotal
            upsertIndex = open.intervalIndex
            bandFloor = open.appliedBandKind
        }
        let openBaseline = baseline
        guard let delta = CodexUsagePricing.delta(from: baseline, to: total), !delta.hasNegativeComponent else {
            rebaselineProspectively(to: total, notifiedTurnID: notifiedTurnID)
            interval.diagnostic = "counter arithmetic overflowed; rebaselined prospectively"
            appendCodexInterval(interval, markUnmeasured: true)
            return .acceptedWithMonetaryRejection(.invalidCost)
        }
        interval.inputTokens = delta.input
        interval.cachedInputTokens = delta.cached
        interval.cacheWriteInputTokens = delta.cacheWrite
        interval.outputTokens = delta.output
        interval.reasoningOutputTokens = delta.reasoningOutput

        var diagnostics: [String] = []
        var complete = false
        let subsetsConsistent = CodexUsagePricing.hasConsistentInputSubsets(input: delta.input, cached: delta.cached, cacheWrite: delta.cacheWrite)
        if !subsetsConsistent {
            diagnostics.append("cached and cache-write input exceed input; excluded from the cache share and not priced")
        }
        switch observation.turnAttribution {
        case .notified:
            let turnID = observation.turnID ?? ""
            if !subsetsConsistent {
                break
            }
            if let toModel = codexState.reroutedTurnIDs[turnID] {
                diagnostics.append("model rerouted to \(toModel); interval not priced")
            } else if let basis = codexState.basisByTurnID[turnID] {
                interval.pricingVersion = basis.pricing.pricingVersion
                interval.requestedModelID = basis.requestedModelID
                if let model = basis.requestedModelID, let resolution = basis.pricing.rates(forModelID: model) {
                    interval.resolvedModelID = resolution.resolvedModelID
                    // The band comes from the context window proof or the latest request's
                    // prompt size (the official qualifier is per request), never the summed
                    // interval, and never drops below a band this turn was already priced at.
                    let applied = CodexUsagePricing.estimate(
                        delta,
                        requestContextTokens: observation.last?.inputTokens.map(Int64.init),
                        modelContextWindow: observation.modelContextWindow.map(Int64.init),
                        minimumBand: bandFloor,
                        resolution: resolution
                    )
                    interval.bandKind = applied.bandKind
                    switch applied.estimate {
                    case let .point(value):
                        // The persisted schema keeps lower/upper; a point writes both equal.
                        interval.estimatedCostLowerUSD = value
                        interval.estimatedCostUpperUSD = value
                        interval.appliedPricing = .init(
                            snapshot: basis.pricing,
                            lowerRates: applied.appliedRates,
                            upperRates: applied.appliedRates
                        )
                        if let assumption = applied.assumption {
                            diagnostics.append(assumption)
                        }
                        complete = true
                    case let .unavailable(reason):
                        diagnostics.append("not priced: \(reason)")
                    }
                } else {
                    diagnostics.append("no Standard/global list price for requested model \(basis.requestedModelID ?? "unknown")")
                }
            } else {
                diagnostics.append("no dispatch pricing basis bound to this turn")
            }
        case .inferredCurrentTurn:
            diagnostics.append("turn identity inferred from routing state only; interval not priced")
        case .unknown:
            diagnostics.append("no turn identity; interval not priced")
        }
        let countsComplete = delta.input != nil && delta.cached != nil && delta.output != nil
        interval.coverage = complete && countsComplete && subsetsConsistent ? .complete : .partial
        interval.diagnostic = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")

        let appliedBandKind = Self.higherBand(bandFloor, interval.bandKind.flatMap(OpenAIPricingContextBand.Kind.init(rawValue:)))
        codexState.lastAcceptedTotal = total
        settleTurn(notifiedTurnID)
        if let upsertIndex, var intervals = record?.codexIntervals, intervals.indices.contains(upsertIndex) {
            intervals[upsertIndex] = interval
            record?.codexIntervals = intervals
            bumpRevision()
            codexState.openTurn?.appliedBandKind = appliedBandKind
        } else if let notifiedTurnID, let markerIndex = codexState.unmeasuredMarkerIndexByTurnID[notifiedTurnID],
                  var intervals = record?.codexIntervals, intervals.indices.contains(markerIndex)
        {
            // A provably owned late observation replaces the turn's unmeasured marker in place.
            codexState.unmeasuredMarkerIndexByTurnID.removeValue(forKey: notifiedTurnID)
            intervals[markerIndex] = interval
            record?.codexIntervals = intervals
            bumpRevision()
            codexState.openTurn = .init(turnID: notifiedTurnID, baselineTotal: openBaseline, intervalIndex: markerIndex, appliedBandKind: appliedBandKind)
        } else {
            appendCodexInterval(interval, markUnmeasured: false)
            if let notifiedTurnID {
                codexState.openTurn = .init(
                    turnID: notifiedTurnID,
                    baselineTotal: openBaseline,
                    intervalIndex: (record?.codexIntervals?.count ?? 1) - 1,
                    appliedBandKind: appliedBandKind
                )
            } else {
                codexState.openTurn = nil
            }
        }
        return .accepted
    }

    /// Nothing is charged from this checkpoint; a later same-turn observation appends from it.
    /// The same turn keeps its band floor.
    private mutating func rebaselineProspectively(to total: CodexUsageObservation.Counters, notifiedTurnID: String?) {
        codexState.lastAcceptedTotal = total
        let floor = codexState.openTurn.flatMap { $0.turnID == notifiedTurnID ? $0.appliedBandKind : nil }
        codexState.openTurn = notifiedTurnID.map { .init(turnID: $0, baselineTotal: total, intervalIndex: nil, appliedBandKind: floor) }
        settleTurn(notifiedTurnID)
    }

    /// `.longContext` outranks every other band; otherwise the newer kind wins.
    private static func higherBand(
        _ floor: OpenAIPricingContextBand.Kind?,
        _ applied: OpenAIPricingContextBand.Kind?
    ) -> OpenAIPricingContextBand.Kind? {
        floor == .longContext ? .longContext : (applied ?? floor)
    }

    /// Records that `notifiedTurnID` owns the latest accepted checkpoint (settled, no longer
    /// awaiting usage, and the ordering authority for older-turn rejection).
    private mutating func settleTurn(_ notifiedTurnID: String?) {
        guard let notifiedTurnID else { return }
        codexState.settledTurnIDs.insert(notifiedTurnID)
        codexState.turnIDsAwaitingUsage.remove(notifiedTurnID)
        if let ordinal = codexState.bindingOrdinalByTurnID[notifiedTurnID] {
            codexState.lastAcceptedTurnOrdinal = max(codexState.lastAcceptedTurnOrdinal ?? ordinal, ordinal)
        }
    }

    private mutating func appendCodexInterval(_ interval: AgentProviderUsageRecord.CodexUsageInterval, markUnmeasured: Bool) {
        var intervals = record?.codexIntervals ?? []
        intervals.append(interval)
        record?.codexIntervals = intervals
        if markUnmeasured {
            record?.hasUnmeasuredHistory = true
        }
        bumpRevision()
    }

    private static func codexLatestRequestProjection(
        counters: CodexUsageObservation.Counters?,
        executionID: UUID,
        turnID: String
    ) -> AgentUsageLatestRequestCacheHit {
        guard let counters else {
            return .init(
                source: .codexLast,
                executionID: executionID,
                turnID: turnID,
                requestID: turnID,
                share: nil,
                detail: "Unavailable: the latest Codex token-usage notification omitted observation.last."
            )
        }
        let fields: [(String, Int?)] = [
            ("input", counters.inputTokens),
            ("cached-input", counters.cachedInputTokens)
        ]
        let missing = fields.compactMap { $0.1 == nil ? $0.0 : nil }
        guard missing.isEmpty, let input = counters.inputTokens, let cached = counters.cachedInputTokens else {
            return .init(
                source: .codexLast,
                executionID: executionID,
                turnID: turnID,
                requestID: turnID,
                share: nil,
                detail: "Unavailable: Codex observation.last omitted \(missing.joined(separator: ", ")) counter\(missing.count == 1 ? "" : "s") for the latest request."
            )
        }
        guard input >= 0, cached >= 0 else {
            return .init(
                source: .codexLast,
                executionID: executionID,
                turnID: turnID,
                requestID: turnID,
                share: nil,
                detail: "Unavailable: Codex observation.last contained an invalid negative input counter for the latest request."
            )
        }
        guard CodexUsagePricing.hasConsistentInputSubsets(
            input: Int64(input),
            cached: Int64(cached),
            cacheWrite: counters.cacheWriteInputTokens.map(Int64.init)
        ) else {
            return .init(
                source: .codexLast,
                executionID: executionID,
                turnID: turnID,
                requestID: turnID,
                share: nil,
                detail: "Unavailable: Codex observation.last reported cached-input and cache-write subsets whose combined count exceeds total input for the latest request."
            )
        }
        guard input > 0 else {
            return .init(
                source: .codexLast,
                executionID: executionID,
                turnID: turnID,
                requestID: turnID,
                share: nil,
                detail: "Unavailable: Codex observation.last reported zero input tokens for the latest request; CH is undefined, not 0%."
            )
        }
        return .init(
            source: .codexLast,
            executionID: executionID,
            turnID: turnID,
            requestID: turnID,
            share: .init(ratio: Decimal(cached) / Decimal(input), coverage: .complete),
            detail: "Complete: Codex observation.last reported input and cached-input counters for the latest live provider-notified request."
        )
    }

    // MARK: Codex projections

    /// `sum(cached input) / sum(input)` over owned intervals with both counters and consistent
    /// input subsets. Zero denominator or overflow is unavailable; excluded or unmeasured
    /// intervals make coverage partial.
    var codexCacheHitShare: AgentUsageCacheHitShare? {
        guard let record, let intervals = record.codexIntervals else { return nil }
        var cached: Int64 = 0
        var input: Int64 = 0
        var contributing = 0
        var excluded = 0
        for interval in intervals {
            guard let intervalInput = interval.inputTokens, let intervalCached = interval.cachedInputTokens,
                  intervalInput >= 0, intervalCached >= 0,
                  CodexUsagePricing.hasConsistentInputSubsets(input: intervalInput, cached: intervalCached, cacheWrite: interval.cacheWriteInputTokens)
            else {
                excluded += 1
                continue
            }
            let (nextInput, overflow1) = input.addingReportingOverflow(intervalInput)
            let (nextCached, overflow2) = cached.addingReportingOverflow(intervalCached)
            guard !overflow1, !overflow2 else { return nil }
            input = nextInput
            cached = nextCached
            contributing += 1
        }
        guard contributing > 0, input > 0 else { return nil }
        let complete = excluded == 0 && !record.hasUnmeasuredHistory
        return .init(ratio: Decimal(cached) / Decimal(input), coverage: complete ? .complete : .partial)
    }

    /// Sum of priced disjoint intervals as one point. Legacy intervals persisted as a range
    /// contribute their lower bound. Any unpriced, partially priced or unmeasured interval, or
    /// unmeasured history, makes coverage partial; `nil` when nothing could be priced.
    var codexSessionCostEstimate: CodexCostEstimate? {
        guard let record, let intervals = record.codexIntervals else { return nil }
        var amount = Decimal(0)
        var priced = 0
        var partial = record.hasUnmeasuredHistory
        for interval in intervals {
            if let intervalAmount = interval.estimatedCostLowerUSD {
                amount += intervalAmount
                priced += 1
            } else {
                partial = true
            }
            if interval.coverage != .complete {
                partial = true
            }
        }
        guard priced > 0 else { return nil }
        return .init(amount: amount, currency: CodexUsagePricing.currency, coverage: partial ? .partial : .complete)
    }

    /// Owned intervals whose cost could not be calculated (reroute, unbound basis, unlisted price,
    /// inferred attribution, inconsistent counters, prospective baseline). Unmeasured-work
    /// markers are counted separately.
    var codexUnpricedIntervalCount: Int {
        record?.codexIntervals?.count(where: { $0.estimatedCostLowerUSD == nil && $0.coverage != .unavailable }) ?? 0
    }

    /// Dispatched turns (or unbound dispatches) that ended without any usage observation.
    var codexUnmeasuredWorkCount: Int {
        record?.codexIntervals?.count(where: { $0.coverage == .unavailable }) ?? 0
    }

    var codexIntervalCount: Int {
        record?.codexIntervals?.count ?? 0
    }

    /// Pricing version(s) frozen into the priced intervals, for provenance wording.
    var codexPricingVersions: [String] {
        Array(Set((record?.codexIntervals ?? []).compactMap { $0.estimatedCostLowerUSD == nil ? nil : $0.pricingVersion })).sorted()
    }

    /// Provenance of the frozen pricing actually applied to priced intervals; `nil` when none.
    var codexPricingProvenance: CodexPricingProvenance? {
        let priced = (record?.codexIntervals ?? []).filter { $0.estimatedCostLowerUSD != nil }
        guard !priced.isEmpty else { return nil }
        let applied = priced.compactMap(\.appliedPricing)
        return .init(
            pricingVersions: codexPricingVersions,
            earliestCapturedAt: applied.map(\.capturedAt).min(),
            latestCapturedAt: applied.map(\.capturedAt).max(),
            latestValidatedAt: applied.map(\.validatedAt).max(),
            staleIntervalCount: applied.count(where: \.wasStale)
        )
    }
}
