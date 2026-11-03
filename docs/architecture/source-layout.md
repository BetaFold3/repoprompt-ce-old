# Source Layout Ownership Map

Current as of 2026-08-01 after the source-layout refactor, provider/core extraction, upstream Tree-sitter grammar migration, and the thin-executable splits. This document is contributor-facing: use it to decide where new source, tests, fixtures, diagnostics, shared protocol code, and guardrail checks belong.

## Current source tree shape

```text
Packages/
  RepoPromptCore/
    Sources/
      RepoPromptShared/MCP/      # shared app/client MCP control and bootstrap protocol definitions
      RepoPromptMCPClientKit/    # reusable bootstrap MCP client plumbing for CLI/gateway clients
      RepoPromptMCPCore/         # importable MCP CLI implementation library
    Tests/RepoPromptCoreTests/   # isolated Shared/MCP core XCTest target
Sources/
  RepoPromptExecutable/          # thin shipped RepoPrompt executable target; sole @main and delegation only
    RepoPromptExecutable.swift
  RepoPromptAgentCore/           # internal agent runtime/AI library target (not a product); RepoPromptApp depends on it
    AI/Prompts/                  # PromptFactory, code/legacy prompt examples, and the provider-neutral workflow prompt catalog (Workflows/)
    AI/Pricing/                  # OpenAI pricing catalog, parser, seed, and store
  RepoPromptPlatform/            # internal generic-primitives library target (not a product); depends on no other app module
    Infrastructure/
      Concurrency/               # cross-cutting async primitives
      Diagnostics/               # dependency-free DEBUG recording mechanisms (PerfDiagnosticsRecorder); domain instrumentation and reporting stay with owners
      FileSystem/                # dependency-free filesystem primitives (LRU/path caches, pattern pool, spill-backed artifact store)
      Networking/                # HTTP and decoding substrate
      Process/                   # process/CLI launch, environment, termination, and stream-framing substrate
      Regex/                     # reusable regex adapters/toolkit
      Security/                  # keychain, code-signing, and secure-storage mechanics
      SyntaxParsing/             # tree-sitter query strings and query resource loading
      Utilities/                 # dependency-free generic utilities/extensions
    ThirdParty/                  # vendored SwiftPCRE2 wrapper
  RepoPromptUI/                  # internal reusable-UI library target (not a product); may depend on RepoPromptPlatform only among app modules (currently none) plus the Markdown, Neon, and SwiftTreeSitter packages
    Components/                  # reusable SwiftUI/AppKit components, button styles, tooltips, debouncing/work-item gates
    Diagnostics/                 # DEBUG font-scale event recording
    Markdown/                    # markdown compile/render views, code highlighting, file-link detection and interaction
    Mentions/                    # mention models, assets, and picker style
    Services/                    # generic UI services (open panel, input monitor, async user waiter)
    SyntaxHighlighting/          # Neon token styles for code highlighting
    TextField/                   # TextKit text views, mention text view/overlay, undo-safe replacement
    Tooltip/                     # tooltip overlay and anchor geometry
    Typography/                  # FontScaleManager, FontScalePreset, transcript code font resolver/fingerprint
    WebPreview/                  # secure HTML preview view, configuration, navigation policy, repo URL scheme
    UIDisplayPreferences.swift   # live display preferences forwarded by the App settings owner
  RepoPromptWorkspace/           # internal workspace-engine library target (not a product); may depend on RepoPromptPlatform only among app modules
    CodeMap/                     # code-map extraction, language strategies, artifact keys/builds, and FileAPI model
    Diagnostics/                 # workspace restore/root-load/worktree-startup instrumentation and MCP tool work counts
    Diffing/                     # diff parsing/application/generation substrate and edit-flow performance tracing
    FileSystem/                  # filesystem services, ignore rules (incl. GitignoreCompiler), watcher ingress, and workspace inventory
    Persistence/                 # code-map and durable artifact stores, MCP filesystem constants, Workspaces store root resolver (WorkspaceStorageRoot)
    Search/                      # search matches/options, path filtering, and store-backed workspace search
    SyntaxParsing/               # syntax manager
    Utilities/                   # standardized paths and checkout path identity
    VCS/                         # git/VCS substrate, git diff snapshots, and worktree initialization
    WorkspaceContext/            # context store, indexing, path lookup/resolution, presentation, selection, slices, search, token accounting
    WorkspaceFiles/              # file-system item models, codemap UI presentation models, and sorting helpers
    Workspaces/                  # checkout refresh service and root actions
  RepoPrompt/                    # internal RepoPromptApp implementation library target (not a package product)
    App/                         # lifecycle, launch/configuration, commands, composition wiring, app notifications, root app views/view models
      Notifications/
      Sparkle/
      ViewModels/
      Views/
    Features/
      AgentMode/                 # Agent Mode UI, models, view models, onboarding, recommendations, and shared agent runtime ownership
        Runtime/Providers/       # provider/runtime enum and provider factory shared by Context Builder, Agent Mode, MCP, and recommendations
        History/                 # cross-workspace session history scanner, MCP tool service (history.list_sessions / search / time / get_session)
      Chat/                      # chat/oracle models, services, diff state, view models, and views
      ContextBuilder/            # Context Builder product UI/runtime, view models, settings, prompts, budget defaults, and response-type mapping
      Diagnostics/               # app-integrated benchmark/debug/stress/diagnostic surfaces
      Prompt/                    # prompt UI, copy/prompt models, packaging, accounting, compact selected-files components, and view models
      Settings/                  # settings models, view models, and views
      WorkspaceFiles/            # workspace root shell, selection, and file-list projection view models; no native tree visualization
      Workspaces/                # workspace manager UI and view models
    Infrastructure/
      AI/                        # AI provider/model/prompt/query substrate (Prompts/AgentModePrompts.swift stays here)
      MCP/                       # app-side MCP infrastructure, app-local MCP helpers, and MCP view model adapters
      Persistence/               # app persistence helpers such as preset file storage
      Process/                   # app-owned CLI installation and executable identity
      Security/                  # app key management and Remote Control pairing
      UI/                        # app-specific UI: agent cards/menus, approval overlays, composer chrome, workspace-backed mention/text-field adapters
      Utilities/                 # app-specific utilities (error extensions, shortcuts)
      WorkspaceContext/          # app-side workspace selection coordination over the RepoPromptWorkspace engine
  RepoPromptRemoteWire/          # dependency-free remote-control wire DTOs, canonical JSON, tickets, and signing helpers
  RepoPromptGateway/             # gateway executable: app links, auth, audit, relay, push, watch, wire adapters, and PWA resources
  RepoPromptMCP/                 # thin repoprompt-mcp executable entry delegating to RepoPromptMCPCore
  RepoPromptC/                   # C support target
  CSwiftPCRE2/                   # C PCRE2 target
  TreeSitterScannerSupport/      # narrow exact-snapshot JavaScript/Python scanner ABI fallback
  CRepoPromptCodeMode/           # app-only bounded code-mode host over vendored QuickJS-ng
Tests/
  RepoPromptTests/               # XCTest tests, support, and fixtures
```

The external target graph is intentionally stable at its boundary: the executable products and emitted binaries remain `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-gateway`. The `RepoPrompt` executable target delegates to the internal `RepoPromptApp` target, while the `RepoPromptMCP` executable target contains only its process entry and delegates to the `RepoPromptMCPCore` package product. `RepoPromptApp` is not declared as a library product or separate Xcode convenience scheme. Root app and gateway tests import their root targets plus the required `RepoPromptCore` products.

`RepoPromptAgentCore` holds the agent runtime and AI. It is an internal, static library target with no product. It holds the self-contained agent runtime: Agent Mode sessions, runners, providers, transcript and tool tracking, scheduling, MCP agent services and DTOs, AI providers, models and prompts, and remote hosts. Among app modules it may depend only on `RepoPromptWorkspace` and `RepoPromptPlatform`; its other dependencies are the `RepoPromptShared` package product, `RepoPromptRemoteWire`, and the packages it imports (`Logging`, the `MCP` SDK, `SwiftAnthropic`, `SwiftOpenAI`, and `RepoPromptClaudeCompatibleProvider`). It must never depend on `RepoPromptApp`, the executables, `RepoPromptGateway`, or `RepoPromptUI`, and it has no bridging header. Code that needs app or UI declarations stays in the app (for example `AgentPreviewLinkRouter` and the Codex native slash-command suggestions extension); app singletons it needs arrive through injected closures (for example `CodexModelPollingService`). Declarations default to `internal`; mark `package` only what `RepoPromptApp` uses. `RepoPromptTests` depends on it and every `@testable import RepoPromptApp` file also has `@testable import RepoPromptAgentCore`.

`RepoPromptPlatform` holds dependency-free generic primitives: concurrency, process/CLI launch, regex and the SwiftPCRE2 wrapper, networking, filesystem caches and the spill-backed artifact store, secure-storage and code-signing mechanics, tree-sitter query strings, and generic utilities. It is an internal, static library target with no product and depends on no other app module: only the `RepoPromptShared` package product, the `RepoPromptC` and `CSwiftPCRE2` C targets, and system frameworks. It must never depend on `RepoPromptApp`, `RepoPromptAgentCore`, `RepoPromptUI`, `RepoPromptWorkspace`, the executables, or `RepoPromptGateway`. Code that needs app, product, or domain declarations stays in a higher module (for example `GitignoreCompiler`, `IgnoreDebugMetricsRecorder`, and `CodeMapSecureFileRemoval` in `RepoPromptWorkspace`; `Shortcuts` and `RemoteScope` in the app). Declarations default to `internal`; mark `package` only what another target uses. `RepoPromptApp` and `RepoPromptTests` depend on it, and every `@testable import RepoPromptApp` file also has `@testable import RepoPromptPlatform`.

`RepoPromptUI` holds reusable presentation code: typography (`FontScaleManager`, `FontScalePreset`, the transcript code-font resolver), `UIDisplayPreferences`, markdown rendering, tooltips, generic components and text views, syntax highlighting, and the secure HTML preview. It is an internal, static library target with no product. Among app modules it may depend only on `RepoPromptPlatform` (currently it needs none); its package dependencies are `Markdown`, `Neon`, and `SwiftTreeSitter`. It must never depend on `RepoPromptApp`, `RepoPromptAgentCore`, `RepoPromptWorkspace`, the executables, or `RepoPromptGateway`, and `GlobalSettingsStore` stays in the app: `RepoPromptSwiftUIApp.init` binds `FontScaleManager` to the store and forwards display preferences into `UIDisplayPreferences`. Product-feature views and adapters over agent, MCP, approval, or workspace types stay in the app (for example `CheckRecommendationsButton`, `NotificationsButtonView`, `SnippetPaletteHelper`, and `AgentSidebarSizing`). Declarations default to `internal`; mark `package` only what another target uses. `RepoPromptApp` and `RepoPromptTests` depend on it, and every `@testable import RepoPromptApp` file also has `@testable import RepoPromptUI`.

`RepoPromptWorkspace` holds the workspace engine: the workspace file context store and its models, indexing, path lookup and resolution, selection, slices, token accounting, codemap presentation and artifacts, search, filesystem services and ignore rules, VCS/git diff and worktree substrate, diffing, the syntax manager, durable artifact persistence, and the workspace restore, root-load, worktree-startup, and edit-flow instrumentation. It is an internal, static library target with no product. Among app modules it may depend only on `RepoPromptPlatform`; its other dependencies are the `RepoPromptShared` package product, the `RepoPromptC` and `TreeSitterScannerSupport` C targets, `SwiftTreeSitter` with the tree-sitter grammar products, and `UniversalCharsetDetection`/`Cuchardet`. It must never depend on `RepoPromptApp`, `RepoPromptAgentCore`, `RepoPromptUI`, the `MCP` SDK product, the executables, or `RepoPromptGateway`. Product view models and adapters over workspace types stay in the app (for example `WorkspaceFilesViewModel`, `FileViewModel`/`FolderViewModel` adapters, `WorkspaceSelectionCoordinator`, and the workspace manager UI). Declarations default to `internal`; mark `package` only what another target uses. `RepoPromptApp` and `RepoPromptTests` depend on it, and every `@testable import RepoPromptApp` file also has `@testable import RepoPromptWorkspace`.

The legacy top-level layer buckets under `Sources/RepoPrompt` have been pruned and must not be recreated:

- `Models`
- `Notifications`
- `Services`
- `Shared`
- `Utils`
- `ViewModels`
- `Views`
- `Features/SynthaxParsing`
- `Features/Benchmark`

## Post-native-tree terminology

The old native file-tree visualization is no longer a live product surface. Do not add back `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, or `SearchFileTreeViewModel` source paths/symbols.

“File tree” remains valid when it refers to compatibility or textual context contracts, including the MCP `get_file_tree` tool, tool result cards, API/persisted symbols such as `FileTreeOption`, historical plans, and prompt/context output such as `<file_map>` / project structure maps. Contributor-facing UI and docs should prefer “project structure map” when describing generated textual context so it is not confused with the removed native UI.

The old IDE-era Prompt selected-files panel is also removed. Do not add back `PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, or the Prompt-owned copy/chat preset picker helpers. The live compact selected-files UI remains `SelectedFilesGrid` plus `FilePreviewPopover`, and the Settings chat preset picker lives under `Features/Settings`.

## Placement rules for new files

- `Sources/RepoPromptExecutable` is restricted to the shipped executable entry. Do not add lifecycle, feature, infrastructure, startup, or composition logic there.
- New product-flow code goes under `Sources/RepoPrompt/Features/<FeatureName>`.
- New app lifecycle, launch/configuration, command, root view/view-model, notification-name, and composition-root wiring goes under `Sources/RepoPrompt/App` in the `RepoPromptApp` target.
- There is no Objective-C bridging header. Swift reaches C code through explicit module imports (`RepoPromptC`, `CSwiftPCRE2`, tree-sitter grammar modules); expose new C entry points through public headers in `Sources/RepoPromptC/include`, except for the documented `CRepoPromptCodeMode` target below.
- New cross-cutting service/platform code goes under `Sources/RepoPrompt/Infrastructure/<Area>`; dependency-free generic primitives that use no app declarations go under `Sources/RepoPromptPlatform/Infrastructure/<Area>`.
- New workspace-engine code (context store, indexing, path lookup, selection/slices, token accounting, codemap, search, filesystem, VCS, diffing, syntax parsing, durable artifacts) that needs no app, agent, UI, or MCP declarations goes under `Sources/RepoPromptWorkspace/<Area>`; product view models and adapters over it stay in the app.
- Native Remote Control host discovery/client transport and persistence belong under `Infrastructure/RemoteHosts`; app-owned pairing keys, discovery authority, and approval routing belong under `Infrastructure/Security/RemotePairing`; gateway admission/relay stays in `RepoPromptGateway`; shared signed discovery wire DTOs stay in `RepoPromptRemoteWire`; onboarding presentation stays under `Features/Settings`.
- Provider-neutral workflow prompt catalog metadata and renderers go under `Sources/RepoPromptAgentCore/AI/Prompts/Workflows/`; do not add new workflow prompts under provider-specific command names or bundled `AppResources/Services/AI/Prompts` mirrors.
- New reusable SwiftUI components, text/markdown helpers, and UI services should prefer a narrow feature owner first; otherwise use `Sources/RepoPromptUI/<Area>` when they need no app declarations (settings stores, view models, agent/MCP/workspace types), or `Sources/RepoPrompt/Infrastructure/UI/<Area>` when they do.
- New generic extensions/helpers should prefer a narrow feature or infrastructure owner first; otherwise use `Sources/RepoPromptPlatform/Infrastructure/Utilities` when they need no app declarations, `Sources/RepoPromptWorkspace/Utilities` for workspace path helpers, or `Sources/RepoPrompt/Infrastructure/Utilities` when they need app declarations.
- New app-visible diagnostic surfaces go under `Sources/RepoPrompt/Features/Diagnostics` and must have a documented purpose and entry point; workspace-engine instrumentation recorded inside the engine goes under `Sources/RepoPromptWorkspace/Diagnostics`.
- New app/client protocol definitions shared by multiple executables go under `Packages/RepoPromptCore/Sources/RepoPromptShared`, except for the documented remote-control wire exception below.
- MCP filesystem/product/build-flavor identity, bootstrap handshake wire DTOs, and external-client event wire DTOs are single-sourced under `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP`; app/helper targets may keep only local compile-flavor selection and app-only presentation behavior.
- New reusable bootstrap MCP client plumbing shared by the CLI and gateway clients goes under `Packages/RepoPromptCore/Sources/RepoPromptMCPClientKit`.
- New gateway-only app-link, auth, audit, relay, push, server, watch, resource, and wire-adapter code goes under `Sources/RepoPromptGateway`; dependency-free remote-control protocol DTOs and signing helpers remain in `Sources/RepoPromptRemoteWire`.
- New app-local MCP/socket/routing helpers go under `Sources/RepoPrompt/Infrastructure/MCP`, not `Sources/RepoPrompt/Shared`.
- New importable CLI implementation code goes under `Packages/RepoPromptCore/Sources/RepoPromptMCPCore`; `Sources/RepoPromptMCP` remains the thin executable entry only. Its one exception is the private Restart-safely relaunch mode (`--rpce-private-relaunch-v1`, lossless restart Phase 4): `main.swift` classifies that reserved argument before any MCP code runs and delegates to `RepoPromptPlatform` (`Infrastructure/Process/ProcessRelaunchHelper.swift`, which owns the closed v1 protocol). `RepoPromptPlatform` is therefore a dependency of the `RepoPromptMCP` target only; no new product or target exists for the helper.
- New test doubles, fixtures, parser inputs, sample projects, benchmark-only fixture data, and XCTest-only helpers go under `Tests/RepoPromptTests`, not the app target.
- Do not create directories named `Tests`, `TestSupport`, or `Fixtures` under `Sources/RepoPrompt`, `Sources/RepoPromptAgentCore`, `Sources/RepoPromptPlatform`, `Sources/RepoPromptUI`, or `Sources/RepoPromptWorkspace`.
- Do not put parser fixtures or sample parser inputs under `Sources/RepoPromptWorkspace/SyntaxParsing` or `Sources/RepoPromptPlatform/Infrastructure/SyntaxParsing`; keep only production parser/query code there.
- Keep `App/WindowState.swift` in `App` until there is a separate composition-root refactor; physical moves must preserve initialization order.

## Exception policy

Exceptions must be explicit, narrow, and documented here before they become precedent.

### Remote-control wire target

- `Sources/RepoPromptRemoteWire` is a purpose-built sibling target for the native remote-client and gateway remote-control protocol. It owns dependency-free `RemoteClientFrame` / `RemoteServerFrame` DTOs, `JSONValue.canonicalString`, canonical frame hashing/signing payload helpers, `RemoteTicket`, `RemoteFrameSigner`, and `RemotePairingProof`.
- The target may import only `Foundation` and `CryptoKit`; it must not import MCP, NIO, Logging, `RepoPrompt`, `RepoPromptGateway`, `RepoPromptMCP`, `RepoPromptMCPClientKit`, or `RepoPromptShared`. `Scripts/source_layout_guardrails.sh` enforces this import guardrail.
- Gateway-only capabilities stay in `Sources/RepoPromptGateway/Wire` as extensions/adapters, including `RemoteWireProtocol.commandFingerprint(for:)`, `JSONValue`↔`MCP.Value` bridging, and `RemoteMCPToolResultCodec`.
- Do not widen `RepoPromptShared` or link the app against `RepoPromptGateway` to share remote-control wire code.

### App-visible diagnostics retained in the RepoPromptApp target

These files are intentionally compiled as app-integrated diagnostics and live under `Sources/RepoPrompt/Features/Diagnostics`:

- `Features/Diagnostics/Benchmark`: the Settings-visible Repo Bench surface, including benchmark core, settings UI/view model, run store, reporting, and local rankings. If Repo Bench needs a headless/CI runner, create a separate executable-target plan rather than hiding target churn in this layout cleanup.
- `Features/Diagnostics/AgentMode`: debug-only Agent Mode performance instrumentation and text-derivation diagnostics.
- `Features/Diagnostics/AgentMode/Stress`: debug-only Agent chat stress launch configuration, harness, overlay panel, and stress support extensions on `AgentModeViewModel`, launched with `-RP_AGENT_CHAT_STRESS` and `RP_AGENT_STRESS_*` environment variables.
- `Features/Diagnostics/MCP`: hidden DEBUG MCP diagnostics, transport diagnostics, Sparkle diagnostics, and memory sampling exposed through `__repoprompt_debug_diagnostics` / legacy debug transport tools.
- `Features/Diagnostics/Prompt`: DEBUG prompt/token recount event forwarding, selection signatures, and selected-path watchdog state surfaced through restore performance diagnostics.
- `Features/Diagnostics/CodeMap`: DEBUG CodeMap initial-root-load timing wrappers surfaced through restore performance diagnostics.
- `Features/Diagnostics/App`: main-thread stall watchdog, worktree-startup benchmark reporting, selection debug signatures, and workspace-switch search-index diagnostics. The engine-side workspace restore performance log, DEBUG root-load trace correlation (`WorkspaceRootLoadDiagnostics`), and worktree-startup instrumentation live in `Sources/RepoPromptWorkspace/Diagnostics`.

### Documented wiring exceptions outside Diagnostics

- `App/AppLaunchConfiguration.swift` remains in `App` because it owns process arguments/environment interpretation for launch behavior. It still routes DEBUG-only Agent chat stress settings, but harness-specific configuration lives under `Features/Diagnostics/AgentMode/Stress`.
- `App/WindowState.swift` remains the composition root and continues to instantiate/pause the DEBUG-only `AgentChatStressHarness`. This is wiring only; harness implementation lives under Diagnostics.
- `Sources/RepoPromptPlatform/Infrastructure/Security/EphemeralSecureKeyValueStore.swift` remains with security storage code, not Diagnostics, because it is a required debug-app secure-storage backend rather than a fixture or visible diagnostic harness. It is `#if DEBUG`, in-memory only, and preserves existing debug behavior for ad-hoc/ephemeral secure storage.

### Tree-sitter scanner linker compatibility target

- `Sources/TreeSitterScannerSupport` is an internal C linker compatibility target, not a restored local grammar target. It contains byte-for-byte exact-snapshot copies of the upstream JavaScript and Python `scanner.c` implementations plus their required `tree_sitter` helper headers. It does not contain parser copies, grammar definitions, queries, or CE-authored scanner code.
- Clean coordinated SwiftPM root graphs compile the exact-pinned upstream JavaScript and Python parser objects but omit their scanner objects, leaving unresolved external-scanner ABI symbols. `TreeSitterScannerSupport` supplies only those missing symbols while CE continues linking the upstream package products.
- The tracked checksum manifest at [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) protects the copied snapshots from drift. Do not expand this target, restore the seven retired local grammar directories, or replace the target with transient `.build/checkouts` mutation. Remove the target, guardrails, checksums, and this exception together only after validated upstream revisions or SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

### Code-mode QuickJS-ng target

- `Sources/CRepoPromptCodeMode` is an internal C target that only `RepoPromptApp` depends on. `src/RepoPromptCodeMode.c` is the CE-authored bounded host, and `include/RepoPromptCodeMode.h` is its only public interface. Swift reaches it only from `Sources/RepoPrompt/Infrastructure/MCP/CodeMode`.
- `vendor/quickjs-ng` holds an unmodified QuickJS-ng 0.17.0 subset: `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, and the headers they need. It never includes `quickjs-libc` or any other filesystem, OS, module, or timer layer. Provenance, the archive checksum, the license, and update steps live in [`ThirdPartyLicenses/quickjs-ng`](../../ThirdPartyLicenses/quickjs-ng/README.md). The tracked `vendor.sha256` manifest protects the vendored files from drift.
- Do not edit vendored files in place, add other upstream files, or let any other target depend on this one. To update QuickJS-ng, replace the whole subset from a verified upstream archive and regenerate the manifest.

No top-level `Sources/RepoPrompt/Notifications` exception remains; app-wide notification-name extensions now live under `Sources/RepoPrompt/App/Notifications`.

## Generated IDE artifacts

The generated Xcode workspace lives under `.build/xcode` and is not part of the
source layout or a second target graph. `Package.swift` continues to own source,
target, dependency, and test-resource membership. Edit the generator and
workflow wrapper under `Scripts`, then regenerate; never edit or track generated
workspace files. See [`xcode-workspace.md`](xcode-workspace.md).

## Guardrails

Run the source-layout guardrails before or after source-layout-sensitive changes:

```bash
make guardrails
# or
./Scripts/source_layout_guardrails.sh
```

The guardrail script verifies:

- the shipped `RepoPrompt` executable source root contains only its entry file, declares exactly one `@main`, and the current `RepoPromptApp` implementation target declares none;
- the shipped `RepoPromptMCP` executable source root contains only `main.swift` and delegates implementation to the `RepoPromptMCPCore` package product (plus the private relaunch mode in `RepoPromptPlatform`);
- `Package.swift` keeps the current implementation target named `RepoPromptApp` at `Sources/RepoPrompt`, with the `RepoPrompt` executable as its thin sole-dependent entry target;
- `RepoPromptAgentCore` exists as a library target at `Sources/RepoPromptAgentCore` and declares no `@main`;
- `RepoPromptPlatform` exists as a library target at `Sources/RepoPromptPlatform` and declares no `@main`;
- `RepoPromptUI` exists as a library target at `Sources/RepoPromptUI` and declares no `@main`;
- `RepoPromptWorkspace` exists as a library target at `Sources/RepoPromptWorkspace` and declares no `@main`;
- the RemoteWire import guardrail keeps `RepoPromptRemoteWire` dependency-free and permits only `Foundation` and `CryptoKit` imports, never app, gateway, MCP, NIO, logging, or shared implementation modules;
- old top-level layer buckets are absent or contain no files;
- no `Tests`, `TestSupport`, or `Fixtures` directories exist under `Sources/RepoPrompt`, `Sources/RepoPromptAgentCore`, `Sources/RepoPromptPlatform`, `Sources/RepoPromptUI`, or `Sources/RepoPromptWorkspace`;
- `MCPControlMessages.swift` and `MCPFilesystemIdentity.swift` exist only under `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP`, and the `MCPExternalClientEvent` wire DTO is declared only there;
- parser fixtures/sample inputs do not live under Workspace or Platform syntax parsing source;
- the narrow `TreeSitterScannerSupport` compatibility target has exactly its approved JavaScript/Python scanner snapshots and helper headers, matches curated checksums, remains wired in `Package.swift`, preserves the seven migrated grammar pins/products in `Package.swift` and `Package.resolved`, and keeps the seven retired local grammar directories absent;
- Agent/MCP runtime code does not depend on `WorkspaceFilesViewModel`, `FileViewModel`, or `FolderViewModel`;
- removed native-tree/search artifact paths are not tracked again;
- removed native-tree/search/eager-loading symbols such as `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, `SearchFileTreeViewModel`, `RootDescendantMaterialization`, `legacyMaterializedRootKeys`, `legacyMaterializeDescendantsRecursively`, and `legacyEager` are not referenced from app or Workspace source;
- removed Prompt UI cleanup artifacts (`PresetBottomBar.swift`, `SelectedFileView.swift`, `SelectedFilesPanelViewModel.swift`) and unique stale symbols (`PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, `PresetTwoPanePopover_Copy`, `CopyPresetPreviewView`, `PresetTwoPanePopover_Chat`) are not referenced from app source;
- `App/WindowState.swift` does not reintroduce scoped `searchViewModel` wiring;
- `WorkspaceFilesViewModel.swift` does not reintroduce the removed `loadContentsRecursively` eager-loading seam.

## Historical resolved items

- `MCPControlMessages.swift`, `MCPFilesystemIdentity.swift`, and the `MCPExternalClientEvent` wire DTO have one source of truth in `Packages/RepoPromptCore/Sources/RepoPromptShared/MCP`; the app and CLI targets depend on the `RepoPromptShared` package product.
- The old production dependency on a test-named filesystem seam was renamed to `FileSystemProviding`; test doubles/support live under tests.
- The dead Dart parser fixture under app source was removed rather than retained as production code.
- Workspace, Agent Mode, MCP infrastructure, workspace context/files, Prompt, Context Builder, Chat, Search, Settings, Code Map, and syntax parsing were moved toward the hybrid feature/infrastructure layout.
- Benchmark, debug, and stress harnesses were classified as app-integrated diagnostics or documented wiring exceptions.
- The old top-level layer buckets were pruned as part of Work Item 11.
- The native file-tree visualization, IDE-era search view-model layer, and eager root materialization seams were removed. Textual project structure maps and MCP `get_file_tree` output remain supported compatibility surfaces.
- The Claude-compatible Agent Mode provider family was extracted into the `RepoPromptClaudeCompatibleProvider` package product under `Packages/RepoPromptAgentProviders/`; see `docs/architecture/provider-plugins.md` for the bridge/adapter layout and rules for adding new providers.
- Workflow prompt generation now lives in the provider-neutral catalog under `Sources/RepoPromptAgentCore/AI/Prompts/Workflows/`; the old provider-specific `ClaudeCodeCommands` surface and duplicated bundled prompt mirror under `AppResources/Services/AI/Prompts/` should not be restored.

## Contributor validation commands

Run the smallest focused validation that covers your change, then broaden as needed:

```bash
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-swift-build PRODUCT=repoprompt-gateway
make dev-core-test
make dev-test FILTER=CodexIntegrationConfigurationTests
make dev-test FILTER=WorkspaceFileContextStoreTests
make dev-test
make guardrails
make doctor
make dev-build
make dev-test
```

For validation that needs the visible debug app, follow the [development workflow](../context/workflows/development.md) and the just-in-time approval invariant in [`AGENTS.md`](../../AGENTS.md); use `make dev-run` instead of the uncoordinated fallback.
