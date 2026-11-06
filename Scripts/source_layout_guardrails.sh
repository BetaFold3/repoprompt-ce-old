#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

print_matches() {
  local label="$1"
  shift
  local output
  output="$($@ 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    fail "$label"
    printf '%s\n' "$output" >&2
  fi
}

# 0. Required layout roots/files should exist before negative scans run.
required_dirs=(
  "Sources/RepoPromptExecutable"
  "Sources/RepoPrompt/Features"
  "Sources/RepoPrompt/Infrastructure"
  "Sources/RepoPromptAgentCore"
  "Sources/RepoPromptPlatform"
  "Sources/RepoPromptUI"
  "Sources/RepoPromptWorkspace"
  "Sources/RepoPromptWorkspace/SyntaxParsing"
  "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP"
  "Packages/RepoPromptCore/Sources/RepoPromptMCPClientKit"
  "Packages/RepoPromptCore/Sources/RepoPromptMCPCore"
  "Packages/RepoPromptCore/Tests/RepoPromptCoreTests"
  "Sources/RepoPromptGateway"
  "Sources/RepoPromptRemoteWire"
  "Tests/RepoPromptTests"
)
for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    fail "required source layout directory missing: $dir"
  fi
done

repo_prompt_entry="Sources/RepoPromptExecutable/RepoPromptExecutable.swift"
if [[ ! -f "$repo_prompt_entry" ]]; then
  fail "required thin RepoPrompt executable entry missing: $repo_prompt_entry"
fi
unexpected_repo_prompt_executable_files=""
if [[ -d "Sources/RepoPromptExecutable" ]]; then
  unexpected_repo_prompt_executable_files="$(find Sources/RepoPromptExecutable -type f ! -path "$repo_prompt_entry" -print)"
fi
if [[ -n "$unexpected_repo_prompt_executable_files" ]]; then
  fail "thin RepoPrompt executable target contains implementation files"
  printf '%s\n' "$unexpected_repo_prompt_executable_files" >&2
fi
# Library source roots of the app split; add each new root here once.
library_source_roots=("Sources/RepoPrompt" "Sources/RepoPromptAgentCore" "Sources/RepoPromptPlatform" "Sources/RepoPromptUI" "Sources/RepoPromptWorkspace")
repo_prompt_app_main_declarations="$(grep -R -n -E '^[[:space:]]*@main([[:space:]]|$)' "${library_source_roots[@]}" --include='*.swift' || true)"
if [[ -n "$repo_prompt_app_main_declarations" ]]; then
  fail "RepoPromptApp/RepoPromptAgentCore/RepoPromptPlatform/RepoPromptUI/RepoPromptWorkspace library targets must not declare @main"
  printf '%s\n' "$repo_prompt_app_main_declarations" >&2
fi
repo_prompt_entry_main_count="$(grep -c -E '^[[:space:]]*@main([[:space:]]|$)' "$repo_prompt_entry" || true)"
if [[ "$repo_prompt_entry_main_count" -ne 1 ]]; then
  fail "thin RepoPrompt executable entry must declare exactly one @main"
fi

repo_prompt_mcp_entry="Sources/RepoPromptMCP/main.swift"
if [[ ! -f "$repo_prompt_mcp_entry" ]]; then
  fail "required thin RepoPromptMCP executable entry missing: $repo_prompt_mcp_entry"
fi
unexpected_repo_prompt_mcp_files=""
if [[ -d "Sources/RepoPromptMCP" ]]; then
  unexpected_repo_prompt_mcp_files="$(find Sources/RepoPromptMCP -type f ! -path "$repo_prompt_mcp_entry" -print)"
fi
if [[ -n "$unexpected_repo_prompt_mcp_files" ]]; then
  fail "thin RepoPromptMCP executable target contains implementation files"
  printf '%s\n' "$unexpected_repo_prompt_mcp_files" >&2
fi

shared_mcp_required_files=(
  "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift"
  "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift"
  "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift"
)
for file in "${shared_mcp_required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required shared MCP file missing: $file"
  fi
done

# Exact-snapshot Tree-sitter scanner support must remain narrow and reproducible.
# Remove this block together with the support target only after validated upstream
# JavaScript/Python revisions compile their scanner objects in a clean root graph.
if [[ -e "src/scanner.c" ]]; then
  fail "retired root src/scanner.c manifest-probe sentinel exists; use the tracked TreeSitterScannerSupport target instead"
fi

print_matches \
  "RepoPromptRemoteWire imports forbidden app/gateway/MCP/NIO/logging modules" \
  grep -R -n -E '^[[:space:]]*import[[:space:]]+(MCP|NIO[A-Za-z0-9_]*|Logging|RepoPrompt|RepoPromptGateway|RepoPromptMCP|RepoPromptMCPClientKit|RepoPromptShared)\b' \
    Sources/RepoPromptRemoteWire --include='*.swift'

tree_sitter_scanner_support_files=(
  "Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h"
  "Sources/TreeSitterScannerSupport/include/tree_sitter/array.h"
  "Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h"
  "Sources/TreeSitterScannerSupport/src/javascript/scanner.c"
  "Sources/TreeSitterScannerSupport/src/python/scanner.c"
  "ThirdPartyLicenses/tree-sitter/scanner-support.sha256"
)
for file in "${tree_sitter_scanner_support_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required TreeSitterScannerSupport compatibility file missing: $file"
  elif ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 &&
       [[ "$(git status --porcelain --untracked-files=all -- "$file")" != "?? $file" ]]; then
    fail "TreeSitterScannerSupport compatibility file must be tracked or pending addition: $file"
  fi
done

if [[ -d "Sources/TreeSitterScannerSupport" ]]; then
  unexpected_tree_sitter_scanner_support_files="$(find Sources/TreeSitterScannerSupport -type f \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h' \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/array.h' \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h' \
    ! -path 'Sources/TreeSitterScannerSupport/src/javascript/scanner.c' \
    ! -path 'Sources/TreeSitterScannerSupport/src/python/scanner.c' \
    -print)"
  if [[ -n "$unexpected_tree_sitter_scanner_support_files" ]]; then
    fail "unexpected file found under narrow TreeSitterScannerSupport compatibility target"
    printf '%s\n' "$unexpected_tree_sitter_scanner_support_files" >&2
  fi
fi

if [[ -f "ThirdPartyLicenses/tree-sitter/scanner-support.sha256" ]]; then
  if ! tree_sitter_scanner_support_checksum_output="$(shasum -a 256 -c ThirdPartyLicenses/tree-sitter/scanner-support.sha256 2>&1)"; then
    fail "TreeSitterScannerSupport compatibility snapshots differ from curated checksums"
    printf '%s\n' "$tree_sitter_scanner_support_checksum_output" >&2
  fi
fi

if ! tree_sitter_scanner_support_manifest_output="$(python3 <<'PY'
import json
import subprocess
from pathlib import Path

expected_packages = {
    "tree-sitter-c": ("https://github.com/tree-sitter/tree-sitter-c", "3efee11f784605d44623d7dadd6cd12a0f73ea92", "TreeSitterC"),
    "tree-sitter-dart": ("https://github.com/UserNobody14/tree-sitter-dart", "80e23c07b64494f7e21090bb3450223ef0b192f4", "TreeSitterDart"),
    "tree-sitter-go": ("https://github.com/tree-sitter/tree-sitter-go", "c350fa54d38af725c40d061a602ee3205ef1e072", "TreeSitterGo"),
    "tree-sitter-java": ("https://github.com/tree-sitter/tree-sitter-java", "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11", "TreeSitterJava"),
    "tree-sitter-javascript": ("https://github.com/tree-sitter/tree-sitter-javascript", "39798e26b6d4dbcee8e522b8db83f8b2df33a5ea", "TreeSitterJavaScript"),
    "tree-sitter-python": ("https://github.com/tree-sitter/tree-sitter-python", "c5fca1a186e8e528115196178c28eefa8d86b0b0", "TreeSitterPython"),
    "tree-sitter-rust": ("https://github.com/tree-sitter/tree-sitter-rust", "2eaf126458a4d6a69401089b6ba78c5e5d6c1ced", "TreeSitterRust"),
}
errors = []
manifest_text = Path("Package.swift").read_text()
resolved = json.loads(Path("Package.resolved").read_text())
resolved_pins = {pin["identity"]: pin for pin in resolved["pins"]}
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
targets = {target["name"]: target for target in package["targets"]}
repo_prompt = targets.get("RepoPrompt", {})
repo_prompt_app = targets.get("RepoPromptApp", {})
repo_prompt_agent_core = targets.get("RepoPromptAgentCore", {})
repo_prompt_platform = targets.get("RepoPromptPlatform", {})
repo_prompt_ui = targets.get("RepoPromptUI", {})
repo_prompt_workspace = targets.get("RepoPromptWorkspace", {})
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
repo_prompt_app_dependencies = repo_prompt_app.get("dependencies", [])
repo_prompt_app_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_app_dependencies
    if "product" in dependency
}

if repo_prompt.get("type") != "executable":
    errors.append("RepoPrompt target must remain executable")
if repo_prompt.get("path") != "Sources/RepoPromptExecutable":
    errors.append("RepoPrompt target must remain the thin Sources/RepoPromptExecutable entry target")
repo_prompt_by_name_dependencies = [
    dependency["byName"][0]
    for dependency in repo_prompt_dependencies
    if dependency.get("byName")
]
if len(repo_prompt_dependencies) != 1 or repo_prompt_by_name_dependencies != ["RepoPromptApp"]:
    errors.append("RepoPrompt executable target must depend only on RepoPromptApp")
if repo_prompt_app.get("type") != "regular":
    errors.append("RepoPromptApp target must remain an internal library target")
if repo_prompt_app.get("path") != "Sources/RepoPrompt":
    errors.append("RepoPromptApp target must retain the Sources/RepoPrompt implementation path")
if repo_prompt_agent_core.get("type") != "regular":
    errors.append("RepoPromptAgentCore target must exist as an internal library target")
if repo_prompt_agent_core.get("path") != "Sources/RepoPromptAgentCore":
    errors.append("RepoPromptAgentCore target must use the Sources/RepoPromptAgentCore path")
if repo_prompt_platform.get("type") != "regular":
    errors.append("RepoPromptPlatform target must exist as an internal library target")
if repo_prompt_platform.get("path") != "Sources/RepoPromptPlatform":
    errors.append("RepoPromptPlatform target must use the Sources/RepoPromptPlatform path")
if repo_prompt_ui.get("type") != "regular":
    errors.append("RepoPromptUI target must exist as an internal library target")
if repo_prompt_ui.get("path") != "Sources/RepoPromptUI":
    errors.append("RepoPromptUI target must use the Sources/RepoPromptUI path")
if repo_prompt_workspace.get("type") != "regular":
    errors.append("RepoPromptWorkspace target must exist as an internal library target")
if repo_prompt_workspace.get("path") != "Sources/RepoPromptWorkspace":
    errors.append("RepoPromptWorkspace target must use the Sources/RepoPromptWorkspace path")

for identity, (url, revision, product) in expected_packages.items():
    manifest_pin = f'.package(url: "{url}", revision: "{revision}")'
    if manifest_pin not in manifest_text:
        errors.append(f"Package.swift missing exact pin: {identity} {revision}")
    pin = resolved_pins.get(identity)
    if pin is None:
        errors.append(f"Package.resolved missing pin: {identity}")
    elif pin.get("location") != url or pin.get("state", {}).get("revision") != revision:
        errors.append(f"Package.resolved pin drift: {identity}")
    if (product, identity) not in repo_prompt_app_products:
        errors.append(f"RepoPromptApp missing upstream grammar product dependency: {product} ({identity})")

support = targets.get("TreeSitterScannerSupport")
if support is None:
    errors.append("TreeSitterScannerSupport target missing")
else:
    if support.get("path") != "Sources/TreeSitterScannerSupport":
        errors.append("TreeSitterScannerSupport target path drifted")
    expected_sources = ["src/javascript/scanner.c", "src/python/scanner.c"]
    if sorted(support.get("sources", [])) != expected_sources:
        errors.append("TreeSitterScannerSupport sources must remain exactly JavaScript/Python scanner.c")
if not any(dependency.get("byName", [None])[0] == "TreeSitterScannerSupport" for dependency in repo_prompt_app_dependencies):
    errors.append("RepoPromptApp must directly depend on TreeSitterScannerSupport")

if errors:
    raise SystemExit("\n".join(errors))
PY
)"; then
  fail "TreeSitter grammar pin/product, scanner-support, or target-topology manifest contract drifted"
  printf '%s\n' "$tree_sitter_scanner_support_manifest_output" >&2
fi

retired_tree_sitter_grammar_dirs=(
  "Sources/RepoPromptTreeSitterCGrammar"
  "Sources/RepoPromptTreeSitterDartGrammar"
  "Sources/RepoPromptTreeSitterGoGrammar"
  "Sources/RepoPromptTreeSitterJavaGrammar"
  "Sources/RepoPromptTreeSitterJavaScriptGrammar"
  "Sources/RepoPromptTreeSitterPythonGrammar"
  "Sources/RepoPromptTreeSitterRustGrammar"
)
for dir in "${retired_tree_sitter_grammar_dirs[@]}"; do
  if [[ -e "$dir" ]]; then
    fail "retired local Tree-sitter grammar directory exists: $dir"
  fi
done

# 1. Old top-level layer buckets should not receive files again.
old_buckets=(
  "Sources/RepoPrompt/ViewModels"
  "Sources/RepoPrompt/Views"
  "Sources/RepoPrompt/Services"
  "Sources/RepoPrompt/Models"
  "Sources/RepoPrompt/Notifications"
  "Sources/RepoPrompt/Utils"
  "Sources/RepoPrompt/Shared"
  "Sources/RepoPrompt/Features/SynthaxParsing"
  "Sources/RepoPrompt/Features/Benchmark"
)
for bucket in "${old_buckets[@]}"; do
  if [[ -d "$bucket" ]]; then
    matches="$(find "$bucket" -type f -print)"
    if [[ -n "$matches" ]]; then
      fail "legacy bucket contains files: $bucket"
      printf '%s\n' "$matches" >&2
    fi
  fi
done

# 2. Test-only directories must stay out of the app source target.
print_matches \
  "Tests/TestSupport/Fixtures directory found under app, AgentCore, Platform, UI, or Workspace sources" \
  find "${library_source_roots[@]}" -type d \( -name Tests -o -name TestSupport -o -name Fixtures \) -print

# 3. MCPControlMessages.swift has exactly one source of truth.
mcp_control_files=()
while IFS= read -r file; do
  mcp_control_files+=("$file")
done < <(find Sources Packages/RepoPromptCore/Sources -name MCPControlMessages.swift -type f -print | sort)
if [[ "${#mcp_control_files[@]}" -ne 1 || "${mcp_control_files[0]:-}" != "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPControlMessages.swift" ]]; then
  fail "MCPControlMessages.swift must exist only at Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  printf '%s\n' "${mcp_control_files[@]}" >&2
fi

# 3a. MCP filesystem and event wire identity also have one shared source of truth.
mcp_identity_files=()
while IFS= read -r file; do
  mcp_identity_files+=("$file")
done < <(find Sources Packages/RepoPromptCore/Sources -name MCPFilesystemIdentity.swift -type f -print | sort)
if [[ "${#mcp_identity_files[@]}" -ne 1 || "${mcp_identity_files[0]:-}" != "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift" ]]; then
  fail "MCPFilesystemIdentity.swift must exist only under RepoPromptShared"
  printf '%s\n' "${mcp_identity_files[@]}" >&2
fi

mcp_event_declarations="$(grep -R -l -E '^(public )?struct MCPExternalClientEvent' Sources Packages/RepoPromptCore/Sources --include='*.swift' | sort || true)"
if [[ "$mcp_event_declarations" != "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift" ]]; then
  fail "MCPExternalClientEvent wire DTO must be declared only under RepoPromptShared"
  printf '%s\n' "$mcp_event_declarations" >&2
fi

mcp_bootstrap_declarations="$(grep -R -l -E '^(public )?(enum MCPBootstrapProtocol|enum MCPBootstrapTiming|struct MCPBootstrapRequest|struct MCPBootstrapResponse|enum MCPBootstrapErrorCode)' Sources Packages/RepoPromptCore/Sources --include='*.swift' | sort || true)"
if [[ "$mcp_bootstrap_declarations" != "Packages/RepoPromptCore/Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift" ]]; then
  fail "MCP bootstrap handshake DTOs must be declared only under RepoPromptShared"
  printf '%s\n' "$mcp_bootstrap_declarations" >&2
fi

# 4. Parser fixtures and sample parser inputs must not live in app source.
print_matches \
  "parser fixture/test directory found under Workspace or Platform syntax parsing source" \
  find Sources/RepoPromptWorkspace/SyntaxParsing Sources/RepoPromptPlatform/Infrastructure/SyntaxParsing -type d \( -iname '*fixture*' -o -iname '*test*' \) -print
print_matches \
  "parser fixture-like sample input found under Workspace or Platform syntax parsing source" \
  find Sources/RepoPromptWorkspace/SyntaxParsing Sources/RepoPromptPlatform/Infrastructure/SyntaxParsing -type f \( \
    -iname '*fixture*' -o -iname '*test*' -o \
    -name '*.dart' -o -name '*.go' -o -name '*.java' -o -name '*.js' -o -name '*.jsx' -o \
    -name '*.py' -o -name '*.rb' -o -name '*.rs' -o -name '*.ts' -o -name '*.tsx' -o \
    -name '*.php' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
  \) -print

# 5. Agent/MCP runtime paths must stay off WorkspaceFiles UI view-model dependencies.
# UI views may still depend on WorkspaceFilesViewModel/FileViewModel/FolderViewModel until
# the later UI-adapter simplification items, but runtime code must use WorkspaceContext values.
print_matches \
  "Agent/MCP runtime source references WorkspaceFilesViewModel/FileViewModel/FolderViewModel" \
  grep -R -n -E 'WorkspaceFilesViewModel|FileViewModel|FolderViewModel' \
    Sources/RepoPrompt/Features/AgentMode/ViewModels \
    Sources/RepoPrompt/Features/ContextBuilder/ViewModels \
    Sources/RepoPrompt/Infrastructure/MCP \
    Sources/RepoPromptAgentCore

# 6. Removed native tree visualization, IDE-mode tree search, and eager root materialization
# seams must not return. Keep unique deleted symbols global, but scope generic names to
# their former owners.
removed_artifact_paths=(
  "Sources/RepoPrompt/Features/AgentMode/Views/AgentFileTreeBottomPanelView.swift"
  "Sources/RepoPrompt/Features/WorkspaceFiles/Views/FileTree/NativeFileTree"
  "Sources/RepoPrompt/Features/Search/ViewModels/SearchFileTreeViewModel.swift"
)
for path in "${removed_artifact_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed native-tree/search artifact path exists: $path"
  fi
done

print_matches \
  "removed native-tree/workspace-loading/search seam referenced in Sources" \
  grep -R -n -E 'AgentFileTreeBottomPanelView|FileTreeViewWrapper|FileTreeViewController|NativeFileTree|SearchFileTreeViewModel|RootDescendantMaterialization|legacyMaterializedRootKeys|legacyMaterializeDescendantsRecursively|legacyEager' \
    Sources/RepoPrompt Sources/RepoPromptWorkspace
print_matches \
  "WindowState references removed searchViewModel wiring" \
  grep -n -E 'searchViewModel' Sources/RepoPrompt/App/WindowState.swift
print_matches \
  "WorkspaceFilesViewModel references removed recursive eager loading seam" \
  grep -n -E 'loadContentsRecursively' Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift

# 7. Removed IDE-era Prompt selected-files panel and Prompt-owned preset bottom bar
# artifacts must not return. The live compact selected-files surface is
# SelectedFilesGrid/FilePreviewPopover, and Settings owns its chat preset picker.
removed_prompt_cleanup_paths=(
  "Sources/RepoPrompt/Features/Prompt/Views/Components/PresetBottomBar.swift"
  "Sources/RepoPrompt/Features/Prompt/Views/Components/SelectedFileView.swift"
  "Sources/RepoPrompt/Features/Prompt/ViewModels/Selection/SelectedFilesPanelViewModel.swift"
)
for path in "${removed_prompt_cleanup_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed Prompt UI cleanup artifact path exists: $path"
  fi
done

print_matches \
  "removed Prompt selected-files/preset-bottom-bar symbol referenced in Sources" \
  grep -R -n -E 'PresetBottomBar|SelectedFilesContentView|SelectedFilesPanelViewModel|PresetTwoPanePopover_Copy|CopyPresetPreviewView|PresetTwoPanePopover_Chat' \
    Sources/RepoPrompt

# 8. Agent-authored reports and working notes stay local unless explicitly
# promoted into the contributor-facing documentation set.
allowed_tracked_docs=(
  "docs/architecture/mcp-instructions-and-provider-guidance.md"
  "docs/architecture/provider-plugins.md"
  "docs/architecture/settings-persistence.md"
  "docs/architecture/source-layout.md"
  "docs/architecture/xcode-workspace.md"
  "docs/context/agent-mcp-delegation-depth.md"
  "docs/context/agent-composer-file-paste.md"
  "docs/context/plans/2026-11-04-agent-document-attachments.md"
  "docs/context/plans/2026-11-06-claude-delegated-session-reliability-plan.md"
  "docs/context/archive/2026-07-30-AGENTS.md"
  "docs/context/archive/2026-07-30-CLAUDE.md"
  "docs/context/archive/MANIFEST.md"
  "docs/context/claude-mcp-connection-health.md"
  "docs/context/claude-model-family-catalog.md"
  "docs/context/codemap-source-authority-recovery.md"
  "docs/context/gpt-model-catalog.md"
  "docs/context/oracle-remote-models-cursor-catalog.md"
  "docs/context/plans/completed/2026-08-29-transcript-preview-deeplink-plan.md"
  "docs/context/plans/completed/2026-09-02-fable-5-1-dynamic-model-catalog-plan.md"
  "docs/context/plans/completed/2026-09-03-codex-computer-use-enablement-plan.md"
  "docs/context/plans/completed/2026-09-03-omp-collapsed-cursor-thinking-accessory-plan.md"
  "docs/context/plans/completed/2026-09-03-omp-thinking-capability-sweep-plan.md"
  "docs/context/plans/completed/2026-09-04-dynamic-gpt-model-catalog-plan.md"
  "docs/context/plans/completed/2026-09-17-claude-auto-permissions-plan.md"
  "docs/context/plans/completed/2026-10-01-claude-compaction-status-and-tokens-only-continuity-plan.md"
  "docs/context/plans/completed/2026-10-03-codemap-source-authority-recovery-plan.md"
  "docs/context/plans/completed/omp-agent-models-menu-thinking-fix.md"
  "docs/context/plans/completed/omp-transcript-authority-and-model-ux.md"
  "docs/context/plans/completed/oracle-remote-models-cursor-catalog.md"
  "docs/context/plans/completed/quick-model-picker-and-handoff-hud.md"
  "docs/context/plans/2026-09-05-codex-conversation-branching-plan.md"
  "docs/context/plans/2026-09-13-agent-usage-and-wait-efficiency-plan.md"
  "docs/context/agent-scheduled-messages.md"
  "docs/context/agent-crash-recovery.md"
  "docs/context/plans/completed/2026-09-21-agent-scheduled-messages-plan.md"
  "docs/context/plans/2026-09-21-oracle-resumable-wait-plan.md"
  "docs/context/plans/2026-10-02-oracle-errors-and-delegated-ask-user-plan.md"
  "docs/context/plans/2026-10-03-codex-cold-resume-reliability-plan.md"
  "docs/context/plans/2026-10-03-oracle-shim-auth-and-knowledge-workers-plan.md"
  "docs/context/plans/2026-10-03-oracle-failure-inspection-plan.md"
  "docs/context/plans/2026-10-03-code-mode-readiness-and-git-narrowing-plan.md"
  "docs/context/code-mode-measurements.md"
  "docs/context/plans/2026-10-05-transcript-inner-scroll-hang-fix-plan.md"
  "docs/context/plans/2026-10-09-oracle-call-contract-hardening-plan.md"
  "docs/context/plans/completed/2026-10-10-app-module-split-contract.md"
  "docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md"
  "docs/context/plans/completed/2026-10-30-telegram-remote-link-specs.md"
  "docs/context/plans/completed/2026-10-31-remote-passkey-unlock-spec.md"
  "docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md"
  "docs/context/assistant-workspace-steering.md"
  "docs/context/telegram-paired-browser-remote.md"
  "docs/context/plans/2026-10-12-agent-mode-transcript-refresh-performance-spec.md"
  "docs/context/plans/completed/2026-10-16-debug-packaging-incremental-spec.md"
  "docs/context/plans/completed/2026-10-16-optimized-diagnostics-dev-lane-spec.md"
  "docs/context/plans/completed/2026-10-18-lossless-app-restart-spec.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase0-oraclea-review.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase0-oracleb-review.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1-scope.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oraclea-review.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oracleb-review.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1a-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-foundation-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oraclea-r3.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-cutover-oracleb-r3.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-plan.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase2-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-plan.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oraclea-initial-incomplete.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-registry-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-work.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-admission-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-review-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase5b-child-links-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-plan.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-forward-guidance.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-source-investigations.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4c-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d2-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d2-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d2-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d2-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d2-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3a-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3a-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3a-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3a-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3a-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d-no-replay-capture.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/live-acceptance-handoff.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-validation-2026-10-24.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-guidance-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/pre-live-guidance-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d7-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d6-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-persistence-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-persistence-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d5-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d4-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d4-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d4-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d-tool-resume-capture.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3c-plan-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3b-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3b-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3b-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3b-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d3b-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d1-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d1-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4d-claude-capture.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-relocation-plan-oraclee.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-forward-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-forward-oraclee.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase4-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-boundary-plan.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-shutdown-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-platform.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-platform-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-platform-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-platform-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase3-platform-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/phase1b-recovery-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f7-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f7-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f7-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f7-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f7-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f2-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f2-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f2-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f2-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f2-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f4-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f4-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f4-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f4-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f4-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f3f6-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f3f6-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f5obs-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f5obs-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f5obs-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-minor-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-minor-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-minor-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-minor-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-minor-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/resign-2026-10-26.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oraclea-part2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/attention-activation-synthesis.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-scenarios.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-popover-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-popover-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-popover-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-popover-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-popover-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention2-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention2-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-attention2-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-check-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-check-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-check-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-check-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-check-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-scout.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-plan-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-plan-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10a-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10a-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10a-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-classification-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10c-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10c-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10c-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-11-quiet-by-default.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-12-pre-output-interrupt.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-verifier-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-b-design-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-b-plan-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-b-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-10b-live-apply.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-f1-regression-bisect.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-p5-esc-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-p5-esc-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-p5-esc-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-launch-authority-review-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-brief.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-results.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r2-brief.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-codex-turn-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-codex-turn-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-codex-turn-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-codex-turn-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-codex-turn-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r2-results.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r2-s1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r2-s3-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-s2-s4-s5-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r2-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r3-brief.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r3-results.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r3-t1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/plan-9live-r3-t1-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/plan-9live-r3-t1-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r3-t1-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r3-t1-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r4-brief.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/verifier-9live-r4-results.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-switch-review-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/activation-switch-review-oracleb.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r1-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r2-r5-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r6-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/plan-9live-fixes-oraclea.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/plan-9live-fixes-oracled.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-esc-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-esc-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-esc-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r3-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r3-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-r3-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-o43-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-o43-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-o43-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-worker.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oraclea-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oracleb-r0.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oraclea-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oracleb-r1.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oraclea-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/fix-9live-claude-home-review-oracleb-r2.md"
  "docs/context/plans/completed/evidence/2026-10-18-lossless-app-restart/diag-9live-r3-rewrite-worker.md"
  "docs/context/review-policy.md"
  "docs/context/specs/2026-11-04-rich-presentation-spec.md"
  "docs/context/plans/2026-10-18-turn-worktree-checkpoints-spec.md"
  "docs/context/plans/completed/2026-10-04-swift-build-measurement-and-debug-dsym-plan.md"
  "docs/context/plans/completed/2026-10-08-swift-compile-follow-ups-plan.md"
  "docs/context/oracle-failure-inspection.md"
  "docs/context/plans/completed/2026-10-18-codemap-automatic-convergence-plan.md"
  "docs/context/plans/completed/agent-focus-delivery-reliability.md"
  "docs/context/plans/agent-mode-qol-shortcut-focus-toolbar-motion.md"
  "docs/context/plans/omp-provider-integration.md"
  "docs/context/plans/pi-provider-integration.md"
  "docs/context/quick-model-picker-and-handoff-hud.md"
  "docs/context/transcript-preview-deep-links.md"
  "docs/context/workflows/development.md"
  "docs/context/workflows/doc-gardening.md"
  "docs/context/workflows/validation.md"
  "docs/designs/cross-restart-durability-root-search-cas-2026-06-25.md"
  "docs/designs/remote-relay-contract.md"
  "docs/open-source-readiness.md"
  "docs/privacy/telemetry.md"
  "docs/technical_implementation_reports/remote-control-gateway.md"
  "docs/technical_implementation_reports/2026-07-08-remote-session-ux-gaps-implementation.md"
  "docs/technical_implementation_reports/2026-07-08-remote-recency-grouping-and-device-badge.md"
  "docs/technical_implementation_reports/2026-07-08-remote-e2e-truncation-spinners-picker-fixes.md"
  "docs/technical_implementation_reports/2026-07-08-remote-e2e-followup-spinner-inversion-status-label-fixes.md"
  "docs/technical_implementation_reports/2026-07-09-remote-effort-picker-clobber-status-label-streaming-fixes.md"
  "docs/technical_implementation_reports/2026-07-09-remote-skip-all-payload-and-respond-recovery-fixes.md"
  "docs/technical_implementation_reports/2026-07-09-remote-interview-draft-preservation-timeout-parity-watch-revalidation.md"
  "docs/technical_implementation_reports/2026-07-09-remote-premature-terminal-latch-and-cb-model-label-fixes.md"
  "docs/technical_implementation_reports/2026-07-13-live-smoke-deferred-followups-f1-f3.md"
  "docs/technical_implementation_reports/2026-07-13-remote-transcript-delivery-recovery.md"
  "docs/technical_implementation_reports/2026-07-13-workspace-run-target-snapshot-invalidation.md"
  "docs/technical_implementation_reports/2026-07-15-remote-pairing-trust-refresh-and-revocation.md"
  "docs/technical_implementation_reports/2026-07-16-remote-command-tail-stale-recovery.md"
  "docs/technical_implementation_reports/2026-07-25-mcp-instructions-rewrite-provider-guidance.md"
  "docs/technical_implementation_reports/2026-07-26-remote-handoff-fork.md"
  "docs/openai-model-metadata-quick-guide.html"
  "docs/releasing.md"
  "docs/testing.md"
  "docs/spec/history-query-tools.md"
  "docs/spec/native-direct-tailnet-pairing.md"
  "docs/worktrees.md"
  "docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md"
  "docs/investigations/r1-r4-contract-validity-2026-07-25.md"
  "docs/investigations/remote-agent-transcript-delivery-regression-2026-07-13.md"
  "docs/investigations/remote-control-ticket-endpoint-404-2026-07-14.md"
  "docs/investigations/remote-pairing-device-revoked-after-pairing-2026-07-15.md"
  "docs/investigations/remote-pairing-onboarding-ux-2026-07-14.md"
  "docs/investigations/test-coverage-value-audit-ledger-2026-05-29.md"
  "docs/investigations/workspace-scoped-run-target-label-2026-07-13.md"
  "docs/plans/test-coverage-value-audit-2026-05-29.md"
  "docs/technical_implementation_reports/2026-07-29-parallel-dual-oracle-sessions.md"
  "docs/technical_implementation_reports/2026-07-30-knowledge-agent-profile.html"
  "docs/technical_implementation_reports/2026-07-30-knowledge-work-harness.html"
  "docs/technical_implementation_reports/2026-07-30-oracle-continuation-preset-inheritance.html"
  "docs/technical_implementation_reports/2026-07-31-api-provider-model-modernization.html"
  "docs/technical_implementation_reports/2026-08-02-right-utility-panel.html"
  "docs/technical_implementation_reports/2026-08-04-right-utility-panel-complete.html"
  "docs/technical_implementation_reports/2026-08-05-cursor-parameterized-model-picker.html"
  "docs/technical_implementation_reports/2026-08-05-oracle-duel-hardening-transcript-qol.html"
  "docs/technical_implementation_reports/2026-08-06-claude-cli-executable-path-override.html"
  "docs/technical_implementation_reports/2026-08-08-build-test-performance-optimization.html"
  "docs/technical_implementation_reports/2026-08-08-quick-model-picker-and-handoff-hud.html"
  "docs/technical_implementation_reports/2026-08-16-cursor-parameter-catalog-phase-b.html"
  "docs/technical_implementation_reports/2026-09-03-codex-computer-use-enablement-report.html"
  "docs/technical_implementation_reports/2026-09-16-agent-usage-and-wait-efficiency-phase-7.html"
)
while IFS= read -r path; do
  allowed_tracked_docs+=("$path")
done < <(git ls-files 'docs/test-suite-optimizer')
unexpected_tracked_docs="$(comm -23 \
  <(git ls-files docs | sort) \
  <(printf '%s\n' "${allowed_tracked_docs[@]}" | sort))"
if [[ -n "$unexpected_tracked_docs" ]]; then
  fail "unexpected tracked docs found; keep agent-authored working documents local or add durable docs to the explicit allowlist"
  printf '%s\n' "$unexpected_tracked_docs" >&2
fi

if [[ "$failures" -ne 0 ]]; then
  printf 'Source layout guardrails failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
  exit 1
fi

printf 'OK: source layout guardrails passed.\n'
