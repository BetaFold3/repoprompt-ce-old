# Code-mode lab measurements (2026-10-10 to 2026-10-12)

Scope: read when the task touches code-mode cost, correctness or long-session evidence, re-running the code-mode lab, or the numbers behind the D3 gate in the code-mode plan.
Authority: Reference
Last-verified: 2026-10-17

This is the persistent record of every number the code-mode lab produced. The decisions and gate live in the plan (`docs/context/plans/2026-10-03-code-mode-readiness-and-git-narrowing-plan.md`, §3 and §7); this file keeps the full per-arm, per-task and per-turn figures so they survive the local lab folder. All numbers are local aggregates from runs against this repository; no session content is quoted.

## 1. Data, scripts and what was lost

- **Raw rows and scripts (local, git-ignored):** `docs/investigations/2026-10-10-codemode-lab/`. `results_*.jsonl` hold one row per task run (session rows add `seq`, `turn`, `ctx_end`, `req`). `ledger.py` with `ledger_spec.py` regenerates every table in §5 (`LEDGER_SPEC=ledger_spec.py python3 ledger.py`); `enrich_ctx.py` adds the end-of-turn context size from the Codex rollouts and Claude transcripts. The harness runs from `/tmp/cmexp` (copy the folder there; QuickJS-ng 0.17.0 must be rebuilt into `qjs/` without `quickjs-libc.c`).
- **Lost on 2026-10-12:** `/tmp/cmexp` was cleared. The original 360-run lab (plan §3.4: Claude, Pi 1.1, Codex, OpenCode 1.18 and 2.0 arms) and the §3.7 fault runs' per-run logs were only there. Their headline numbers survive in plan §3.4 and §3.7; the §3.7 fault rows survive with raw totals only (no price weighting). Every other result set below was regenerated from surviving rows and reproduces the plan's figures exactly.

## 2. Method

- **Metric: price-weighted tokens (wtok)** = uncached input ×1 + cache write ×1.25 + cache read ×0.1 + output ×5 (Sonnet's relative list prices). On Claude Sonnet, 1M wtok ≈ $3. Raw totals are dominated by cheap cache reads and mislead (plan §3.4).
- **Ratios:** geometric mean over tasks of per-task median wtok, arm ÷ baseline; below 1 is cheaper. Brackets are 95% bootstrap intervals (2,000 resamples of repetitions within tasks). Session ratios use paired session totals (same task order and repetition), bootstrapped over pairs.
- **Gate (plan §7):** per task kind, ratio ≤ 1.10; no task loses its majority of correct runs; a savings claim needs the interval below 1; ≥ 5 repetitions.
- **Tasks:** 14 with machine-checked truth on this repository. Single lookup T1, T3, T5; multi-step T2, T4, T6; heavy fan-out T7, T8 (rank or count over 20–30 files); understand U1–U3 (trace behaviour through function bodies); edit E1–E3 (return a unified diff, graded by `git apply` plus checks). Truths were re-verified against the tree on 2026-10-12.
- **Hosts:** Claude Code 2.1.281 (Sonnet unless marked Opus) through the owner's rotator shim; Codex `gpt-6-sol` at low effort unless marked high, 0.159 for 2026-10-10/11 runs and 0.162.0-alpha.17.2 for 2026-10-12 runs, through the owner's shim with RepoPrompt's real launch overrides; Pi 1.1 with an OpenAI model. Both arms of every comparison ran on the same version in the same window.
- **Arms:** `cc_text` / `cx_text_rp` are today's baseline (Claude: RepoPrompt tools direct; Codex: RepoPrompt tools inside Codex's native code mode). `cc_cm`, `cx_dons_rpcm` add RepoPrompt `code_mode` with the Node prototype executor; `cc_cm2`, `cx_dons_rpcm2` use the QuickJS-ng executor with the plan §6 rules. `dons` = Codex `features.code_mode.direct_only_tool_namespaces=["mcp__rp"]` (RepoPrompt tools direct). `_f1` / `_f2` = injected faults (15% transient errors / 20% of calls slowed 10 s). `_opus`, `_hi` = Claude Opus, Codex high effort.
- **Sessions:** each task is one user turn in the same CLI session. Codex turns use `codex exec resume`. Claude turns use either one long-lived `--input-format stream-json` process (how Agent Mode drives Claude) or `--resume` per turn (new process each turn).
- **Codex session usage:** `codex exec resume` reports usage as the running thread total, so per-turn Codex usage is the difference between consecutive turns (`ledger.py` does this; it warns if any difference is negative, and none was).
- **Context at end of turn (`ctx_end`):** input tokens of the last model request in the turn (Codex `last_token_usage.input_tokens`; Claude input + cache read + cache write of the last assistant message). It is the context the next turn starts from.

## 3. Headline results

| Date | Comparison | Host | Set | Reps | Ratio [95% CI] | Correct (code mode / baseline) |
|---|---|---|---|---:|---|---:|
| 10-10 | optional `code_mode` (Node) | Claude Sonnet | T1–T8 | 3 | ×0.89 [0.72–1.00] | 96% / 96% |
| 10-10 | RP direct + `code_mode` vs native code mode | Codex | T1–T8 | 5 | ×0.80 [0.62–1.02] | 40/40 / 56/56 |
| 10-10 | RP direct, no `code_mode` vs native | Codex | T1–T8 | 5 | ×1.18 [0.84–1.36] | 40/40 / 56/56 |
| 10-10 | `code_mode` nested in Codex code mode | Codex | T1–T8 | 3 | ×1.12 [0.91–1.37] | 24/24 / 24/24 |
| 10-10 | direct + `code_mode` vs direct | Codex gpt-5.5 | T1–T8 | 3 | ×0.75 [0.62–1.13] | 24/24 / 24/24 |
| 10-10 | `exposure: direct` + `code_mode` vs Pi direct | Pi 1.1 | T1–T8 | 3 | ×0.89 [0.69–1.10] | 24/24 / 24/24 |
| 10-10 | the same vs Pi's own code mode | Pi 1.1 | T1–T8 | 3 | ×0.56 [0.45–0.67] | 24/24 / 24/24 (Pi code mode, plan §3.4) |
| 10-10 | optional `code_mode` (Node) | Claude Sonnet | U/E | 5 | ×0.99 [0.92–1.10] | 28/30 / 28/30 |
| 10-10 | direct + `code_mode` (Node) | Codex | U/E | 5 | ×0.78 [0.68–0.82] | 22/30 / 24/30 |
| 10-10 | optional `code_mode` (Node) | Claude Opus | T1–T8 / U/E | 3 | ×0.96 [0.71–0.99] / ×1.00 [0.94–1.10] | 24/24, 18/18 |
| 10-10 | direct + `code_mode` (Node) | Codex high | T1–T8 / U/E | 3 | ×0.75 [0.61–1.11] / ×0.73 [0.66–0.85] | 24/24, 16/18 vs 17/18 |
| 10-10 | 6-turn sessions (Node) | Claude Sonnet, `--resume` | S1–S3 | 2 | ×0.70 [0.62–0.79] | 32/36 / 36/36 |
| 10-10 | 6-turn sessions (Node) | Codex | S1–S3 | 2 | ×0.84 [0.70–1.00]¹ | 36/36 / 36/36 |
| 10-11 | **gate:** direct + `code_mode` (QuickJS) | Claude Sonnet | T1–T8 / all 14 | 5 | ×0.78 [0.64–0.87] / ×0.87 [0.78–0.94] | 68/70 / 66/70 |
| 10-11 | **gate:** direct + `code_mode` (QuickJS) | Codex | T1–T8 / all 14 | 5 | ×0.55 [0.50–0.71] / ×0.63 [0.58–0.74] | 67/70 / 68/70 |
| 10-11 | **gate:** F1 15% errors (QuickJS) | Claude / Codex | T1–T8 subset | 3 | ×0.82 [0.71–0.88] / ×0.55 [0.47–0.69] | 18/18 vs 18/18; 18/18 vs 17/18 |
| 10-11 | **gate:** 6-turn sessions (QuickJS) | Claude Sonnet, stream-json | S1–S3 | 2 | ×0.66 [0.56–0.79] | 36/36 / 34/36 |
| 10-11 | **gate:** 6-turn sessions (QuickJS) | Codex | S1–S3 | 2 | ×0.79 [0.62–0.93]¹ | 36/36 / 36/36 |
| 10-12 | 6-turn sessions (QuickJS) | Claude Sonnet, `--resume` per turn | S1–S3 | 2 | ×0.71 [0.54–0.93] | 36/36 / 35/36 |
| 10-12 | 11-turn mixed sessions (QuickJS) | Claude Sonnet, stream-json | SL | 3 | ×1.01 [0.97–1.08] | 33/33 / 33/33 |
| 10-12 | 11-turn mixed sessions (QuickJS) | Codex, 0.162.0-alpha | SL | 3 | ×0.85 [0.77–0.90] | 31/33 / 32/33 |

¹ Corrected on 2026-10-12. `codex exec resume` reports each turn's usage as the cumulative thread total (checked against the per-request `last_token_usage` in Codex's rollout files, on 0.159 and 0.162). The plan's earlier Codex session figures (×0.84 [0.72–0.97], ×0.82 [0.68–0.98]) summed cumulative values; per-turn usage is now the difference between consecutive turns. Single-task Codex runs were not affected.

## 4. Long sessions

Model providers' own code-mode material publishes single-task or tool-definition savings; the owner's reading of OpenAI's posts and docs found no long-session comparison. These are the lab's long-session numbers.

**Sequences.** S1–S3 are six turns of T-tasks only (lookups, multi-step, fan-out) in three orders. SL is eleven turns of distinct tasks that mix them with the three understanding tasks: T1, T6, U1, T2, T7, U2, T4, T3, U3, T8, T5. No session reached compaction.

| Session | Host and mode | Paired sessions | Session total ratio [95% CI] | Context at end of last turn (code mode / baseline) | Turns using `code_mode` | Correct turns (code mode / baseline) |
|---|---|---:|---|---|---:|---:|
| 6-turn T-only, Node executor (10-10) | Claude, `--resume` | 6 | ×0.70 [0.62–0.79] | 55k / 71k | 11/36 | 32/36 / 36/36 |
| 6-turn T-only, Node executor (10-10) | Codex, `exec resume` | 6 | ×0.84 [0.70–1.00] | 33k / 36k | 19/36 | 36/36 / 36/36 |
| 6-turn T-only, QuickJS (10-11) | Claude, stream-json | 6 | ×0.66 [0.56–0.79] | 60k / 80k | 16/36 | 36/36 / 34/36 |
| 6-turn T-only, QuickJS (10-11) | Codex, `exec resume` | 6 | ×0.79 [0.62–0.93] | 29k / 37k | 22/36 | 36/36 / 36/36 |
| 6-turn T-only, QuickJS (10-12) | Claude, `--resume` | 6 | ×0.71 [0.54–0.93] | 67k / 78k | 12/36 | 36/36 / 35/36 |
| 11-turn mixed, QuickJS (10-12) | Claude, stream-json | 3 | ×1.01 [0.97–1.08] | 144k / 143k | 4/33 | 33/33 / 33/33 |
| 11-turn mixed, QuickJS (10-12) | Codex, `exec resume` | 3 | ×0.85 [0.77–0.90] | 54k / 65k | 21/33 | 31/33 / 32/33 |

Findings:
- **Codex keeps its saving over long sessions.** ×0.79–0.85 at 6 and 11 turns, with the interval below 1 in each run at QuickJS. The context it carries forward is smaller (QuickJS runs: 22% at 6 turns, 17% at 11 turns, 54k versus 65k tokens; Node prototype: 6%), because scripts return only what the answer needs instead of leaving raw results in the history. Codex used `code_mode` in about two thirds of turns.
- **Claude's long-session saving depends on the task mix.** On fan-out-heavy 6-turn sessions it saves 29–34% (stream-json and `--resume` agree: ×0.66 and ×0.71) and carries 14–25% less context. On the 11-turn mixed session it is cost-neutral (×1.01, within the +10% gate bound). Splitting that session by turn type: understanding turns are 51% of the baseline's session cost and run ×1.07 with code mode; lookup and fan-out turns run ×0.94; the two fan-out tasks run ×0.83 (single-task runs: about ×0.5). Two effects shrink the saving in a session: the baseline gets cheaper too, because earlier turns already listed or read the files (T7 baseline 48–58k in-session versus 88k alone); and Claude chose `code_mode` less (4 of 33 turns: T7 and T4 in two of three sessions each, never T8, which it answered with one search). Context at the end was the same (about 144k), since few scripts ran.
- **No length penalty appeared.** Per-turn ratios scatter (single turns from ×0.56 to ×1.82) but show no upward drift with turn number on either host (§5); Claude's last 11-turn turn at ×1.34 is one single-lookup turn (46k versus 34k). Correctness held: Claude 33/33 in both arms; Codex lost U3 twice with code mode and once without, each time on one of U3's 27 checks.
- **Resume works through the owner's rotator shim** (fixed 2026-10-12) when the CLI streams JSON (`--output-format stream-json`): turn 2 read about 43k tokens from cache in a smoke test, and all 72 resume turns ran without error. The shim manages sessions by output format: a fresh `-p --output-format stream-json` launch is tracked (account rotation, affinity, explicit-ID resume); a fresh `-p --output-format json` launch intentionally passes through untracked, so its session ID is unknown to the shim and resuming it fails; `--output-format json` with `--resume <managed-id>` works on the bound account, without stream observation or continuation failover (verified 2026-10-12 on a stream-json session). Lab and Agent Mode sessions start in stream-json, so they are tracked.
- Per-turn tables, cumulative cost and context per turn are in §5.

## 5. Full tables

Generated by `ledger.py` from the surviving rows; section numbers in the titles refer to the plan's §3. Per experiment: an arm summary (medians per run), the per-kind ratios, and per-task medians; sessions show per-turn and cumulative cost.

### §3.6 Codex: RepoPrompt tools direct (namespace key) ± `code_mode`, real RP launch config, 5 reps

Source: `results_dons_w.jsonl` (152 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cx_text_rp` | 56 | 56/56 | 16,761 | 7,493 / 0 / 56,320 / 244 | 3 | 2 | 12.6 | 0/56 |
| `cx_dons` | 40 | 40/40 | 15,186 | 8,417 / 0 / 55,936 / 202 | 3 | 2 | 12.2 | 0/40 |
| `cx_dons_rpcm` | 40 | 40/40 | 13,618 | 4,159 / 0 / 36,992 / 190 | 2 | 1 | 12.5 | 19/40 |
| `cx_direct_rp` | 16 | 4/16 | 14,149 | 4,594 / 0 / 63,488 / 232 | 5 | 4 | 12.1 | 0/16 |

| Change (arm vs baseline) | single | multi | heavy | All tasks |
|---|---:|---:|---:|---:|
| `cx_dons_rpcm` vs `cx_text_rp` | ×0.76 [0.46–1.26] | ×0.77 [0.59–1.09] | ×0.93 [0.61–1.35] | ×0.80 [0.62–1.02] |
| `cx_dons` vs `cx_text_rp` | ×0.74 [0.45–1.15] | ×1.40 [0.82–1.70] | ×1.81 [0.96–2.61] | ×1.18 [0.84–1.36] |

| Task | Group | `cx_text_rp` | `cx_dons` | `cx_dons_rpcm` | `cx_direct_rp` |
|---|---|---:|---:|---:|---:|
| T1_caps | single | 10,801 (7/7) | 22,232 (5/5) | 22,640 (5/5) | 23,508 (0/2) |
| T2_smallread_wire | multi | 24,598 (7/7) | 21,326 (5/5) | 14,423 (5/5) | 13,042 (1/2) |
| T3_opencode_env | single | 13,216 (7/7) | 5,832 (5/5) | 5,981 (5/5) | 9,929 (1/2) |
| T4_policy_lines | multi | 17,398 (7/7) | 44,418 (5/5) | 16,748 (5/5) | 10,181 (0/2) |
| T5_admission_tests | single | 13,275 (7/7) | 6,024 (5/5) | 6,070 (5/5) | 10,332 (1/2) |
| T6_ref_counts | multi | 11,453 (7/7) | 14,175 (5/5) | 9,441 (5/5) | 19,958 (1/2) |
| T7_top_lines | heavy | 19,700 (7/7) | 100,939 (5/5) | 14,056 (5/5) | 16,911 (0/2) |
| T8_try_await | heavy | 23,465 (7/7) | 15,075 (5/5) | 28,339 (5/5) | 24,326 (0/2) |

Cells: median wtok per run (correct runs / runs).

### §3.6 Codex nesting, gpt-5.5, and Pi 1.1 exposure, 3 reps

Source: `results_prop_w.jsonl` (144 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cx_g55` | 24 | 24/24 | 19,476 | 6,634 / 0 / 80,384 / 476 | 5 | 4 | 21.1 | 0/24 |
| `cx_g55_rpcm` | 24 | 24/24 | 12,338 | 3,991 / 0 / 58,496 / 486 | 2 | 1 | 19.3 | 8/24 |
| `cx_nested` | 24 | 24/24 | 19,382 | 10,722 / 0 / 65,024 / 276 | 3 | 2 | 14.1 | 12/24 |
| `cx_text` | 24 | 24/24 | 18,914 | 8,496 / 0 / 65,344 / 243 | 3 | 2 | 11.9 | 0/24 |
| `pi_direct` | 24 | 24/24 | 5,292 | 3,832 / 0 / 3,840 / 162 | 2 | 3 | 12.2 | 0/24 |
| `pi_rpcm` | 24 | 24/24 | 5,248 | 3,356 / 0 / 4,224 / 168 | 2 | 2 | 12.6 | 12/24 |

| Change (arm vs baseline) | single | multi | heavy | All tasks |
|---|---:|---:|---:|---:|
| `cx_nested` vs `cx_text` | ×1.20 [0.82–1.34] | ×1.06 [0.79–1.62] | ×1.08 [0.78–1.76] | ×1.12 [0.91–1.37] |
| `cx_g55_rpcm` vs `cx_g55` | ×1.00 [0.91–1.14] | ×0.78 [0.55–1.29] | ×0.46 [0.27–1.78] | ×0.75 [0.62–1.13] |
| `pi_rpcm` vs `pi_direct` | ×0.71 [0.65–1.15] | ×1.19 [0.71–1.56] | ×0.80 [0.34–1.00] | ×0.89 [0.69–1.10] |

| Task | Group | `cx_g55` | `cx_g55_rpcm` | `cx_nested` | `cx_text` | `pi_direct` | `pi_rpcm` |
|---|---|---:|---:|---:|---:|---:|---:|
| T1_caps | single | 11,372 (3/3) | 12,073 (3/3) | 9,941 (3/3) | 10,095 (3/3) | 4,430 (3/3) | 2,522 (3/3) |
| T2_smallread_wire | multi | 27,473 (3/3) | 32,111 (3/3) | 28,880 (3/3) | 30,671 (3/3) | 6,701 (3/3) | 5,272 (3/3) |
| T3_opencode_env | single | 10,389 (3/3) | 10,237 (3/3) | 18,992 (3/3) | 18,971 (3/3) | 2,010 (3/3) | 2,030 (3/3) |
| T4_policy_lines | multi | 42,232 (3/3) | 22,009 (3/3) | 19,218 (3/3) | 16,048 (3/3) | 7,878 (3/3) | 10,920 (3/3) |
| T5_admission_tests | single | 10,634 (3/3) | 10,288 (3/3) | 18,990 (3/3) | 10,756 (3/3) | 3,579 (3/3) | 2,247 (3/3) |
| T6_ref_counts | multi | 15,570 (3/3) | 12,289 (3/3) | 21,591 (3/3) | 20,299 (3/3) | 3,907 (3/3) | 6,041 (3/3) |
| T7_top_lines | heavy | 41,017 (3/3) | 12,006 (3/3) | 22,883 (3/3) | 19,869 (3/3) | 11,941 (3/3) | 7,185 (3/3) |
| T8_try_await | heavy | 31,593 (3/3) | 23,151 (3/3) | 25,040 (3/3) | 24,660 (3/3) | 8,895 (3/3) | 9,481 (3/3) |

Cells: median wtok per run (correct runs / runs).

### §3.7 Understand and edit tasks, Node prototype executor, 5 reps

Source: `results_new.jsonl` (120 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cc_cm` | 30 | 28/30 | 57,724 | 9 / 16,337 / 162,593 / 3,960 | 6 | 5 | 53.3 | 0/30 |
| `cc_text` | 30 | 28/30 | 60,036 | 10 / 15,984 / 177,272 / 4,498 | 7 | 6 | 53.6 | 0/30 |
| `cx_dons_rpcm` | 30 | 22/30 | 19,355 | 7,288 / 0 / 99,456 / 638 | 5 | 4 | 25.1 | 27/30 |
| `cx_text_rp` | 30 | 24/30 | 27,040 | 13,195 / 0 / 99,392 / 686 | 5 | 4 | 22.8 | 0/30 |

| Change (arm vs baseline) | understand | edit | All tasks |
|---|---:|---:|---:|
| `cc_cm` vs `cc_text` | ×1.04 [0.90–1.20] | ×0.94 [0.88–1.09] | ×0.99 [0.92–1.10] |
| `cx_dons_rpcm` vs `cx_text_rp` | ×0.81 [0.70–0.87] | ×0.75 [0.62–0.83] | ×0.78 [0.68–0.82] |

| Task | Group | `cc_cm` | `cc_text` | `cx_dons_rpcm` | `cx_text_rp` |
|---|---|---:|---:|---:|---:|
| U1_env_build | understand | 87,295 (5/5) | 84,771 (5/5) | 18,012 (5/5) | 26,696 (5/5) |
| U2_slice_math | understand | 48,089 (5/5) | 49,508 (5/5) | 23,520 (3/5) | 30,950 (4/5) |
| U3_diff_pipeline | understand | 206,359 (5/5) | 183,924 (5/5) | 46,739 (4/5) | 45,615 (3/5) |
| E1_rename_subtract | edit | 36,345 (3/5) | 38,276 (5/5) | 18,492 (4/5) | 24,451 (4/5) |
| E2_env_source_case | edit | 45,475 (5/5) | 45,931 (5/5) | 18,947 (5/5) | 22,866 (5/5) |
| E3_label_cap | edit | 56,269 (5/5) | 63,155 (3/5) | 17,312 (1/5) | 26,162 (3/5) |

Cells: median wtok per run (correct runs / runs).

### §3.7 Claude Opus and Codex high effort, T1–T8, 3 reps

Source: `results_var.jsonl` (96 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cc_cm_opus` | 24 | 24/24 | 19,598 | 6 / 6,752 / 82,768 / 750 | 3 | 2 | 18.4 | 12/24 |
| `cc_text_opus` | 24 | 24/24 | 26,066 | 6 / 6,986 / 81,655 / 844 | 4 | 2 | 10.9 | 0/24 |
| `cx_dons_rpcm_hi` | 24 | 24/24 | 15,145 | 7,064 / 0 / 47,360 / 240 | 2 | 2 | 13.1 | 12/24 |
| `cx_text_rp_hi` | 24 | 24/24 | 20,194 | 9,242 / 0 / 64,640 / 351 | 4 | 3 | 13.6 | 0/24 |

| Change (arm vs baseline) | single | multi | heavy | All tasks |
|---|---:|---:|---:|---:|
| `cc_cm_opus` vs `cc_text_opus` | ×1.07 [0.52–1.12] | ×1.06 [0.80–1.08] | ×0.71 [0.61–0.81] | ×0.96 [0.71–0.99] |
| `cx_dons_rpcm_hi` vs `cx_text_rp_hi` | ×0.77 [0.44–1.40] | ×0.67 [0.50–1.28] | ×0.84 [0.67–1.47] | ×0.75 [0.61–1.11] |

| Task | Group | `cc_cm_opus` | `cc_text_opus` | `cx_dons_rpcm_hi` | `cx_text_rp_hi` |
|---|---|---:|---:|---:|---:|
| T1_caps | single | 13,982 (3/3) | 14,768 (3/3) | 6,513 (3/3) | 14,449 (3/3) |
| T2_smallread_wire | multi | 54,560 (3/3) | 41,579 (3/3) | 26,610 (3/3) | 26,399 (3/3) |
| T3_opencode_env | single | 18,437 (3/3) | 14,300 (3/3) | 22,316 (3/3) | 13,256 (3/3) |
| T4_policy_lines | multi | 21,472 (3/3) | 24,421 (3/3) | 12,712 (3/3) | 18,077 (3/3) |
| T5_admission_tests | single | 18,138 (3/3) | 18,082 (3/3) | 6,384 (3/3) | 10,580 (3/3) |
| T6_ref_counts | multi | 17,542 (3/3) | 17,036 (3/3) | 9,626 (3/3) | 22,240 (3/3) |
| T7_top_lines | heavy | 27,787 (3/3) | 46,057 (3/3) | 13,583 (3/3) | 20,613 (3/3) |
| T8_try_await | heavy | 28,908 (3/3) | 34,370 (3/3) | 27,028 (3/3) | 25,020 (3/3) |

Cells: median wtok per run (correct runs / runs).

### §3.7 Claude Opus and Codex high effort, understand/edit, 3 reps

Source: `results_new_var.jsonl` (72 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cc_cm_opus` | 18 | 18/18 | 37,146 | 8 / 11,527 / 117,402 / 2,040 | 5 | 4 | 27.4 | 13/18 |
| `cc_text_opus` | 18 | 18/18 | 37,178 | 8 / 11,384 / 117,327 / 2,236 | 6 | 4 | 27.0 | 0/18 |
| `cx_dons_rpcm_hi` | 18 | 16/18 | 22,756 | 8,382 / 0 / 100,288 / 1,020 | 5 | 4 | 28.2 | 18/18 |
| `cx_text_rp_hi` | 18 | 17/18 | 33,248 | 14,628 / 0 / 133,632 / 1,270 | 6 | 5 | 31.6 | 0/18 |

| Change (arm vs baseline) | understand | edit | All tasks |
|---|---:|---:|---:|
| `cc_cm_opus` vs `cc_text_opus` | ×0.97 [0.93–1.00] | ×1.03 [0.91–1.23] | ×1.00 [0.94–1.10] |
| `cx_dons_rpcm_hi` vs `cx_text_rp_hi` | ×0.74 [0.68–0.88] | ×0.72 [0.60–0.91] | ×0.73 [0.66–0.85] |

| Task | Group | `cc_cm_opus` | `cc_text_opus` | `cx_dons_rpcm_hi` | `cx_text_rp_hi` |
|---|---|---:|---:|---:|---:|
| U1_env_build | understand | 35,514 (3/3) | 35,200 (3/3) | 20,293 (3/3) | 27,094 (3/3) |
| U2_slice_math | understand | 36,695 (3/3) | 37,669 (3/3) | 22,651 (2/3) | 31,818 (3/3) |
| U3_diff_pipeline | understand | 70,003 (3/3) | 74,405 (3/3) | 35,682 (2/3) | 47,400 (3/3) |
| E1_rename_subtract | edit | 40,222 (3/3) | 41,752 (3/3) | 22,250 (3/3) | 36,799 (2/3) |
| E2_env_source_case | edit | 41,166 (3/3) | 36,878 (3/3) | 22,862 (3/3) | 34,450 (3/3) |
| E3_label_cap | edit | 27,374 (3/3) | 26,726 (3/3) | 29,689 (3/3) | 32,550 (3/3) |

Cells: median wtok per run (correct runs / runs).

### §3.7 Injected faults, Node prototype: F1 15% transient errors, F2 20% of calls slowed 10 s, 3 reps

Source: `results_fault.jsonl` (144 rows).

These rows hold only raw input/output totals; the per-run logs needed for price weighting were lost, so the weighted ratios survive only in the plan. Correctness and raw totals:

| Arm | Runs | Correct | Median raw input tokens | Median output tokens | Median wall s |
|---|---:|---:|---:|---:|---:|
| `cc_cm_f1` | 18 | 15/18 | 167,368 | 1,274 | 25.1 |
| `cc_cm_f2` | 18 | 15/18 | 183,784 | 1,052 | 33.6 |
| `cc_text_f1` | 18 | 18/18 | 181,012 | 1,342 | 24.8 |
| `cc_text_f2` | 18 | 18/18 | 125,168 | 1,117 | 26.9 |
| `cx_dons_rpcm_f1` | 18 | 17/18 | 93,275 | 284 | 18.1 |
| `cx_dons_rpcm_f2` | 18 | 17/18 | 61,047 | 203 | 20.4 |
| `cx_text_rp_f1` | 18 | 18/18 | 98,176 | 329 | 17.2 |
| `cx_text_rp_f2` | 18 | 18/18 | 88,624 | 306 | 22.5 |

### §3.7 Six-turn sessions, Node prototype, resumed CLI sessions (Claude and Codex)

Source: `results_sess.jsonl` (144 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cc_cm` | 6 | 36 | 32/36 | 147,476 | 115 | 11/36 |
| `cc_text` | 6 | 36 | 36/36 | 207,396 | 134 | 0/36 |
| `cx_dons_rpcm` | 6 | 36 | 36/36 | 62,974 | 105 | 19/36 |
| `cx_text_rp` | 6 | 36 | 36/36 | 77,168 | 78 | 0/36 |

**`cc_cm` vs `cc_text`: session total ×0.70 [0.62–0.79] over 6 paired sessions of 6 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 33,957 | 60,776 | ×0.56 | 33,957 | 60,776 | ×0.56 | 164,843 / 152,654 | 38,332 / 40,156 | 4/6 / 6/6 |
| 2 | 15,732 | 15,621 | ×1.01 | 48,002 | 84,548 | ×0.57 | 78,644 / 93,854 | 40,337 / 47,312 | 6/6 / 6/6 |
| 3 | 13,864 | 15,946 | ×0.87 | 66,808 | 107,300 | ×0.62 | 81,926 / 122,404 | 41,896 / 58,804 | 6/6 / 6/6 |
| 4 | 36,360 | 44,273 | ×0.82 | 94,190 | 137,578 | ×0.68 | 175,626 / 155,582 | 47,403 / 63,641 | 6/6 / 6/6 |
| 5 | 21,718 | 27,524 | ×0.79 | 117,146 | 161,710 | ×0.72 | 138,249 / 177,440 | 50,384 / 67,474 | 6/6 / 6/6 |
| 6 | 24,982 | 36,958 | ×0.68 | 147,476 | 207,396 | ×0.71 | 139,998 / 186,232 | 55,204 / 70,857 | 4/6 / 6/6 |

**`cx_dons_rpcm` vs `cx_text_rp`: session total ×0.84 [0.70–1.00] over 6 paired sessions of 6 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 12,925 | 18,520 | ×0.70 | 12,925 | 18,520 | ×0.70 | 70,956 / 84,640 | 20,746 / 23,661 | 6/6 / 6/6 |
| 2 | 9,519 | 6,971 | ×1.37 | 20,872 | 25,102 | ×0.83 | 46,684 / 49,807 | 22,701 / 24,817 | 6/6 / 6/6 |
| 3 | 9,246 | 10,764 | ×0.86 | 30,530 | 36,892 | ×0.83 | 58,346 / 57,950 | 24,380 / 26,464 | 6/6 / 6/6 |
| 4 | 14,809 | 14,575 | ×1.02 | 44,283 | 53,498 | ×0.83 | 75,525 / 81,274 | 28,156 / 33,159 | 6/6 / 6/6 |
| 5 | 9,894 | 9,404 | ×1.05 | 51,609 | 62,595 | ×0.82 | 65,446 / 70,842 | 28,902 / 34,316 | 6/6 / 6/6 |
| 6 | 12,228 | 14,542 | ×0.84 | 62,974 | 77,168 | ×0.82 | 64,976 / 108,154 | 33,478 / 35,698 | 6/6 / 6/6 |

### §3.8 Phase 3 gate, QuickJS-ng executor, T1–T8 + understand/edit, 5 reps

Source: `results_p3_w.jsonl` (280 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cc_cm2` | 70 | 68/70 | 43,143 | 8 / 12,824 / 136,318 / 1,488 | 5 | 4 | 25.3 | 14/70 |
| `cc_text` | 70 | 66/70 | 48,429 | 8 / 14,758 / 141,970 / 1,896 | 6 | 5 | 27.1 | 0/70 |
| `cx_dons_rpcm2` | 70 | 67/70 | 15,174 | 4,387 / 0 / 58,560 / 436 | 3 | 2 | 15.1 | 48/70 |
| `cx_text_rp` | 70 | 68/70 | 22,870 | 9,594 / 0 / 79,296 / 455 | 4 | 3 | 15.8 | 0/70 |

| Change (arm vs baseline) | single | multi | heavy | understand | edit | T1–T8 | All tasks |
|---|---:|---:|---:|---:|---:|---:|---:|
| `cc_cm2` vs `cc_text` | ×1.01 [1.00–1.09] | ×0.74 [0.72–0.90] | ×0.58 [0.24–0.75] | ×0.94 [0.83–1.17] | ×1.05 [0.87–1.20] | ×0.78 [0.64–0.87] | ×0.87 [0.78–0.94] |
| `cx_dons_rpcm2` vs `cx_text_rp` | ×0.45 [0.41–0.76] | ×0.66 [0.54–1.00] | ×0.55 [0.39–0.86] | ×0.79 [0.69–1.00] | ×0.73 [0.59–0.88] | ×0.55 [0.50–0.71] | ×0.63 [0.58–0.74] |

| Task | Group | `cc_cm2` | `cc_text` | `cx_dons_rpcm2` | `cx_text_rp` |
|---|---|---:|---:|---:|---:|
| T1_caps | single | 19,123 (5/5) | 19,043 (5/5) | 6,386 (5/5) | 13,773 (5/5) |
| T2_smallread_wire | multi | 35,105 (5/5) | 42,076 (5/5) | 14,475 (5/5) | 23,724 (5/5) |
| T3_opencode_env | single | 18,548 (5/5) | 18,360 (5/5) | 5,850 (5/5) | 13,106 (5/5) |
| T4_policy_lines | multi | 25,195 (5/5) | 52,550 (5/5) | 9,259 (5/5) | 17,171 (5/5) |
| T5_admission_tests | single | 18,892 (5/5) | 18,825 (5/5) | 6,077 (5/5) | 13,429 (5/5) |
| T6_ref_counts | multi | 24,169 (5/5) | 24,093 (5/5) | 10,057 (5/5) | 11,395 (5/5) |
| T7_top_lines | heavy | 33,260 (5/5) | 88,117 (4/5) | 10,848 (5/5) | 19,761 (5/5) |
| T8_try_await | heavy | 47,728 (5/5) | 52,960 (5/5) | 11,080 (5/5) | 20,434 (5/5) |
| U1_env_build | understand | 84,821 (5/5) | 91,303 (5/5) | 18,396 (5/5) | 26,650 (5/5) |
| U2_slice_math | understand | 51,326 (5/5) | 52,408 (5/5) | 21,852 (5/5) | 28,890 (5/5) |
| U3_diff_pipeline | understand | 183,969 (5/5) | 199,744 (5/5) | 40,462 (4/5) | 43,039 (5/5) |
| E1_rename_subtract | edit | 55,220 (5/5) | 51,073 (4/5) | 20,147 (5/5) | 24,817 (5/5) |
| E2_env_source_case | edit | 44,210 (4/5) | 43,421 (4/5) | 15,873 (4/5) | 24,165 (4/5) |
| E3_label_cap | edit | 61,140 (4/5) | 58,099 (4/5) | 18,337 (4/5) | 25,435 (4/5) |

Cells: median wtok per run (correct runs / runs).

### §3.8 Phase 3 gate, injected faults F1, QuickJS-ng executor, 3 reps

Source: `results_p3_fault_w.jsonl` (72 rows).

| Arm | Runs | Correct | Median wtok | Median uncached / cache write / cache read / output | Median model turns | Median tool calls | Median wall s | `code_mode` used |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cc_cm2_f1` | 18 | 18/18 | 34,935 | 8 / 11,410 / 136,872 / 992 | 4 | 4 | 20.9 | 8/18 |
| `cc_text_f1` | 18 | 18/18 | 45,378 | 8 / 18,255 / 148,775 / 1,353 | 6 | 4 | 22.7 | 0/18 |
| `cx_dons_rpcm2_f1` | 18 | 18/18 | 10,446 | 2,664 / 0 / 57,344 / 336 | 3 | 2 | 13.8 | 12/18 |
| `cx_text_rp_f1` | 18 | 17/18 | 22,529 | 10,062 / 0 / 90,240 / 328 | 4 | 4 | 15.4 | 0/18 |

| Change (arm vs baseline) | single | multi | heavy | All tasks |
|---|---:|---:|---:|---:|
| `cc_cm2_f1` vs `cc_text_f1` | ×1.22 [0.82–1.25] | ×0.78 [0.66–0.88] | ×0.73 [0.57–0.84] | ×0.82 [0.71–0.88] |
| `cx_dons_rpcm2_f1` vs `cx_text_rp_f1` | ×0.47 [0.39–0.71] | ×0.62 [0.48–0.90] | ×0.51 [0.39–0.66] | ×0.55 [0.47–0.69] |

| Task | Group | `cc_cm2_f1` | `cc_text_f1` | `cx_dons_rpcm2_f1` | `cx_text_rp_f1` |
|---|---|---:|---:|---:|---:|
| T1_caps | single | 23,638 (3/3) | 19,306 (3/3) | 6,557 (3/3) | 13,923 (3/3) |
| T2_smallread_wire | multi | 43,094 (3/3) | 41,468 (3/3) | 21,587 (3/3) | 27,687 (3/3) |
| T4_policy_lines | multi | 34,426 (3/3) | 66,498 (3/3) | 14,834 (3/3) | 24,302 (3/3) |
| T6_ref_counts | multi | 25,246 (3/3) | 28,662 (3/3) | 7,342 (3/3) | 14,830 (3/3) |
| T7_top_lines | heavy | 43,766 (3/3) | 91,987 (3/3) | 16,969 (3/3) | 27,048 (2/3) |
| T8_try_await | heavy | 52,032 (3/3) | 45,866 (3/3) | 9,740 (3/3) | 23,648 (3/3) |

Cells: median wtok per run (correct runs / runs).

### §3.8 Phase 3 gate, six-turn sessions, Claude (one stream-json process per session)

Source: `results_p3_sess_cc2.jsonl` (72 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cc_cm2` | 6 | 36 | 36/36 | 146,482 | 74 | 16/36 |
| `cc_text` | 6 | 36 | 34/36 | 216,366 | 112 | 0/36 |

**`cc_cm2` vs `cc_text`: session total ×0.66 [0.56–0.79] over 6 paired sessions of 6 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 28,530 | 45,558 | ×0.63 | 28,530 | 45,558 | ×0.63 | 110,664 / 192,789 | 38,196 / 40,710 | 6/6 / 6/6 |
| 2 | 15,536 | 15,634 | ×0.99 | 38,906 | 81,604 | ×0.48 | 78,839 / 114,794 | 40,588 / 57,776 | 6/6 / 6/6 |
| 3 | 35,844 | 22,811 | ×1.57 | 70,662 | 89,136 | ×0.79 | 159,200 / 125,750 | 52,059 / 61,714 | 6/6 / 5/6 |
| 4 | 24,907 | 44,094 | ×0.56 | 98,225 | 140,037 | ×0.70 | 150,482 / 148,388 | 55,826 / 71,392 | 6/6 / 6/6 |
| 5 | 22,118 | 27,983 | ×0.79 | 119,157 | 164,561 | ×0.72 | 168,074 / 193,726 | 57,486 / 74,688 | 6/6 / 6/6 |
| 6 | 23,746 | 40,179 | ×0.59 | 146,482 | 216,366 | ×0.68 | 176,881 / 200,541 | 60,344 / 80,037 | 6/6 / 5/6 |

### §3.8 Phase 3 gate, six-turn sessions, Codex (`codex exec resume`)

Source: `results_p3_sess.jsonl` (144 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cx_dons_rpcm2` | 6 | 36 | 36/36 | 66,666 | 63 | 22/36 |
| `cx_text_rp` | 6 | 36 | 36/36 | 79,519 | 69 | 0/36 |

**`cx_dons_rpcm2` vs `cx_text_rp`: session total ×0.79 [0.62–0.93] over 6 paired sessions of 6 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 14,346 | 19,261 | ×0.74 | 14,346 | 19,261 | ×0.74 | 59,397 / 94,330 | 20,256 / 23,430 | 6/6 / 6/6 |
| 2 | 6,468 | 7,676 | ×0.84 | 23,606 | 25,734 | ×0.92 | 41,906 / 50,080 | 21,236 / 25,269 | 6/6 / 6/6 |
| 3 | 12,203 | 13,346 | ×0.91 | 32,412 | 39,080 | ×0.83 | 69,126 / 58,068 | 24,980 / 29,202 | 6/6 / 6/6 |
| 4 | 11,308 | 15,074 | ×0.75 | 46,788 | 54,572 | ×0.86 | 70,960 / 87,614 | 26,021 / 32,714 | 6/6 / 6/6 |
| 5 | 7,584 | 10,641 | ×0.71 | 55,526 | 64,928 | ×0.86 | 58,198 / 71,640 | 26,726 / 33,538 | 6/6 / 6/6 |
| 6 | 10,969 | 14,590 | ×0.75 | 66,666 | 79,519 | ×0.84 | 67,610 / 102,262 | 28,620 / 36,897 | 6/6 / 6/6 |

### §3.9 Claude six-turn sessions in resume mode (`--resume` per turn through the rotator shim), QuickJS-ng executor

Source: `results_p4_ccresume.jsonl` (72 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cc_cm2` | 6 | 36 | 36/36 | 165,908 | 105 | 12/36 |
| `cc_text` | 6 | 36 | 35/36 | 217,374 | 136 | 0/36 |

**`cc_cm2` vs `cc_text`: session total ×0.71 [0.54–0.93] over 6 paired sessions of 6 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 30,444 | 42,742 | ×0.71 | 30,444 | 42,742 | ×0.71 | 130,397 / 167,818 | 39,113 / 38,907 | 6/6 / 5/6 |
| 2 | 15,712 | 19,790 | ×0.79 | 43,951 | 72,540 | ×0.61 | 79,767 / 113,050 | 40,802 / 51,614 | 6/6 / 6/6 |
| 3 | 28,180 | 22,785 | ×1.24 | 67,900 | 94,296 | ×0.72 | 150,735 / 134,822 | 46,048 / 58,063 | 6/6 / 6/6 |
| 4 | 26,730 | 44,125 | ×0.61 | 95,691 | 139,748 | ×0.68 | 173,150 / 195,184 | 52,894 / 66,476 | 6/6 / 6/6 |
| 5 | 17,996 | 27,282 | ×0.66 | 118,676 | 165,576 | ×0.72 | 139,308 / 163,458 | 55,896 / 70,479 | 6/6 / 6/6 |
| 6 | 47,232 | 47,904 | ×0.99 | 165,908 | 217,374 | ×0.76 | 209,629 / 195,400 | 66,933 / 77,554 | 6/6 / 6/6 |

### §3.9 Eleven-turn long sessions, Claude (stream-json), QuickJS-ng executor

Source: `results_p4_sl.jsonl` (132 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cc_cm2` | 3 | 33 | 33/33 | 640,650 | 474 | 4/33 |
| `cc_text` | 3 | 33 | 33/33 | 633,700 | 491 | 0/33 |

**`cc_cm2` vs `cc_text`: session total ×1.01 [0.97–1.08] over 3 paired sessions of 11 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 23,604 | 23,329 | ×1.01 | 23,604 | 23,329 | ×1.01 | 109,500 / 71,778 | 37,606 / 36,656 | 3/3 / 3/3 |
| 2 | 15,361 | 15,537 | ×0.99 | 39,118 | 38,905 | ×1.01 | 78,768 / 76,923 | 40,738 / 39,853 | 3/3 / 3/3 |
| 3 | 74,398 | 69,383 | ×1.07 | 124,003 | 108,288 | ×1.15 | 221,900 / 217,475 | 47,614 / 46,729 | 3/3 / 3/3 |
| 4 | 29,108 | 28,729 | ×1.01 | 145,427 | 149,895 | ×0.97 | 169,708 / 165,854 | 57,319 / 56,038 | 3/3 / 3/3 |
| 5 | 44,097 | 49,067 | ×0.90 | 197,290 | 198,646 | ×0.99 | 238,895 / 194,268 | 61,066 / 64,797 | 3/3 / 3/3 |
| 6 | 51,498 | 50,843 | ×1.01 | 248,788 | 252,107 | ×0.99 | 205,758 / 203,619 | 71,016 / 70,303 | 3/3 / 3/3 |
| 7 | 32,062 | 38,576 | ×0.83 | 288,592 | 292,286 | ×0.99 | 230,656 / 226,417 | 78,632 / 77,219 | 3/3 / 3/3 |
| 8 | 18,521 | 18,164 | ×1.02 | 307,113 | 311,701 | ×0.99 | 159,011 / 156,173 | 79,890 / 78,465 | 3/3 / 3/3 |
| 9 | 189,830 | 186,879 | ×1.02 | 496,943 | 502,537 | ×0.99 | 457,232 / 358,522 | 106,610 / 105,090 | 3/3 / 3/3 |
| 10 | 84,068 | 83,000 | ×1.01 | 587,321 | 599,313 | ×0.98 | 270,840 / 288,630 | 140,178 / 139,594 | 3/3 / 3/3 |
| 11 | 46,020 | 34,387 | ×1.34 | 640,650 | 633,700 | ×1.01 | 402,467 / 285,688 | 144,169 / 143,422 | 3/3 / 3/3 |

### §3.9 Eleven-turn long sessions, Codex (`codex exec resume`), QuickJS-ng executor

Source: `results_p4_sl.jsonl` (132 rows).

| Variant | Sessions | Turns | Correct turns | Median session wtok | Median session wall s | Turns using `code_mode` |
|---|---:|---:|---:|---:|---:|---:|
| `cx_dons_rpcm2` | 3 | 33 | 31/33 | 195,874 | 223 | 21/33 |
| `cx_text_rp` | 3 | 33 | 32/33 | 223,892 | 301 | 0/33 |

**`cx_dons_rpcm2` vs `cx_text_rp`: session total ×0.85 [0.77–0.90] over 3 paired sessions of 11 turns.**

| Turn | Median wtok (code mode) | Median wtok (baseline) | Turn ratio | Median cumulative wtok (code mode) | Median cumulative wtok (baseline) | Cumulative ratio | Median input tokens per turn (code mode / baseline) | Median context at end of turn (code mode / baseline) | Correct (code mode / baseline) |
|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 1 | 17,040 | 18,400 | ×0.93 | 17,040 | 18,400 | ×0.93 | 42,099 / 58,246 | 21,469 / 20,520 | 3/3 / 3/3 |
| 2 | 13,004 | 7,153 | ×1.82 | 23,703 | 25,553 | ×0.93 | 44,363 / 43,207 | 22,466 / 22,263 | 3/3 / 3/3 |
| 3 | 17,093 | 23,788 | ×0.72 | 40,796 | 49,341 | ×0.83 | 77,503 / 139,001 | 29,728 / 29,464 | 3/3 / 3/3 |
| 4 | 11,473 | 15,892 | ×0.72 | 49,499 | 64,166 | ×0.77 | 84,501 / 123,035 | 30,915 / 31,392 | 3/3 / 3/3 |
| 5 | 12,250 | 14,467 | ×0.85 | 62,046 | 90,824 | ×0.68 | 94,420 / 101,072 | 31,855 / 32,840 | 3/3 / 3/3 |
| 6 | 27,290 | 25,608 | ×1.07 | 90,838 | 112,774 | ×0.81 | 196,469 / 174,902 | 36,040 / 37,436 | 3/3 / 3/3 |
| 7 | 9,880 | 14,610 | ×0.68 | 100,718 | 127,668 | ×0.79 | 74,940 / 114,306 | 36,939 / 38,400 | 3/3 / 3/3 |
| 8 | 8,921 | 9,555 | ×0.93 | 109,752 | 140,099 | ×0.78 | 74,716 / 77,658 | 37,556 / 39,037 | 3/3 / 3/3 |
| 9 | 44,168 | 45,406 | ×0.97 | 168,891 | 187,920 | ×0.90 | 249,107 / 246,925 | 52,132 / 57,160 | 1/3 / 2/3 |
| 10 | 14,005 | 19,915 | ×0.70 | 182,896 | 209,013 | ×0.88 | 113,505 / 122,234 | 53,078 / 64,440 | 3/3 / 3/3 |
| 11 | 12,176 | 14,636 | ×0.83 | 195,874 | 223,892 | ×0.87 | 107,052 / 129,777 | 53,812 / 65,175 | 3/3 / 3/3 |


## 6. Non-token measurements

### 6.1 Read-slot contention (2026-10-10, live app, `read_file` small-read lane: 2 per connection, 2 per window)

32 reads of one script, by calls in flight: 1 → 1,800 ms (speedup 1.00), 2 → 1,400 ms (1.29), 4 → 1,331 ms (1.35), 8 → 1,563 ms (1.15); 8 spread over 2 connections 1,428 ms, over 4 connections 1,349 ms. The 2-per-window cap is the ceiling.

Foreground `read_file` latency while K background scripts fan out 32 reads each:

| K scripts | Where | Foreground p50 / p95 / max ms | Background 32-read fan-out ms |
|---:|---|---|---:|
| 0 | — | 52 / 55 / 131 | — |
| 1 | same connection | 177 / 267 / 292 | 1,420 |
| 2 | same connection | 310 / 519 / 715 | 2,569 |
| 4 | same connection | 664 / 1,251 / 1,581 | 5,389 |
| 1 | separate connections | 113 / 217 / 318 | 1,845 |
| 2 | separate connections | 169 / 248 / 346 | 2,862 |
| 4 | separate connections | 399 / 526 / 545 | 5,450 |

Admission was FIFO with no starvation and no errors.

### 6.2 Failure behaviour (2026-10-10, Node prototype, before the §6 executor rules)

Under F1 (15% transient errors): Claude scripts hit a failed nested call in 13 of 20 scripts and 11 still reported success; Codex 10 of 23 and 7 reported success. Codex's native code mode re-issued all 17 failed scripts. Under F2 (20% of calls slowed 10 s) three Claude scripts hit the 60 s timeout and lost all finished work. Correctness: `cc_cm` lost T8 under F1 and T7 under F2 (5/6 tasks each); `cx_dons_rpcm` kept every task. Price-weighted ratios (from the lost per-run logs): Claude F1 ×0.80 [0.62–1.05], F2 ×0.69 [0.64–0.92]; Codex F1 ×0.73 [0.60–0.84], F2 ×0.68 [0.62–0.82]. With the QuickJS executor rules (one retry, failures reject, failure footer, partial output) the F1 re-run lost nothing (§3, 2026-10-11): 36 nested calls retried, 6 surfaced as failures, 0 timeouts.

### 6.3 QuickJS-ng 0.17.0 executor (2026-10-10, C host without libc)

- **Parity with Node on 167 harvested lab scripts:** 159 identical; 3 differ only in key order from completion-order writes; 3 match one of two nondeterministic Node runs; 2 failed on Node because of a prototype bug (lost results over about 64 KiB) and succeeded on QuickJS. Nested call counts equal for 167/167. No engine-caused difference.
- **API differences (74-expression probe):** no `Intl` (locale formatting, `localeCompare` is code-unit order) and different error wording (9 cases); QuickJS is correct where the Node `vm` realm was not.
- **Containment (286 adversarial runs):** CPU spins, async spins and catastrophic regexes stop at 2 s guest CPU (uncatchable, fires inside the regex engine); never-settling promises detected in about 5 ms; heap held at the 64 MiB limit (Node prototype: 2–4 GiB RSS); recursion stops at depth 1,022 (1 MiB stack); 10,000 concurrent calls → at most 4 reach the bridge and call 33 fails; no calls after the wall deadline; patching `tools`, `JSON`, `Array.prototype.join` or `Promise` cannot affect arguments, protocol or output; `std`, `os`, `require`, `process`, timers and module imports are absent; output stops at 32 KiB. The Node prototype failed most of these, including a full host escape via `tools.read_file.constructor`. `Object.prototype.toJSON` can rewrite arguments inside the guest, so the app's path policy stays the boundary. Hot loops run roughly 20–50× slower than V8.

### 6.4 Codex namespace key and prompt overhead (2026-10-11, app-server path through the owner's shim)

- `features.code_mode.direct_only_tool_namespaces=["mcp__<server>"]` in the thread config made RepoPrompt calls direct in 4/4 runs (computer use on and off); without it they ran inside `exec` in 4/4. No tool-search calls either way. The namespace is `mcp__` + the server name with `-` → `_`, case-sensitive; a wrong name is silently ignored.
- Making the full `RepoPromptCE` catalog direct raised the per-request prompt from 16.8k to 31.7k tokens (about +15k per request); the lab's five tools add about 1.5k. Hence the plan's second, read-only server entry for Codex.

### 6.5 Real usage (plan §3.1 and §3.5)

Claude Code, 2026-04-03 to 2026-10-10, 1,152 user turns with direct exploration calls: turns with 20+ exploration calls are 20.9% of turns and 61.2% of exploration output; 10–19 calls 18.1% / 21.6%; 5–9 calls 20.8% / 11.0%; 2–4 calls 26.0% / 5.1%; 1 call 14.1% / 1.1%. Re-reads of an already-read path: 42–50% of reads.

## 7. Caveats

- 14 tasks on one repository; heavy tasks count and rank, while real 20+ call turns mostly read for understanding, so real savings should be smaller than the heavy-task figures.
- One model per host and effort level unless marked; ratios compare within a host only.
- The executor ran in a proxy in front of `repoprompt_ce_cli_debug`, not inside the app; Phase 6 of the plan re-measures with the in-app executor.
- Wall time is noisy: runs share one RepoPrompt window and the machine was often loaded. Tokens and turns are unaffected.
- No session reached compaction; the longest sessions here are 11 turns.
- Task paths and expected answers match the tree before the app-module split (valid up to main `d1e4ce69`). On today's tree, T3 (OpenCode moved into `RepoPromptAgentCore`), T4 (more files in the MCP policies folder), T7 (line count changed) and U1–U3 and E1–E3 (moved paths) no longer match; T1, T2, T5, T6 and T8 still do. The numbers above stay valid for the tree they ran on; the next run pins a corpus SHA and re-derives the truths (plan §7).
