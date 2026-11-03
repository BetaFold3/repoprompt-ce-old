#!/usr/bin/env bash
# SwiftPM keys manifest-evaluation and build-plan caches on the exact child
# environment. Measured environment deltas force 14–27s replans versus a ~1.1s
# null floor, so every coordinated/packaging Swift call must present a
# byte-identical environment. The additive env -i construction also subsumes
# run_without_github_tokens.sh stripping of GH_TOKEN, GITHUB_TOKEN, and
# SOURCE_GH_TOKEN.
set -eo pipefail

# Optimized-diagnostics Dev lane (internal; intended for `package_app.sh debug-optimized`). A leading --rpce-optimized-diagnostics is consumed here, so the
# command switch below sees today's argv shape. The lane accepts only
# `build ... -c release`; test products, scratch/build/package paths, any other
# configuration spelling and -Xswiftc (which reaches third-party modules) exit 2
# before Swift. The manifest gate reaches Swift only through this flag: env -i
# drops an inherited RPCE_OPTIMIZED_DIAGNOSTICS.
# Optimized-incremental App lane (`package_app.sh debug-optimized-incremental`): a leading
# --rpce-optimized-incremental takes the same rules, adds RPCE_OPTIMIZED_INCREMENTAL=1 after the
# diagnostics gate and uses its own scratch folder. The two lane flags are mutually exclusive.
optimized_lane=""
optimized_incremental_lane=""
lane_flag=""
case "${1:-}" in
    --rpce-optimized-diagnostics) lane_flag="$1" ;;
    --rpce-optimized-incremental) lane_flag="$1"; optimized_incremental_lane=1 ;;
esac
if [[ -n "$lane_flag" ]]; then
    shift
    optimized_lane=1
    lane_reject() {
        echo "canonical_swift.sh: $lane_flag $1" >&2
        exit 2
    }
    [[ "${1:-}" == build ]] || lane_reject "supports only the build command; got '${1:-}'"
    lane_release=0
    lane_args=("${@:2}")
    for ((lane_index = 0; lane_index < ${#lane_args[@]}; lane_index++)); do
        lane_token="${lane_args[$lane_index]}"
        case "$lane_token" in
            -c)
                lane_value="${lane_args[$((lane_index + 1))]:-}"
                [[ "$lane_release" == 0 ]] || lane_reject "requires exactly one '-c release'; got a second '-c'"
                if [[ "$lane_value" != release ]]; then
                    lane_reject "requires exactly one '-c release'; got '-c $lane_value'"
                fi
                lane_release=1
                lane_index=$((lane_index + 1))
                ;;
            --build-tests | -Xswiftc | -Xswiftc=* | --scratch-path | --scratch-path=* | --build-path | --build-path=* | \
                --package-path | --package-path=* | --configuration | --configuration=* | -c=* | \
                --rpce-optimized-diagnostics | --rpce-optimized-incremental)
                lane_reject "does not accept '$lane_token'"
                ;;
        esac
    done
    [[ "$lane_release" == 1 ]] || lane_reject "requires '-c release'"
    [[ -f "$PWD/Package.swift" ]] || lane_reject "must run from the package root; no Package.swift in '$PWD'"
fi

# Pinned constant PATH: env -i clears PATH, but SwiftPM build steps spawn
# tools (codesign for debug entitlements, git) via PATH lookup. A constant
# system PATH keeps the environment deterministic across all lanes.
swift_env=("PATH=/usr/bin:/bin:/usr/sbin:/sbin")

if [[ -n "${REPOPROMPT_ENABLE_SENTRY:-}" ]]; then
    swift_env+=("REPOPROMPT_ENABLE_SENTRY=$REPOPROMPT_ENABLE_SENTRY")
fi
if [[ -n "${RPCE_ENABLE_BENCHMARK_TESTS:-}" ]]; then
    swift_env+=("RPCE_ENABLE_BENCHMARK_TESTS=$RPCE_ENABLE_BENCHMARK_TESTS")
fi
# XCTest runtime gates must reach swift-test children; they are opt-in and
# rare, so the steady-state (unset) environment stays canonical.
if [[ -n "${RPCE_RUN_CODEMAP_E2E:-}" ]]; then
    swift_env+=("RPCE_RUN_CODEMAP_E2E=$RPCE_RUN_CODEMAP_E2E")
fi
if [[ -n "${RPCE_RUN_SCALE_TESTS:-}" ]]; then
    swift_env+=("RPCE_RUN_SCALE_TESTS=$RPCE_RUN_SCALE_TESTS")
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift_env+=("DEVELOPER_DIR=$DEVELOPER_DIR")
fi
if [[ -n "${SDKROOT:-}" ]]; then
    swift_env+=("SDKROOT=$SDKROOT")
fi
if [[ -n "${TOOLCHAINS:-}" ]]; then
    swift_env+=("TOOLCHAINS=$TOOLCHAINS")
fi
if [[ -n "$optimized_lane" ]]; then
    swift_env+=("RPCE_OPTIMIZED_DIAGNOSTICS=1")
fi
if [[ -n "$optimized_incremental_lane" ]]; then
    swift_env+=("RPCE_OPTIMIZED_INCREMENTAL=1")
fi

# Index store policy (RPCE_INDEX_STORE=on|off; unset means off). No known
# consumer reads SwiftPM's index store, so qualified debug build/test
# invocations get --disable-index-store; on adds nothing. Any other value,
# including the empty string, exits 2 before Swift. The policy variable never
# reaches Swift (env -i); only argv changes, so toggling costs one rebuild.
if [[ -z "${RPCE_INDEX_STORE+set}" ]]; then
    index_policy=off
else
    index_policy="$RPCE_INDEX_STORE"
fi
if [[ "$index_policy" != on && "$index_policy" != off ]]; then
    echo "canonical_swift.sh: RPCE_INDEX_STORE must be 'on' or 'off' (unset means off); got '$index_policy'" >&2
    exit 2
fi

# Xcode 27 / Swift 6.4 defaults to swiftbuild, whose .build/out layout and
# cached XCFramework diagnostics differ from the native SwiftPM engine used by
# our packaging and XCTest artifact tooling. Keep build, test (including list
# and --skip-build), and --show-bin-path on the same explicit engine.
index_candidate=""
case "${1:-}" in
    build|test)
        swift_command="$1"
        shift
        # Pin color off: SwiftPM's TTY-dependent default changes compiler argv between pipe (build) and PTY (test) jobs, forcing module re-emission.
        set -- "$swift_command" --build-system native --no-color-diagnostics "$@"
        index_candidate=1
        ;;
esac
# The lane's own build folder: never thrashes .build/<arch>/debug or the shared
# host-native release tree. It precedes classification, so the dSYM and index
# policies see it (release configuration: full symbols, no index flag).
if [[ -n "$optimized_incremental_lane" ]]; then
    set -- "${@:1:4}" --scratch-path "$PWD/.build/optimized-incremental" "${@:5}"
elif [[ -n "$optimized_lane" ]]; then
    set -- "${@:1:4}" --scratch-path "$PWD/.build/optimized-diagnostics" "${@:5}"
fi

# Debug dSYM policy (RPCE_DEBUG_DSYM=on|off; unset means off). The classifier
# inspects only the build configuration of this exact argument vector, prints
# one stderr banner, and answers the effective value on stdout. Every eligible
# debug invocation (build, test, list, --show-bin-path) gets the same added
# hook so SwiftPM's environment-keyed caches stay byte-identical; the policy
# variable itself never reaches Swift (env -i). The wrapper never touches
# symbol files: `make dev-dsym` regenerates them for existing binaries. An
# invalid policy value exits 2 and any classifier failure exits before Swift.
dsym_python=/usr/bin/python3
if [[ ! -x "$dsym_python" ]]; then
    dsym_python="$(command -v python3 || true)"
fi
if [[ -z "$dsym_python" ]]; then
    echo "canonical_swift.sh: python3 is required to classify RPCE_DEBUG_DSYM" >&2
    exit 70
fi
dsym_effective="$("$dsym_python" -I -S "$(dirname "${BASH_SOURCE[0]}")/debug_dsym.py" wrapper-policy -- "$@")" || exit $?
case "$dsym_effective" in
    off)
        swift_env+=("SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true")
        ;;
    on) ;;
    *)
        echo "canonical_swift.sh: unexpected debug dSYM policy result '$dsym_effective'" >&2
        exit 70
        ;;
esac

# Index eligibility is the dSYM debug-skip qualification (debug configuration,
# no Sentry), independent of the requested dSYM policy. Effective on is
# ambiguous, so re-ask the same classifier with only RPCE_DEBUG_DSYM=off for
# that one quiet subprocess; the single banner above stays authoritative.
if [[ "$index_policy" == off && -n "$index_candidate" ]]; then
    index_effective="$dsym_effective"
    if [[ "$dsym_effective" == on ]]; then
        index_effective="$(RPCE_DEBUG_DSYM=off "$dsym_python" -I -S "$(dirname "${BASH_SOURCE[0]}")/debug_dsym.py" wrapper-policy -- "$@" 2>/dev/null)" || {
            index_status=$?
            echo "canonical_swift.sh: index store eligibility classification failed (exit $index_status)" >&2
            exit "$index_status"
        }
    fi
    case "$index_effective" in
        off)
            set -- "$1" "$2" "$3" --disable-index-store "${@:4}"
            ;;
        on) ;;
        *)
            echo "canonical_swift.sh: unexpected index store eligibility result '$index_effective'" >&2
            exit 70
            ;;
    esac
fi

exec /usr/bin/env -i "${swift_env[@]}" /usr/bin/swift "$@"
