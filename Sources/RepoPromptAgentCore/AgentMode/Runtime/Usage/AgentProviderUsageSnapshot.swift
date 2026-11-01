import Foundation

package struct AgentProviderUsageSnapshot: Equatable {
    enum Scope: Equatable {
        case claude
        case codex
        case unsupported(String)
    }

    /// Two labelled values for every scope: the latest-request cache-hit ratio and the
    /// accumulated session API cost estimate. Coverage, scope, pricing basis and provenance live
    /// only in `detailText` / `expandedDetailText`, never in the values themselves.
    package struct Presentation: Equatable {
        package static let cacheHitRatioLabel = "Cache Hit Ratio"
        package static let costEstimateLabel = "API Cost Estimates"
        package static let unavailableValue = "—"

        /// Names the accounted provider for assistive technologies; never a visible label.
        package var accessibilityLabel: String
        /// Latest-request CH such as `99.8%`, or `—`.
        package var cacheHitRatioValue: String
        /// Accumulated session cost such as `$206.70` (or `<$0.01`), or `—`.
        package var costEstimateValue: String
        /// Full scope/coverage explanation for tooltips and accessibility.
        package var detailText: String
        /// Additional content rendered inside the context-pill popover. It keeps the compact
        /// rows limited to latest-request CH plus accumulated session cost.
        package var expandedDetailText: String?
        /// Short explanation hosts may render visibly next to the readout: why no figures are
        /// shown, or why shown figures are only partial. `nil` when nothing needs explaining.
        package var noteText: String?

        init(
            accessibilityLabel: String,
            cacheHitRatioValue: String,
            costEstimateValue: String,
            detailText: String,
            expandedDetailText: String? = nil,
            noteText: String? = nil
        ) {
            self.accessibilityLabel = accessibilityLabel
            self.cacheHitRatioValue = cacheHitRatioValue
            self.costEstimateValue = costEstimateValue
            self.detailText = detailText
            self.expandedDetailText = expandedDetailText
            self.noteText = noteText
        }

        /// Fixed for every scope; never carries a provider name or coverage qualifier.
        package var cacheHitRatioLabel: String {
            Self.cacheHitRatioLabel
        }

        package var costEstimateLabel: String {
            Self.costEstimateLabel
        }

        /// `Cache Hit Ratio: 99.8%`
        package var cacheHitRatioLine: String {
            "\(cacheHitRatioLabel): \(cacheHitRatioValue)"
        }

        /// `API Cost Estimates: $206.70`
        package var costEstimateLine: String {
            "\(costEstimateLabel): \(costEstimateValue)"
        }

        /// Single-line convenience form of both labelled values.
        package var readoutText: String {
            "\(cacheHitRatioLine) · \(costEstimateLine)"
        }
    }

    var scope: Scope
    var trackingStartedAt: Date?
    /// Live-only request-level CH. Persisted turn/result aggregates never populate it.
    var latestRequestCacheHit: AgentUsageLatestRequestCacheHit?
    /// Token-weighted CH over the persisted session ledger.
    var cacheHitShare: AgentUsageCacheHitShare?
    var costEstimate: AgentUsageCostEstimate?
    /// Pricing provenance for Codex (frozen pricing version(s) used by the priced intervals).
    var pricingProvenance: String?
    /// Explains why restored read-only values cannot claim current full-session coverage.
    var coverageDetail: String?
    /// Concrete per-metric coverage text used by the expanded popover.
    var sessionCacheCoverageDetail: String?
    var sessionCostCoverageDetail: String?
    /// Accepted accounting mutations only. This lets lifecycle changes publish through the
    /// existing equality guard without making transcript text a usage update signal.
    package var accountingRevision: UInt64?
    /// Explains why a Claude readout shows no figures (gated live accounting, missing record,
    /// foreign ownership, or an unsupported persisted value). `nil` when figures are shown.
    var unavailableReason: String?

    /// Explains a Claude readout with no accounting owner or a lifecycle-only (`.unqualified`)
    /// policy: nothing was measured, which is distinct from a measured zero.
    static let claudeLiveAccountingGatedReason =
        "No live figures: usage accounting is not counting this session's turns. Only restored session accounting can display, and it is marked partial."
    static let claudeNoUsageRecordedReason = "No usage has been recorded for this session yet."

    init(
        scope: Scope,
        trackingStartedAt: Date? = nil,
        latestRequestCacheHit: AgentUsageLatestRequestCacheHit? = nil,
        cacheHitShare: AgentUsageCacheHitShare? = nil,
        costEstimate: AgentUsageCostEstimate? = nil,
        pricingProvenance: String? = nil,
        coverageDetail: String? = nil,
        sessionCacheCoverageDetail: String? = nil,
        sessionCostCoverageDetail: String? = nil,
        accountingRevision: UInt64? = nil,
        unavailableReason: String? = nil
    ) {
        self.scope = scope
        self.trackingStartedAt = trackingStartedAt
        self.latestRequestCacheHit = latestRequestCacheHit
        self.cacheHitShare = cacheHitShare
        self.costEstimate = costEstimate
        self.pricingProvenance = pricingProvenance
        self.coverageDetail = coverageDetail
        self.sessionCacheCoverageDetail = sessionCacheCoverageDetail
        self.sessionCostCoverageDetail = sessionCostCoverageDetail
        self.accountingRevision = accountingRevision
        self.unavailableReason = unavailableReason
    }

    /// No accounting owner at all (no session, or no accumulator installed yet). Claude scope
    /// still explains itself so an empty readout is never a silent dash.
    package static func unavailable(for selectedAgent: AgentProviderKind?) -> Self {
        let resolvedScope = scope(for: selectedAgent)
        return .init(
            scope: resolvedScope,
            unavailableReason: resolvedScope == .claude || resolvedScope == .codex ? claudeNoUsageRecordedReason : nil
        )
    }

    /// Projects only an owned, semantically valid accounting record. A strict lossless view of
    /// an opaque v1 value is eligible; unsupported opaque data and foreign origins remain
    /// unavailable. Production's unqualified gate may expose hydrated data but never live
    /// mutations, because an unqualified accumulator is accepted only at revision zero.
    static func projected(
        selectedAgent: AgentProviderKind?,
        accounting: AgentUsageAccumulator?,
        expectedOwnerSessionID: UUID?
    ) -> Self {
        let resolvedScope = scope(for: selectedAgent)
        if resolvedScope == .codex {
            return projectedCodex(accounting: accounting, expectedOwnerSessionID: expectedOwnerSessionID)
        }
        guard resolvedScope == .claude,
              let expectedOwnerSessionID,
              let accounting,
              accounting.ownerSessionID == expectedOwnerSessionID,
              accounting.eligibility == .eligible,
              let record = accounting.record,
              record.originSessionID == expectedOwnerSessionID,
              record.semanticViolation == nil,
              accounting.qualification != .unqualified || accounting.ownedRevision == 0
        else {
            return .init(
                scope: resolvedScope,
                unavailableReason: resolvedScope == .claude
                    ? claudeUnavailableReason(
                        accounting: accounting,
                        expectedOwnerSessionID: expectedOwnerSessionID
                    )
                    : nil
            )
        }
        var cacheHitShare = accounting.cacheHitShare
        var costEstimate = accounting.sessionCostEstimate
        var coverageDetail: String?
        var details: [String] = []
        var cacheCurrentDetails: [String] = []
        var costCurrentDetails: [String] = []
        // Restored `.open` turns/segments from a disposed execution are work that never closed;
        // under every policy they make displayed coverage partial and are named explicitly.
        if accounting.hasAbandonedHydratedLifecycleState {
            if cacheHitShare != nil {
                cacheHitShare?.coverage = .partial
            }
            if costEstimate != nil {
                costEstimate?.coverage = .partial
            }
            let detail = "The restored state includes unfinished work."
            details.append(detail)
            cacheCurrentDetails.append(detail)
            costCurrentDetails.append(detail)
        }
        if accounting.qualification == .executionVerified,
           let diagnostic = accounting.executionQualificationDiagnostic
        {
            // Figures come only from qualified executions; an active execution that cannot
            // charge makes any dispatched work explicitly uncounted.
            let detail: String
            if accounting.hasUnchargedDispatchedWork {
                if cacheHitShare != nil {
                    cacheHitShare?.coverage = .partial
                }
                if costEstimate != nil {
                    costEstimate?.coverage = .partial
                }
                detail = "The current continuation is not counted: \(diagnostic)."
            } else if case .awaiting? = accounting.executionVerdict {
                detail = "The current continuation is not counting yet: \(diagnostic)."
            } else {
                detail = "The current continuation cannot be counted: \(diagnostic)."
            }
            details.append(detail)
            cacheCurrentDetails.append(detail)
            costCurrentDetails.append(detail)
        }
        if accounting.qualification == .executionVerified, let diagnostic = accounting.monetaryScopeDiagnostic {
            let detail = "The current continuation counts tokens only: \(diagnostic)."
            details.append(detail)
            costCurrentDetails.append(detail)
        }
        let childTurns = accounting.childActivityTurnCount
        if childTurns > 0 {
            details.append(
                "Native child (subagent) activity occurred in \(childTurns) turn\(childTurns == 1 ? "" : "s"); the cost estimate includes it, while those turns' result usage is excluded from CH because its main-loop scope cannot be proven."
            )
            cacheCurrentDetails.append(
                "Native child (subagent) activity occurred in \(childTurns) turn\(childTurns == 1 ? "" : "s"); those turns' result usage is excluded from CH because its main-loop scope cannot be proven."
            )
        }
        if accounting.qualification == .unqualified {
            if cacheHitShare != nil {
                cacheHitShare?.coverage = .partial
            }
            if costEstimate != nil {
                costEstimate?.coverage = .partial
            }
            let unqualified = "These figures are restored historical accounting; current runtime tracking is unqualified, so coverage is partial."
            details.insert(unqualified, at: 0)
            cacheCurrentDetails.append(unqualified)
            costCurrentDetails.append(unqualified)
            if accounting.activeExecutionID != nil {
                let unmeasured = "The current continuation is unmeasured."
                details.append(unmeasured)
                cacheCurrentDetails.append(unmeasured)
                costCurrentDetails.append(unmeasured)
            }
        }
        if !details.isEmpty {
            coverageDetail = details.joined(separator: " ")
        }
        return .init(
            scope: resolvedScope,
            trackingStartedAt: record.trackingStartedAt,
            latestRequestCacheHit: accounting.latestRequestCacheHit(for: .claudeAssistant),
            cacheHitShare: cacheHitShare,
            costEstimate: costEstimate,
            coverageDetail: coverageDetail,
            sessionCacheCoverageDetail: claudeSessionCacheCoverageDetail(
                record: record,
                share: cacheHitShare,
                currentDetail: cacheCurrentDetails.isEmpty
                    ? nil
                    : uniqueDetails(cacheCurrentDetails).joined(separator: " ")
            ),
            sessionCostCoverageDetail: claudeSessionCostCoverageDetail(
                record: record,
                estimate: costEstimate,
                currentDetail: costCurrentDetails.isEmpty
                    ? nil
                    : uniqueDetails(costCurrentDetails).joined(separator: " ")
            ),
            accountingRevision: accounting.ownedRevision
        )
    }

    /// Codex scope (plan §4.1): owned counter intervals priced locally from the frozen
    /// Standard/global list-price snapshot captured at each dispatch.
    private static func projectedCodex(
        accounting: AgentUsageAccumulator?,
        expectedOwnerSessionID: UUID?
    ) -> Self {
        guard let expectedOwnerSessionID,
              let accounting,
              accounting.ownerSessionID == expectedOwnerSessionID,
              accounting.eligibility == .eligible,
              accounting.qualification != .unqualified
        else {
            return .init(
                scope: .codex,
                unavailableReason: claudeUnavailableReason(
                    accounting: accounting,
                    expectedOwnerSessionID: expectedOwnerSessionID
                )
            )
        }

        let latest = accounting.latestRequestCacheHit(for: .codexLast)
        guard let record = accounting.record else {
            return .init(
                scope: .codex,
                latestRequestCacheHit: latest,
                sessionCacheCoverageDetail: "Unavailable: no persisted Codex session intervals have been recorded.",
                sessionCostCoverageDetail: "Unavailable: no persisted Codex session intervals have been recorded.",
                accountingRevision: accounting.ownedRevision,
                unavailableReason: latest == nil ? claudeNoUsageRecordedReason : nil
            )
        }
        guard record.originSessionID == expectedOwnerSessionID, record.semanticViolation == nil else {
            return .init(
                scope: .codex,
                unavailableReason: claudeUnavailableReason(
                    accounting: accounting,
                    expectedOwnerSessionID: expectedOwnerSessionID
                )
            )
        }

        let intervals = record.codexIntervals ?? []
        let cacheShare = accounting.codexCacheHitShare
        let cost = accounting.codexSessionCostEstimate
        // A completely priced interval's diagnostic is only a stated pricing assumption; it is
        // disclosed with the session cost coverage, not as a coverage problem.
        var details = uniqueDetails(intervals.compactMap { interval in
            interval.estimatedCostLowerUSD != nil && interval.coverage == .complete ? nil : interval.diagnostic
        })
        if record.hasUnmeasuredHistory {
            details.append(
                "Earlier Codex usage is marked unmeasured; the persisted record does not store a separate historical cause."
            )
        }
        return .init(
            scope: .codex,
            trackingStartedAt: intervals.isEmpty ? nil : record.trackingStartedAt,
            latestRequestCacheHit: latest,
            cacheHitShare: cacheShare,
            costEstimate: cost.map { .init(amount: $0.amount, currency: $0.currency, coverage: $0.coverage) },
            pricingProvenance: accounting.codexPricingProvenance.map(codexPricingProvenanceText),
            coverageDetail: details.isEmpty ? nil : details.joined(separator: " "),
            sessionCacheCoverageDetail: codexSessionCacheCoverageDetail(
                record: record,
                intervals: intervals,
                share: cacheShare
            ),
            sessionCostCoverageDetail: codexSessionCostCoverageDetail(
                record: record,
                intervals: intervals,
                estimate: cost
            ),
            accountingRevision: accounting.ownedRevision,
            unavailableReason: intervals.isEmpty && latest == nil ? claudeNoUsageRecordedReason : nil
        )
    }

    package var presentation: Presentation {
        switch scope {
        case .claude:
            claudePresentation
        case .codex:
            codexPresentation
        case let .unsupported(providerName):
            .init(
                accessibilityLabel: "\(providerName) usage",
                cacheHitRatioValue: Presentation.unavailableValue,
                costEstimateValue: Presentation.unavailableValue,
                detailText: "Cache hit (CH) share and cost are unavailable for \(providerName).",
                noteText: "Usage accounting is unavailable for \(providerName)."
            )
        }
    }

    /// Names the first failed projection precondition for a Claude scope. Ordering mirrors the
    /// `projected` guard so the explanation matches the branch that actually rejected the record.
    private static func claudeUnavailableReason(
        accounting: AgentUsageAccumulator?,
        expectedOwnerSessionID: UUID?
    ) -> String {
        guard let expectedOwnerSessionID else {
            return "No active session owns usage accounting."
        }
        guard let accounting else {
            return claudeNoUsageRecordedReason
        }
        guard accounting.ownerSessionID == expectedOwnerSessionID else {
            return "Usage accounting belongs to a different session and is not shown here."
        }
        switch accounting.eligibility {
        case .foreignOrigin:
            return "The restored usage record originated in a different session; it is preserved but not counted here."
        case .opaquePersistedValue:
            return "The restored usage value is not supported by this build; it is preserved unchanged and not shown."
        case .eligible:
            break
        }
        guard let record = accounting.record else {
            if accounting.qualification == .unqualified {
                return claudeLiveAccountingGatedReason
            }
            if let diagnostic = accounting.executionQualificationDiagnostic {
                return "No live figures: \(diagnostic). This session's turns are not counted."
            }
            return "No usage has been recorded for this session yet."
        }
        guard record.originSessionID == expectedOwnerSessionID else {
            return "The restored usage record originated in a different session; it is preserved but not counted here."
        }
        guard record.semanticViolation == nil else {
            return "The restored usage record is not semantically valid; it is preserved unchanged and not shown."
        }
        return "Usage accounting cannot be shown for the current session state."
    }

    private static func claudeSessionCacheCoverageDetail(
        record: AgentProviderUsageRecord,
        share: AgentUsageCacheHitShare?,
        currentDetail: String?
    ) -> String {
        var reasons = record.turns.compactMap { turn -> String? in
            guard turn.outcome != .open, turn.coverage != .complete else { return nil }
            if let diagnostic = turn.diagnostic {
                return diagnostic.contains("monetary checkpoint rejected") ? nil : diagnostic
            }
            let missing = [
                turn.inputTokens == nil ? "input" : nil,
                turn.cacheReadInputTokens == nil ? "cache-read" : nil,
                turn.cacheCreationInputTokens == nil ? "cache-creation" : nil
            ].compactMap(\.self)
            return missing.isEmpty
                ? "A finalized Claude turn is marked incomplete; its historical cause was not recorded."
                : "A finalized Claude turn omitted \(missing.joined(separator: ", ")) counters."
        }
        if record.hasUnmeasuredHistory {
            reasons.append(
                "Earlier Claude usage is marked unmeasured; the persisted record does not store a separate historical cause."
            )
        }
        if let currentDetail {
            reasons.append(currentDetail)
        }
        reasons = uniqueDetails(reasons)
        guard let share else {
            let cause = reasons.isEmpty
                ? "No finalized turn has a complete, nonzero input/cache-read/cache-creation denominator."
                : reasons.joined(separator: " ")
            return "Unavailable: \(cause)"
        }
        guard share.coverage == .partial else {
            let complete = "Complete: every finalized measured turn supplied the counters used by this metric."
            return reasons.isEmpty ? complete : "\(complete) \(reasons.joined(separator: " "))"
        }
        return reasons.isEmpty
            ? "Partial: the persisted value is marked partial, but its historical cause was not recorded."
            : "Partial: \(reasons.joined(separator: " "))"
    }

    private static func claudeSessionCostCoverageDetail(
        record: AgentProviderUsageRecord,
        estimate: AgentUsageCostEstimate?,
        currentDetail: String?
    ) -> String {
        var reasons: [String] = []
        for (offset, segment) in record.claudeSegments.enumerated() {
            let segmentNumber = offset + 1
            if segment.baseline == nil {
                reasons.append("Cost segment \(segmentNumber) has no verified cumulative-cost baseline.")
            }
            if segment.latestCumulative == nil {
                reasons.append("Cost segment \(segmentNumber) has no accepted cumulative-cost checkpoint.")
            }
            if segment.coverage != .complete {
                reasons.append(
                    "Cost segment \(segmentNumber) is recorded with \(coverageText(segment.coverage)) coverage; no separate historical reason is stored on the segment."
                )
            }
            if segment.state == .suspended {
                reasons.append(
                    "Cost segment \(segmentNumber) is suspended; the persisted segment does not store its historical suspension cause."
                )
            }
        }
        reasons.append(contentsOf: record.turns.compactMap { turn in
            guard let diagnostic = turn.diagnostic, diagnostic.contains("monetary checkpoint rejected") else {
                return nil
            }
            return diagnostic
        })
        if record.hasUnmeasuredHistory {
            reasons.append(
                "Earlier Claude cost is marked unmeasured; the persisted record does not store a separate historical cause."
            )
        }
        if let currentDetail {
            reasons.append(currentDetail)
        }
        reasons = uniqueDetails(reasons)
        guard let estimate else {
            return reasons.isEmpty
                ? "Unavailable: no segment has both a verified baseline and an accepted cumulative-cost checkpoint."
                : "Unavailable: \(reasons.joined(separator: " "))"
        }
        guard estimate.coverage == .partial else {
            let complete = "Complete: every contributing monetary segment has complete coverage."
            return reasons.isEmpty ? complete : "\(complete) \(reasons.joined(separator: " "))"
        }
        return reasons.isEmpty
            ? "Partial: the persisted estimate is marked partial, but its historical cause was not recorded."
            : "Partial: \(reasons.joined(separator: " "))"
    }

    private static func codexSessionCacheCoverageDetail(
        record: AgentProviderUsageRecord,
        intervals: [AgentProviderUsageRecord.CodexUsageInterval],
        share: AgentUsageCacheHitShare?
    ) -> String {
        var reasons = intervals.compactMap { interval -> String? in
            guard let input = interval.inputTokens,
                  let cached = interval.cachedInputTokens,
                  input >= 0,
                  cached >= 0,
                  CodexUsagePricing.hasConsistentInputSubsets(
                      input: input,
                      cached: cached,
                      cacheWrite: interval.cacheWriteInputTokens
                  )
            else {
                if let diagnostic = interval.diagnostic {
                    return diagnostic
                }
                let missing = [
                    interval.inputTokens == nil ? "input" : nil,
                    interval.cachedInputTokens == nil ? "cached-input" : nil
                ].compactMap(\.self)
                return missing.isEmpty
                    ? "A Codex interval has inconsistent input/cache counters; no separate historical cause was recorded."
                    : "A Codex interval omitted \(missing.joined(separator: ", ")) counters."
            }
            return nil
        }
        if record.hasUnmeasuredHistory {
            reasons.append(
                "Earlier Codex usage is marked unmeasured; the persisted record does not store a separate historical cause."
            )
        }
        reasons = uniqueDetails(reasons)
        guard let share else {
            return reasons.isEmpty
                ? "Unavailable: no owned interval has a complete, nonzero input denominator."
                : "Unavailable: \(reasons.joined(separator: " "))"
        }
        guard share.coverage == .partial else {
            return "Complete: every owned measured interval supplied consistent input and cached-input counters."
        }
        return reasons.isEmpty
            ? "Partial: the persisted value is marked partial, but its historical cause was not recorded."
            : "Partial: \(reasons.joined(separator: " "))"
    }

    private static func codexSessionCostCoverageDetail(
        record: AgentProviderUsageRecord,
        intervals: [AgentProviderUsageRecord.CodexUsageInterval],
        estimate: CodexCostEstimate?
    ) -> String {
        var reasons = intervals.compactMap { interval -> String? in
            guard interval.estimatedCostLowerUSD == nil || interval.coverage != .complete else {
                return nil
            }
            if let diagnostic = interval.diagnostic {
                return diagnostic
            }
            let missing = [
                interval.inputTokens == nil ? "input" : nil,
                interval.cachedInputTokens == nil ? "cached-input" : nil,
                interval.outputTokens == nil ? "output" : nil
            ].compactMap(\.self)
            return missing.isEmpty
                ? "A Codex interval is not completely priced; its historical cause was not recorded."
                : "A Codex interval omitted \(missing.joined(separator: ", ")) counters required for complete pricing."
        }
        if record.hasUnmeasuredHistory {
            reasons.append(
                "Earlier Codex cost is marked unmeasured; the persisted record does not store a separate historical cause."
            )
        }
        reasons = uniqueDetails(reasons)
        // Completely priced intervals carry a diagnostic only for a stated pricing assumption
        // (for example an unstated long-context qualifier); it never lowers coverage.
        let assumptions = uniqueDetails(intervals.compactMap { interval in
            interval.estimatedCostLowerUSD != nil && interval.coverage == .complete ? interval.diagnostic : nil
        })
        var assumptionText = assumptions.isEmpty ? "" : " Pricing assumption: \(assumptions.joined(separator: "; "))."
        let legacyRangeCount = intervals.count { interval in
            guard let lower = interval.estimatedCostLowerUSD, let upper = interval.estimatedCostUpperUSD else {
                return false
            }
            return lower != upper
        }
        if legacyRangeCount > 0 {
            assumptionText += " \(legacyRangeCount) earlier interval(s) were priced as a range by an older build; the lower bound is shown."
        }
        guard let estimate else {
            return reasons.isEmpty
                ? "Unavailable: no owned interval has a priceable token delta."
                : "Unavailable: \(reasons.joined(separator: " "))"
        }
        guard estimate.coverage == .partial else {
            return "Complete: every owned interval has a complete frozen-pricing estimate.\(assumptionText)"
        }
        return reasons.isEmpty
            ? "Partial: the persisted estimate is marked partial, but its historical cause was not recorded.\(assumptionText)"
            : "Partial: \(reasons.joined(separator: " "))\(assumptionText)"
    }

    private static func uniqueDetails(_ details: [String]) -> [String] {
        var seen = Set<String>()
        return details.filter { seen.insert($0).inserted }
    }

    /// Frozen pricing provenance for the details: version(s), capture/validation dates and
    /// whether any priced interval used a snapshot that was already stale at dispatch.
    private static func codexPricingProvenanceText(_ provenance: CodexPricingProvenance) -> String {
        var parts = ["pricing version \(provenance.pricingVersions.map { String($0.prefix(12)) }.joined(separator: ", "))"]
        if let earliest = provenance.earliestCapturedAt, let latest = provenance.latestCapturedAt {
            let earliestText = earliest.formatted(date: .abbreviated, time: .omitted)
            let latestText = latest.formatted(date: .abbreviated, time: .omitted)
            parts.append(earliestText == latestText ? "price list dated \(earliestText)" : "price lists dated \(earliestText) to \(latestText)")
        }
        if let validated = provenance.latestValidatedAt {
            parts.append("last validated \(validated.formatted(date: .abbreviated, time: .shortened))")
        }
        if provenance.staleIntervalCount > 0 {
            parts.append("stale at dispatch for \(provenance.staleIntervalCount) interval\(provenance.staleIntervalCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    private static func scope(for selectedAgent: AgentProviderKind?) -> Scope {
        switch selectedAgent {
        case .claudeCode:
            .claude
        case .codexExec:
            .codex
        case let selectedAgent?:
            .unsupported(selectedAgent.displayName)
        case nil:
            .unsupported("Provider")
        }
    }

    private var claudePresentation: Presentation {
        let latestReadout = latestRequestCacheHit?.share.map { Self.cachePercentage($0.ratio) }
        let costReadout = costEstimate.flatMap {
            $0.coverage == .unavailable || $0.currency != AgentUsageAccumulator.claudeCurrency
                ? nil
                : Self.usdAmount($0.amount)
        }
        let latestDetail = latestRequestCacheHit.map {
            "Latest-request CH: \(latestReadout ?? "unavailable"). \($0.detail)"
        } ?? "Latest-request CH: unavailable. It is live-only and is not restored from turn/result aggregates or another process."
        let sessionCacheDetail = cacheHitShare.map {
            "Session-average CH: \(Self.cachePercentage($0.ratio)) (\(Self.coverageText($0.coverage)) coverage). It is token-weighted over finalized result usage and is never used as the latest-request value. \(sessionCacheCoverageDetail ?? "")"
        } ?? "Session-average CH: unavailable. \(sessionCacheCoverageDetail ?? "No finalized result has a complete nonzero input/cache counter triple.")"
        let trackingDetail = trackingStartedAt.map {
            "Tracking period: since \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? "Tracking period: unavailable."
        let costDetail = costReadout.map {
            "Accumulated session cost: \($0) (\(Self.coverageText(costEstimate?.coverage)) coverage). It is Claude's cumulative process estimate, including helper-model and native Claude child usage, not billed spend; separate RepoPrompt CE worker sessions are excluded. \(sessionCostCoverageDetail ?? "")"
        } ?? "Accumulated session cost: unavailable. \(sessionCostCoverageDetail ?? "No accepted cumulative cost checkpoint is recorded.")"

        let expanded = [latestDetail, sessionCacheDetail, trackingDetail, costDetail, unavailableReason]
            .compactMap(\.self)
            .joined(separator: "\n\n")
        return .init(
            accessibilityLabel: "Claude usage",
            cacheHitRatioValue: latestReadout ?? Presentation.unavailableValue,
            costEstimateValue: costReadout ?? Presentation.unavailableValue,
            detailText: expanded.replacingOccurrences(of: "\n", with: " "),
            expandedDetailText: expanded,
            noteText: nil
        )
    }

    private var codexPresentation: Presentation {
        let latestReadout = latestRequestCacheHit?.share.map { Self.cachePercentage($0.ratio) }
        let costReadout: String? = costEstimate.flatMap { estimate in
            guard estimate.coverage != .unavailable, estimate.currency == CodexUsagePricing.currency else { return nil }
            return Self.usdAmount(estimate.amount)
        }

        let latestDetail = latestRequestCacheHit.map {
            "Latest-request CH: \(latestReadout ?? "unavailable"). \($0.detail)"
        } ?? "Latest-request CH: unavailable. It is live-only and is not restored from cumulative totals, another session, or another process."
        let sessionCacheDetail = cacheHitShare.map {
            "Session-average CH: \(Self.cachePercentage($0.ratio)) (\(Self.coverageText($0.coverage)) coverage). It is token-weighted over owned cumulative-total intervals and is never used as the latest-request value. \(sessionCacheCoverageDetail ?? "")"
        } ?? "Session-average CH: unavailable. \(sessionCacheCoverageDetail ?? "No owned interval has complete nonzero input and cached-input counters.")"
        let trackingDetail = trackingStartedAt.map {
            "Tracking period: since \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? "Tracking period: unavailable."
        let costDetail = costReadout.map {
            "Accumulated session cost: \($0) (\(Self.coverageText(costEstimate?.coverage)) coverage). It is an API-equivalent estimate calculated from frozen OpenAI Standard/global list prices\(pricingProvenance.map { " (\($0))" } ?? "") at each dispatch, not billed spend or a plan charge. Uncached input is priced at the input rate (an absent cache-write count is the provider's schema default of zero), and the context band follows the model's context window or the latest request's input size, never dropping within a turn. \(sessionCostCoverageDetail ?? "")"
        } ?? "Accumulated session cost: unavailable. It would be an API-equivalent estimate, not billed spend or a plan charge. \(sessionCostCoverageDetail ?? "No owned interval could be priced.")"

        let expanded = [latestDetail, sessionCacheDetail, trackingDetail, costDetail, unavailableReason]
            .compactMap(\.self)
            .joined(separator: "\n\n")
        return .init(
            accessibilityLabel: "Codex usage",
            cacheHitRatioValue: latestReadout ?? Presentation.unavailableValue,
            costEstimateValue: costReadout ?? Presentation.unavailableValue,
            detailText: expanded.replacingOccurrences(of: "\n", with: " "),
            expandedDetailText: expanded,
            noteText: nil
        )
    }

    private static func cachePercentage(_ ratio: Decimal) -> String {
        if ratio > 0, ratio < Decimal(string: "0.001")! {
            return "<0.1%"
        }
        return "\(formatted(ratio * 100, fractionDigits: 1))%"
    }

    /// USD to two decimals, half-up. A positive amount that would round to zero shows `<$0.01`
    /// so it never masquerades as free.
    static func usdAmount(_ amount: Decimal) -> String {
        let rounded = roundedDecimal(amount, scale: 2, mode: .plain)
        if amount > 0, rounded <= 0 {
            return "<$0.01"
        }
        return "$\(formatted(rounded, fractionDigits: 2))"
    }

    private static func roundedDecimal(_ value: Decimal, scale: Int16, mode: NSDecimalNumber.RoundingMode) -> Decimal {
        let handler = NSDecimalNumberHandler(
            roundingMode: mode,
            scale: scale,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).decimalValue
    }

    private static func formatted(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }

    private static func coverageText(_ coverage: AgentProviderUsageRecord.Coverage?) -> String {
        switch coverage {
        case .complete:
            "complete"
        case .partial:
            "partial"
        case .unavailable, nil:
            "unavailable"
        }
    }
}
