#!/usr/bin/env bash
# Build the lab's QuickJS-ng code_mode host (qjs/cm_host_v2.c).
#
#   QJS_SRC=<quickjs-ng v0.17.0 source checkout> build_qjs_host.sh [output]
#       Gate build, as in the 2026-10 lab: compiles only quickjs.c libregexp.c libunicode.c dtoa.c; quickjs-libc is
#       never compiled, so the guest has no filesystem, network or timers.
#   build_qjs_host.sh --homebrew [output]
#       Test build against Homebrew's quickjs-ng dylib (which also bundles quickjs-libc). The host never registers
#       those modules, but this is not the containment build: use it for offline bridge tests, not for gate runs
#       (runner.py refuses a host that links libqjs).
#
# Default output (gate build): $CMLAB_QJS_HOST, else $CMLAB_SCRATCH/bin/cm_host_v2, else <repo>/.build/codemode-lab/bin/cm_host_v2.
# Default output (test build): $CMLAB_SCRATCH/bin/cm_host_v2-homebrew (never the gate path).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mode="source"
if [[ "${1:-}" == "--homebrew" ]]; then mode="homebrew"; shift; fi
scratch="${CMLAB_SCRATCH:-$repo/.build/codemode-lab}"
if [[ "$mode" == "homebrew" ]]; then
  out="${1:-$scratch/bin/cm_host_v2-homebrew}"
else
  out="${1:-${CMLAB_QJS_HOST:-$scratch/bin/cm_host_v2}}"
fi
mkdir -p "$(dirname "$out")"
cc_bin="${CC:-cc}"

if [[ "$mode" == "homebrew" ]]; then
  prefix="$(brew --prefix quickjs-ng 2>/dev/null || true)"
  if [[ -z "$prefix" || ! -f "$prefix/include/quickjs.h" ]]; then
    echo "error: Homebrew quickjs-ng not found (brew install quickjs-ng)" >&2; exit 1
  fi
  "$cc_bin" -O2 -I"$prefix/include" -o "$out" "$here/qjs/cm_host_v2.c" -L"$prefix/lib" -lqjs -lpthread
  echo "built (test build, Homebrew dylib): $out"
  exit 0
fi

src="${QJS_SRC:?set QJS_SRC to a quickjs-ng v0.17.0 source checkout, or pass --homebrew for a test build}"
for f in quickjs.c libregexp.c libunicode.c dtoa.c quickjs.h; do
  [[ -f "$src/$f" ]] || { echo "error: $src/$f not found; QJS_SRC must be a quickjs-ng source checkout" >&2; exit 1; }
done
version="$(awk '/define QJS_VERSION_(MAJOR|MINOR|PATCH)/ {printf "%s.", $3}' "$src/quickjs.h")"
if [[ "${version%.}" != "0.17.0" ]]; then
  echo "warning: quickjs-ng ${version%.} (the lab measured 0.17.0); re-run the parity and containment checks before trusting results" >&2
fi
"$cc_bin" -O2 -I"$src" -o "$out" "$here/qjs/cm_host_v2.c" \
  "$src/quickjs.c" "$src/libregexp.c" "$src/libunicode.c" "$src/dtoa.c" -lm -lpthread
echo "built (gate build, no quickjs-libc): $out"
