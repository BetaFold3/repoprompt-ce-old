# Phase 3 Platform initial review — OracleB

Scope: read when the task touches review of the bounded process-inspection and launcher-marker slice.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Complete-source initial review; earlier invalid packaging was not counted as approval. Chat: `restart-platform-complet-F5554E`.

# Oracle Review



# Review: Lossless restart Phase 3, Platform slice (ProcessInspection + RPCE_RUNTIME_ID marker)

## Summary

This slice adds `ProcessInspection`, a read-only, stateless way to inspect a single PID. It reads the identity twice, before and after the supporting fields, and checks that both reads agree. It also adds an optional `RPCE_RUNTIME_ID` marker to `ProcessLauncher`, which defaults to `nil`.

The four properties you asked me to check mostly hold:

- **No false exit.** `.notFound` only comes from `ESRCH` on a basic-info read. A zero return with a stale `errno` is reported as `malformedResponse`, not absence. ESRCH on the path or group read can't make the result `.notFound`. The boot-identity checks fail safe.
- **No lost child ownership.** The spawn path, descriptors, flags, process group and `SpawnedProcess` are unchanged.
- **No-marker behavior unchanged.** With `nil`, `launchEnvironment` returns the caller's dictionary as-is.
- **Data minimization.** Results carry no argument or environment contents.

The one real defect is in the `KERN_PROCARGS2` parser. It can report a marker as "verifiably absent" when the process is carrying it. Everything else is P2/P3.

I reviewed against the code as written. Some kernel facts below come from memory of XNU/libuv sources and need the live check that is already deferred; I mark where that applies.

## P1 (Should fix)

### F1. Parser reports "verified absence" for processes that rewrite their argv area (e.g. Node/libuv `process.title`)

- **Where:** `ProcessInspection.swift:284–294` (the argc loop, then the env loop that stops at the first empty string). The contract that depends on it is at `:60` ("`nil` means the variable was verifiably absent") and in `phase3-platform.md` ("`nil` means verified absence").
- **Failure scenario:**
  - `KERN_PROCARGS2` returns the process's live string area, not a frozen copy taken at exec.
  - libuv's `uv_set_process_title` copies the title into the `argv[0]` slot and zero-fills the rest of the contiguous argv area. Node uses this when a CLI sets `process.title`.
  - Take a process launched as `node /path/claude --print` that then sets `process.title = "claude"`. Its buffer becomes `claude\0\0\0…\0<env…>`.
  - The argc loop (argc = 3) reads `"claude"`, then counts two single-byte empty strings as arguments. The cursor is still inside the zero run.
  - The env loop sees `buffer[cursor] == 0` and stops at once. The parser returns `.available(runtimeID: nil, claudeConfigDirectory: nil)`.
- **Impact:** The plan learns the provider home from the real `claude` descendant's `CLAUDE_CONFIG_DIR` and matches ownership by marker (spec R6). A false "verified absence" is a wrong answer, not an "unknown". Discovery could treat a marked writer as unowned or as having no home, which undermines the two-writer rule. Whether the shipped Claude build (Node vs. Bun binary) rewrites argv is a live-gate question. But a `claude`-only `ps` line is the usual sign that it does, and the primitive's contract is wrong either way.
- **Smallest fix:**
  1. After the argc loop, skip a run of NUL bytes before reading the environment, the same way the exec-path padding is skipped at `:280–282`. psutil does this too.

     ```swift
     for _ in 0 ..< argumentCount { … }
     while cursor < buffer.count, buffer[cursor] == 0 { cursor += 1 }   // zero-filled argv tail
     ```

     With an empty environment the cursor may now run into the trailing `executable_path=…`-style entries. That is harmless, because none of their keys match the selected keys. All 25 existing tests still pass with this change.
  2. Add a fixture with a zero-filled argv tail, e.g. `"claude\0\0\0\0\0\0" + env`.
  3. Weaken the doc wording from "verified absence" to "absent from the process's current exec string area". The next slice should treat `nil` as weak evidence, never as proof that a process isn't owned. A process can overwrite that memory, and env changes made with `setenv` never show up in it.

## P2 (Consider)

### F2. An inherited marker passes through untouched when `runtimeID` is `nil`

- **Where:** `ProcessLauncher.swift:78`; the test pins this at `ProcessLauncherRuntimeMarkerTests.swift:18–23`.
- **Scenario:** You run a dev build of RepoPrompt from inside an agent's Bash tool. The dev app then inherits `RPCE_RUNTIME_ID`, and every child it spawns with `nil` carries the outer runtime's marker. So do children launched through Foundation `Process`. Once discovery exists, the outer instance would treat those processes as its own descendants.
- **Status:** Inactive today, and it matches the stated contract.
- **Fix (decide before activation):** Unset the marker once at app startup (`unsetenv`), rather than stripping it in the launcher, because the launcher isn't the only spawn path. Record it as `assumed:` or `deferred:`.

### F3. An `exec` during sampling can mix evidence from two images

- **Where:** `ProcessInspection.swift:157–172`.
- **Why:** PID, start time and UID all survive `execve`. A shim that `exec`s `claude` keeps one birth identity. If the exec lands between the path read and the args read, the result pairs the old image's path with the new image's env, and the identity bracket can't catch it.
- **Impact:** Rare, mainly at startup, and the fields are already documented as supporting evidence.
- **Fix:** Document it as a known limitation in the evidence doc. No code change.

### F4. Zombies come back as `.observed`

- **Where:** `BasicInfo` (`:111–117`) and `Backend.readBasicInfo` (roughly `:397–403`) drop `pbi_status`.
- **Why:** As far as I recall XNU, `PROC_PIDTBSDINFO` deliberately resolves zombies. An exited but unreaped writer would then look alive, with its path and args unavailable, and could block Resume indefinitely under the two-writer rule.
- **Fix (cheap):** Carry `isZombie = (info.pbi_status == SZOMB)` through `BasicInfo` into `ProcessObservation`, and add one scripted test. The live zombie gate is already deferred, so you could also defer this, but it's a three-line change.

### F5. An empty `argv[0]` gets consumed as padding

- **Where:** `:280–282`.
- **Scenario:** For a process spawned with `argv[0] == ""`, the padding loop swallows `argv[0]`. The argc loop then consumes the first env entry as an argument. `ProcessLauncher` emits env in dictionary order, so the marker can be that first entry and be silently lost.
- **Impact:** Contrived; `ps` and psutil have the same ambiguity.
- **Fix:** Note it in the doc. No code change.

## P3 (cheap improvements)

- **Copy only selected values (`:300`).** `Array(entry[(separator + 1)...])` copies every environment value, including unrelated secrets, before checking the key. Move the copy inside the two matching branches. This is a one-line minimization fix.
- **Identity uses effective UID.** `pbi_uid` is the effective UID. A same-process `seteuid` or a setuid exec would change the identity, which the spec reads as "exited". It's fine for the PROCARGS2 access check, which also uses the effective UID. Note it next to the spec's UID definition, or use `pbi_ruid` for identity.
- **Doc wording.** The spec says "Any mismatch means `exited`" (spec line 287), but this primitive returns `unavailable(consistency)` when its two reads disagree. That's correct: it's a sampling race, not a mismatch against a recorded identity. Add one sentence to the evidence doc saying the "mismatch ⇒ exited" rule applies when comparing against a recorded identity, not to this internal check.
- **Test gap.** Add the zero-filled argv fixture from F1 and, if you take F4, a zombie case.

## Verified, no finding

- **`errno` handling.** Both `proc_*` paths clear `errno` before the call and capture it right after. The stale-ESRCH case maps to `malformedResponse`, and the tests prove it with fake queries.
- **Access gate.** The UID gate (`:160`) uses the same effective-UID check the kernel applies to `KERN_PROCARGS2`, so skipping the query and reporting `accessDenied` is accurate.
- **Bounds checks.** Every cursor step in the parser is guarded. Negative or oversized `argc`, an unterminated final entry, duplicate selected keys, a bad UUID and invalid UTF-8 in selected values all fail closed with `malformedResponse`.
- **Launcher.** It builds `envp` from a local copy, so the caller's dictionary is never mutated. The `debugSpawn` defaulted parameter placement compiles and keeps existing call sites source-compatible.
- **Validation claims.** The suites contain 25 and 5 tests, matching the reported counts, and the evidence doc doesn't overclaim live qualification.
