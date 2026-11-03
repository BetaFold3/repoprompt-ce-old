#!/usr/bin/env python3
"""Verify an optimized Dev lane's Swift compile flags from SwiftPM's build plan.

Contract: docs/context/workflows/development.md#optimized-diagnostics-lane-opt-in and
#optimized-incremental-app-lane-opt-in. Read-only, Python 3 standard library only.

Usage: verify_build_lane_flags.py --build-yaml <scratch>/release.yaml [--lane optimized-diagnostics|optimized-incremental]

The default lane, optimized-diagnostics, keeps its original contract: every first-party
compile is -O with an effective whole-module optimization. The optimized-incremental lane
additionally requires the RPCE_OPTIMIZED_INCREMENTAL label on every first-party compile and
proves that only RepoPromptApp is effectively non-WMO: SwiftPM's release
-whole-module-optimization must be present and overridden by a later
-no-whole-module-optimization (the driver honors the last of the pair), with -incremental and
an effective -enable-batch-mode. Every other module must be effectively WMO and carry none of
those App-only flags.

The input is SwiftPM's llbuild manifest. This parser reads only the dialect
SwiftPM writes: a column-0 ``commands:`` section whose blocks are
``  "<key>":`` lines followed by ``    <field>: <value>`` lines, where ``inputs``
and ``args`` are single-line JSON flow arrays. Anything else in that section is
malformed and fails closed. It is not a general YAML parser.

A Swift compile command is a ``shell`` command that runs ``swiftc`` with
``-module-name``, ``-c`` and Swift source inputs (``.swift`` entries in
``inputs`` or the ``@<...>/sources`` response file). Link commands (``swiftc``
with ``-module-name`` and the ``@<...>/Objects.LinkFileList`` response file, no
``-c`` and no sources) are ignored. Every other ``swiftc`` command with ``-module-name``
fails closed. Each compile command is checked on its own; modules are grouped
only for the presence check and the report.

Exit status: 0 when every rule holds, 1 on any violation or malformed input,
2 on command-line usage errors (argparse). Callers must treat any non-zero
status as failure.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field

LANE_MARKER = "RPCE_OPTIMIZED_DIAGNOSTICS"
INCREMENTAL_MARKER = "RPCE_OPTIMIZED_INCREMENTAL"
DEBUG_DEFINE = "DEBUG"
LANE_OPTIMIZED = "optimized-diagnostics"
LANE_INCREMENTAL = "optimized-incremental"
LANES = (LANE_OPTIMIZED, LANE_INCREMENTAL)
# The only module the optimized-incremental lane compiles non-WMO (a FIRST_PARTY_MODULES member, so a
# plan without it already fails the first-party presence check).
INCREMENTAL_APP_MODULES = frozenset({"RepoPromptApp"})

FIRST_PARTY_MODULES = frozenset(
    {
        "RepoPrompt",
        "RepoPromptApp",
        "RepoPromptAgentCore",
        "RepoPromptPlatform",
        "RepoPromptUI",
        "RepoPromptWorkspace",
        "RepoPromptRemoteWire",
        "RepoPromptMCP",
        "RepoPromptGateway",
        "RepoPromptShared",
        "RepoPromptMCPClientKit",
        "RepoPromptMCPCore",
        "RepoPromptClaudeCompatibleProvider",
    }
)
FIRST_PARTY_PREFIX = "RepoPrompt"
TEST_MODULE_SUFFIX = "Tests"

# Options whose next argv token belongs to another tool and never defines a Swift condition.
FOREIGN_VALUE_OPTIONS = frozenset({"-Xcc", "-Xlinker", "-Xclang-linker"})
WMO_FLAGS = frozenset({"-whole-module-optimization", "-wmo"})
NO_WMO_FLAGS = frozenset({"-no-whole-module-optimization", "-no-wmo"})
INCREMENTAL_FLAG = "-incremental"
ENABLE_BATCH_FLAG = "-enable-batch-mode"
DISABLE_BATCH_FLAG = "-disable-batch-mode"
OPTIMIZATION_FLAG = re.compile(r"^-O[A-Za-z]*$")
SOURCES_RESPONSE_BASENAME = "sources"
LINK_RESPONSE_BASENAME = "Objects.LinkFileList"

BLOCK_KEY_LINE = re.compile(r'^  (".*"):$')
FIELD_LINE = re.compile(r"^    ([A-Za-z0-9_-]+): (.*)$")


class MalformedPlan(Exception):
    """The build plan is not in the expected SwiftPM llbuild dialect."""


@dataclass(frozen=True)
class CompileCommand:
    key: str
    module: str
    defines: frozenset[str]
    optimization_flags: tuple[str, ...]
    whole_module: bool
    no_whole_module: bool
    enable_testing: bool
    # Last-wins driver state, recorded in argv order (all False/None when the flags are absent).
    effective_whole_module: bool | None = None
    incremental: bool = False
    effective_batch_mode: bool | None = None


@dataclass
class PlanSummary:
    compiles: list[CompileCommand] = field(default_factory=list)
    ignored_links: int = 0


def _parse_command_blocks(text: str) -> list[tuple[str, dict[str, str]]]:
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line == "commands:"]
    if len(starts) != 1:
        raise MalformedPlan(f"expected exactly one column-0 'commands:' section, found {len(starts)}")
    blocks: list[tuple[str, dict[str, str]]] = []
    seen_keys: set[str] = set()
    current: dict[str, str] | None = None
    for number, line in enumerate(lines[starts[0] + 1 :], start=starts[0] + 2):
        if not line.strip():
            continue
        if not line.startswith(" "):
            # SwiftPM writes commands: last; anything after it would hide later blocks.
            raise MalformedPlan(f"line {number}: unexpected top-level line after commands section")
        key_match = BLOCK_KEY_LINE.match(line)
        if key_match:
            try:
                key = json.loads(key_match.group(1))
            except json.JSONDecodeError as error:
                raise MalformedPlan(f"line {number}: unreadable command key ({error})") from None
            if not isinstance(key, str) or not key:
                raise MalformedPlan(f"line {number}: command key is not a non-empty string")
            if key in seen_keys:
                raise MalformedPlan(f"line {number}: duplicate command key {key!r}")
            seen_keys.add(key)
            current = {}
            blocks.append((key, current))
            continue
        field_match = FIELD_LINE.match(line)
        if field_match is None:
            raise MalformedPlan(f"line {number}: unexpected line in commands section: {line[:120]!r}")
        if current is None:
            raise MalformedPlan(f"line {number}: field outside a command block")
        name, value = field_match.groups()
        if name in current:
            raise MalformedPlan(f"line {number}: duplicate field {name!r}")
        current[name] = value
    return blocks


def _string_array(key: str, name: str, raw: str | None) -> list[str]:
    if raw is None:
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise MalformedPlan(f"command {key!r}: unreadable {name} ({error})") from None
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise MalformedPlan(f"command {key!r}: {name} is not an array of strings")
    return value


def _scalar(key: str, name: str, raw: str | None) -> str | None:
    if raw is None:
        return None
    if raw.startswith('"'):
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise MalformedPlan(f"command {key!r}: unreadable {name} ({error})") from None
        if not isinstance(value, str):
            raise MalformedPlan(f"command {key!r}: {name} is not a string")
        return value
    return raw


def _swift_tokens(args: list[str]) -> list[str]:
    """argv after the executable, without the values of -Xcc/-Xlinker/-Xclang-linker."""
    tokens: list[str] = []
    index = 1
    while index < len(args):
        if args[index] in FOREIGN_VALUE_OPTIONS:
            index += 2
            continue
        tokens.append(args[index])
        index += 1
    return tokens


def _response_files(tokens: list[str]) -> list[str]:
    return [os.path.basename(token[1:]) for token in tokens if token.startswith("@")]


def _classify_compile(key: str, module: str, tokens: list[str]) -> CompileCommand:
    defines: set[str] = set()
    optimization: list[str] = []
    whole_module = no_whole_module = enable_testing = incremental = False
    effective_whole_module: bool | None = None
    effective_batch_mode: bool | None = None
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "-D":
            if index + 1 >= len(tokens) or not tokens[index + 1]:
                raise MalformedPlan(f"command {key!r}: -D without a value")
            defines.add(tokens[index + 1])
            index += 2
            continue
        if token.startswith("-D") and len(token) > 2:
            defines.add(token[2:])
        elif OPTIMIZATION_FLAG.match(token):
            optimization.append(token)
        elif token in WMO_FLAGS:
            whole_module = True
            effective_whole_module = True
        elif token in NO_WMO_FLAGS:
            no_whole_module = True
            effective_whole_module = False
        elif token == INCREMENTAL_FLAG:
            incremental = True
        elif token == ENABLE_BATCH_FLAG:
            effective_batch_mode = True
        elif token == DISABLE_BATCH_FLAG:
            effective_batch_mode = False
        elif token == "-enable-testing":
            enable_testing = True
        elif token.startswith("@"):
            if os.path.basename(token[1:]) != SOURCES_RESPONSE_BASENAME:
                raise MalformedPlan(
                    f"command {key!r}: argv response file {token!r} may hide flags; only the sources list is allowed"
                )
        index += 1
    return CompileCommand(
        key=key,
        module=module,
        defines=frozenset(defines),
        optimization_flags=tuple(optimization),
        whole_module=whole_module,
        no_whole_module=no_whole_module,
        enable_testing=enable_testing,
        effective_whole_module=effective_whole_module,
        incremental=incremental,
        effective_batch_mode=effective_batch_mode,
    )


def parse_build_plan(text: str) -> PlanSummary:
    summary = PlanSummary()
    for key, fields in _parse_command_blocks(text):
        tool = _scalar(key, "tool", fields.get("tool"))
        if tool is None:
            raise MalformedPlan(f"command {key!r}: missing tool")
        if tool == "swift-compiler":
            raise MalformedPlan(f"command {key!r}: unsupported swift-compiler tool dialect")
        if tool != "shell":
            continue
        args = _string_array(key, "args", fields.get("args"))
        if not args or os.path.basename(args[0]) != "swiftc":
            continue
        inputs = _string_array(key, "inputs", fields.get("inputs"))
        if "-module-name" not in args:
            if any(item.endswith(".swift") for item in inputs):
                raise MalformedPlan(f"command {key!r}: swiftc with Swift sources but no -module-name")
            continue
        tokens = _swift_tokens(args)
        if tokens.count("-module-name") != 1:
            raise MalformedPlan(f"command {key!r}: expected one top-level -module-name")
        position = tokens.index("-module-name")
        if position + 1 >= len(tokens) or not tokens[position + 1] or tokens[position + 1].startswith("-"):
            raise MalformedPlan(f"command {key!r}: -module-name without a value")
        module = tokens[position + 1]
        response_files = _response_files(tokens)
        has_sources = any(item.endswith(".swift") for item in inputs) or SOURCES_RESPONSE_BASENAME in response_files
        has_compile_flag = "-c" in tokens
        is_link = LINK_RESPONSE_BASENAME in response_files
        if has_compile_flag and has_sources and not is_link:
            summary.compiles.append(_classify_compile(key, module, tokens))
        elif is_link and not has_compile_flag and not has_sources:
            summary.ignored_links += 1
        else:
            raise MalformedPlan(
                f"command {key!r}: unclassified swiftc command for module {module!r} "
                f"(-c={has_compile_flag}, sources={has_sources}, link={is_link})"
            )
    if not summary.compiles:
        raise MalformedPlan("no Swift compile commands found")
    return summary


def module_class(module: str) -> str:
    if module in FIRST_PARTY_MODULES:
        return "first-party"
    if module.endswith(TEST_MODULE_SUFFIX):
        return "test"
    if module.startswith(FIRST_PARTY_PREFIX):
        return "unknown"
    return "third-party"


def _whole_module_violations(command: CompileCommand) -> list[str]:
    """A module that must stay WMO: the default lane's original rules plus no App-only flags."""
    problems: list[str] = []
    if not command.whole_module:
        problems.append("missing -whole-module-optimization")
    if command.no_whole_module:
        problems.append("has -no-whole-module-optimization")
    return problems


def _incremental_app_violations(command: CompileCommand) -> list[str]:
    """RepoPromptApp in the optimized-incremental lane: effective non-WMO incremental batch mode."""
    problems: list[str] = []
    if not command.whole_module:
        problems.append("missing SwiftPM's release -whole-module-optimization (the override is unproven)")
    if not command.no_whole_module:
        problems.append("missing -no-whole-module-optimization")
    elif command.effective_whole_module is not False:
        problems.append("-whole-module-optimization follows -no-whole-module-optimization (effective WMO)")
    if not command.incremental:
        problems.append("missing -incremental")
    if command.effective_batch_mode is None:
        problems.append("missing -enable-batch-mode")
    elif not command.effective_batch_mode:
        problems.append("-disable-batch-mode follows -enable-batch-mode (batch mode off)")
    return problems


def _incremental_batch_flag_violations(command: CompileCommand) -> list[str]:
    """The optimized-incremental lane's App-only incremental and batch-mode flags on any other module."""
    problems: list[str] = []
    if command.incremental:
        problems.append(f"has {INCREMENTAL_FLAG} (App-only)")
    if command.effective_batch_mode is not None:
        problems.append("has a batch-mode flag (App-only)")
    return problems


def command_violations(command: CompileCommand, lane: str = LANE_OPTIMIZED) -> list[str]:
    if lane not in LANES:
        raise ValueError(f"unknown lane {lane!r}")
    incremental_lane = lane == LANE_INCREMENTAL
    lane_defines = (DEBUG_DEFINE, LANE_MARKER, INCREMENTAL_MARKER) if incremental_lane else (DEBUG_DEFINE, LANE_MARKER)
    kind = module_class(command.module)
    problems: list[str] = []
    if kind == "first-party":
        for name in lane_defines:
            if name not in command.defines:
                problems.append(f"missing -D{name}")
        if not incremental_lane and INCREMENTAL_MARKER in command.defines:
            problems.append(f"has -D{INCREMENTAL_MARKER} (optimized-incremental lane label)")
        if "-O" not in command.optimization_flags:
            problems.append("missing -O")
        for flag in sorted(set(command.optimization_flags) - {"-O"}):
            problems.append(f"has {flag}")
        if incremental_lane and command.module in INCREMENTAL_APP_MODULES:
            problems.extend(_incremental_app_violations(command))
        else:
            problems.extend(_whole_module_violations(command))
            if incremental_lane:
                problems.extend(_incremental_batch_flag_violations(command))
        if command.enable_testing:
            problems.append("has -enable-testing")
    elif kind in ("test", "third-party"):
        # Rule 4 covers every non-first-party module; tests are exempt only from the
        # first-party requirements and the unknown-module rule.
        for name in (DEBUG_DEFINE, LANE_MARKER, INCREMENTAL_MARKER):
            if name in command.defines:
                problems.append(f"{kind} module has -D{name}")
        if incremental_lane:
            # App-only proof: every other module keeps SwiftPM's release WMO untouched.
            for problem in _whole_module_violations(command) + _incremental_batch_flag_violations(command):
                problems.append(f"{kind} module {problem}")
    else:
        problems.append("unclassified RepoPrompt* module (not in the expected first-party set)")
    return problems


def verify(summary: PlanSummary, lane: str = LANE_OPTIMIZED) -> tuple[list[str], list[str]]:
    """Return (summary lines, failure lines)."""
    by_class: dict[str, dict[str, list[CompileCommand]]] = {
        "first-party": {},
        "third-party": {},
        "test": {},
        "unknown": {},
    }
    failures: list[str] = []
    failed_modules: dict[str, set[str]] = {kind: set() for kind in by_class}
    for command in summary.compiles:
        kind = module_class(command.module)
        by_class[kind].setdefault(command.module, []).append(command)
        for problem in command_violations(command, lane):
            failures.append(f"FAIL {kind} {command.module} [{command.key}]: {problem}")
            failed_modules[kind].add(command.module)
    missing = sorted(FIRST_PARTY_MODULES - set(by_class["first-party"]))
    for module in missing:
        failures.append(f"FAIL first-party {module}: no Swift compile command in the build plan")

    def line(kind: str, label: str, extra: str = "") -> str:
        modules = by_class[kind]
        commands = sum(len(entries) for entries in modules.values())
        bad = len(failed_modules[kind]) + (len(missing) if kind == "first-party" else 0)
        status = "FAIL" if bad else "OK"
        return f"{label}: {len(modules)} modules{extra}, {commands} compile commands, {bad} failing: {status}"

    if lane == LANE_INCREMENTAL:
        lines = [
            f"lane: {LANE_INCREMENTAL}",
            line(
                "first-party",
                "first-party (DEBUG + lane marker + incremental label, -O, no -enable-testing; "
                f"{', '.join(sorted(INCREMENTAL_APP_MODULES))} effective non-WMO incremental batch, rest WMO)",
                f" of {len(FIRST_PARTY_MODULES)} expected",
            ),
            line("third-party", "third-party (no DEBUG, no lane markers, WMO, no App-only flags)"),
            line("test", "test modules (no DEBUG, no lane markers, WMO, no App-only flags)"),
            line("unknown", "unclassified RepoPrompt* modules (must be none)"),
            f"link commands ignored: {summary.ignored_links}",
        ]
        return lines, failures
    lines = [
        line(
            "first-party",
            "first-party (DEBUG + lane marker, -O, WMO, no -enable-testing)",
            f" of {len(FIRST_PARTY_MODULES)} expected",
        ),
        line("third-party", "third-party (no DEBUG, no lane marker)"),
        line("test", "test modules (no DEBUG, no lane marker)"),
        line("unknown", "unclassified RepoPrompt* modules (must be none)"),
        f"link commands ignored: {summary.ignored_links}",
    ]
    return lines, failures


def run(build_yaml: str, stdout=sys.stdout, stderr=sys.stderr, lane: str = LANE_OPTIMIZED) -> int:
    try:
        with open(build_yaml, "rb") as handle:
            raw = handle.read()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        print(f"verify_build_lane_flags: cannot read {build_yaml}: {error}", file=stderr)
        print("result: FAIL (unreadable build plan)", file=stdout)
        return 1
    try:
        summary = parse_build_plan(text)
    except MalformedPlan as error:
        print(f"verify_build_lane_flags: malformed build plan {build_yaml}: {error}", file=stderr)
        print("result: FAIL (malformed build plan)", file=stdout)
        return 1
    lines, failures = verify(summary, lane)
    print(f"verify_build_lane_flags: {build_yaml}", file=stdout)
    for entry in lines:
        print(entry, file=stdout)
    for entry in failures:
        print(entry, file=stderr)
    print(f"result: {'FAIL' if failures else 'PASS'}", file=stdout)
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--build-yaml", required=True, help="SwiftPM llbuild manifest, e.g. <scratch>/release.yaml")
    parser.add_argument("--lane", choices=LANES, default=LANE_OPTIMIZED, help="lane contract to verify")
    options = parser.parse_args(argv)
    return run(options.build_yaml, lane=options.lane)


if __name__ == "__main__":
    sys.exit(main())
