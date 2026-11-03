#if DEBUG
    /// Runtime label for the Dev app build lane. Exists only under `DEBUG`, so release binaries are unchanged.
    /// `RPCE_OPTIMIZED_DIAGNOSTICS` is defined only by the optimized lanes (`-c release` with first-party `DEBUG`);
    /// `RPCE_OPTIMIZED_INCREMENTAL` additionally marks the optimized-incremental App lane (App non-WMO, rest WMO).
    public enum RepoPromptBuildLane: String, Sendable {
        case debug, debugOptimized = "debug-optimized", debugOptimizedIncremental = "debug-optimized-incremental"
        public static let current: RepoPromptBuildLane = {
            #if RPCE_OPTIMIZED_INCREMENTAL
                return .debugOptimizedIncremental
            #elseif RPCE_OPTIMIZED_DIAGNOSTICS
                return .debugOptimized
            #else
                return .debug
            #endif
        }()
    }
#endif
#if RPCE_OPTIMIZED_DIAGNOSTICS && !DEBUG
    #error("RPCE_OPTIMIZED_DIAGNOSTICS requires DEBUG")
#endif
#if RPCE_OPTIMIZED_INCREMENTAL && !RPCE_OPTIMIZED_DIAGNOSTICS
    #error("RPCE_OPTIMIZED_INCREMENTAL requires RPCE_OPTIMIZED_DIAGNOSTICS")
#endif
