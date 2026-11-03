#!/usr/bin/env python3
"""Regression tests for trusted release-control helpers."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import debug_package_cache  # noqa: E402


class ReleaseToolingTests(unittest.TestCase):
    def test_debug_package_input_key_covers_resources_scripts_and_git_but_not_provenance(self) -> None:
        # Retargeted from the retired fast-package fingerprint: same resource- and script-sensitivity.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            scripts = root / "Scripts"
            build = root / ".build" / "debug"
            resources = root / "AppResources"
            for directory in (scripts, build, resources):
                directory.mkdir(parents=True)
            for name in debug_package_cache.INPUT_SCRIPTS:
                (scripts / name).write_text(f"{name}-v1\n", encoding="utf-8")
            resource = resources / "Configuration.json"
            resource.write_text('{"version":1}\n', encoding="utf-8")
            provenance = Path(tmp) / "dest" / "RepoPrompt.app" / "Contents" / "Resources" / "RepoPromptDebugProvenance.json"
            provenance.parent.mkdir(parents=True)
            provenance.write_text('{"generated":1}\n', encoding="utf-8")
            fields = {name: "x" for name in debug_package_cache.PLAN_FIELDS}
            git = ["main", "a" * 40, False]

            def key() -> str:
                return debug_package_cache.compute_keys(
                    cert="adhoc", root=root, scripts_dir=scripts, build_dir=build, fields=fields,
                    environ={"PATH": "/usr/bin"}, git=tuple(git), os_build="25A1",
                )["input_key"]

            baseline = key()
            provenance.write_text('{"generated":2}\n', encoding="utf-8")
            self.assertEqual(key(), baseline)

            resource.write_text('{"version":2}\n', encoding="utf-8")
            self.assertNotEqual(key(), baseline)
            resource.write_text('{"version":1}\n', encoding="utf-8")
            self.assertEqual(key(), baseline)

            (scripts / "smoke_embedded_mcp_helper.sh").write_text("verify-v2\n", encoding="utf-8")
            self.assertNotEqual(key(), baseline)
            (scripts / "smoke_embedded_mcp_helper.sh").write_text("smoke_embedded_mcp_helper.sh-v1\n", encoding="utf-8")
            self.assertEqual(key(), baseline)

            git[1] = "b" * 40
            self.assertNotEqual(key(), baseline)
            git[1] = "a" * 40
            git[2] = True
            self.assertNotEqual(key(), baseline)

    def test_debug_provenance_uses_json_validation_and_rejects_truncated_output(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        validator = SCRIPT_DIR / "validate_json.py"
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        provenance = temp_dir / "RepoPromptDebugProvenance.json"

        self.assertIn(
            'run python3 "$CONTROL_PLANE_SCRIPTS_DIR/validate_json.py" \\\n        "$APP_BUNDLE/Contents/Resources/RepoPromptDebugProvenance.json"',
            package_script,
        )
        self.assertNotIn(
            'plutil -lint "$APP_BUNDLE/Contents/Resources/RepoPromptDebugProvenance.json"',
            package_script,
        )

        provenance.write_text('{"version": 1}\n', encoding="utf-8")
        valid = subprocess.run(
            [sys.executable, str(validator), str(provenance)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(valid.stdout.strip(), f"Valid JSON: {provenance}")

        provenance.write_text('{"version":', encoding="utf-8")
        truncated = subprocess.run(
            [sys.executable, str(validator), str(provenance)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(truncated.returncode, 1)
        self.assertIn(f"error: invalid JSON file {provenance}:", truncated.stderr)

    def test_runtime_signing_policy_matches_release_metadata_and_entitlement_templates(self) -> None:
        root = SCRIPT_DIR.parent
        metadata = {}
        for line in (root / "version.env").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                metadata[key] = value.strip('"')

        package_manifest = (root / "Package.swift").read_text(encoding="utf-8")
        policy = (
            root / "Sources" / "RepoPromptPlatform" / "Infrastructure" / "Security" / "RuntimeCodeSigningPolicy.swift"
        ).read_text(encoding="utf-8")
        entitlements = (root / "AppBundle" / "RepoPrompt.entitlements.template").read_text(encoding="utf-8")
        info_plist = plistlib.loads((root / "AppBundle" / "Info.plist.template").read_bytes())

        self.assertIn('environment["REPOPROMPT_ENABLE_SENTRY"] == "1"', package_manifest)
        self.assertIn('repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertNotIn("let sentryEnabled = true", package_manifest)

        self.assertIn(
            f'static let developerIDBundleIdentifier = "{metadata["BUNDLE_ID"]}"',
            policy,
        )
        self.assertIn(
            f'static let appleDevelopmentDebugBundleIdentifier = "{metadata["BUNDLE_ID"]}.debug"',
            policy,
        )
        self.assertIn(
            f'static let signingTeamIdentifier = "{metadata["SIGNING_TEAM_ID"]}"',
            policy,
        )
        self.assertIn("1.2.840.113635.100.6.1.13", policy)
        self.assertIn("1.2.840.113635.100.6.1.12", policy)
        self.assertIn("__SIGNING_TEAM_ID__.__BUNDLE_ID__", entitlements)
        self.assertIn("<string>__SIGNING_TEAM_ID__</string>", entitlements)
        self.assertEqual(info_plist["CFBundleIdentifier"], "__BUNDLE_ID__")
        self.assertIn("RepoPromptSigningMode", info_plist)
        self.assertIn("RepoPromptDebugSecureStorageBackend", info_plist)
        self.assertIn("RepoPromptLocalSigningCertificateSHA256", info_plist)
        self.assertIn("RepoPromptLocalSecureStorageGeneration", info_plist)
        self.assertIn("RepoPromptSentryDSN", info_plist)
        self.assertEqual(info_plist["RepoPromptSentryDSN"], "")
        self.assertIn(
            'static let localSelfSignedCertificateName = "RepoPrompt CE Local Self-Signed Code Signing"',
            policy,
        )

    def test_app_declares_apple_events_automation(self) -> None:
        root = SCRIPT_DIR.parent
        info_plist = plistlib.loads((root / "AppBundle" / "Info.plist.template").read_bytes())
        self.assertIn("NSAppleEventsUsageDescription", info_plist)
        # Keep this user-visible privacy explanation deliberate and reviewable when its wording changes.
        self.assertEqual(
            info_plist["NSAppleEventsUsageDescription"],
            "RepoPrompt CE uses automation to let explicitly requested agent workflows inspect and control other applications.",
        )

        for template_name in (
            "RepoPrompt.entitlements.template",
            "RepoPrompt.local-self-signed.entitlements.template",
        ):
            with self.subTest(template_name=template_name):
                entitlements = plistlib.loads((root / "AppBundle" / template_name).read_bytes())
                self.assertIs(entitlements.get("com.apple.security.automation.apple-events"), True)

    def test_info_plist_url_scheme_is_rendered_per_build_channel(self) -> None:
        template = (SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_text(encoding="utf-8")
        self.assertIn("__URL_SCHEME__", template)
        for expected in ("repoprompt-ce", "repoprompt-ce-debug"):
            info_plist = plistlib.loads(template.replace("__URL_SCHEME__", expected).encode("utf-8"))
            registered_schemes = [
                scheme
                for url_type in info_plist.get("CFBundleURLTypes", [])
                for scheme in url_type.get("CFBundleURLSchemes", [])
            ]
            self.assertEqual(registered_schemes, [expected])

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        self.assertIn('URL_SCHEME="repoprompt-ce"', package_script)
        self.assertIn('URL_SCHEME="repoprompt-ce-debug"', package_script)

    def test_local_self_signed_outer_codesign_uses_equals_requirement_argv(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        sign_path_body = package_script.split("sign_path(){", 1)[1].split("\n}\nsign_sparkle_framework(){", 1)[0]
        # Step 6: the signing block ends with the debug bundle-reuse gate's `fi`; the captured body is unchanged.
        app_signing_body = package_script.split("APP_SIGN_ARGS=()", 1)[1].split(
            'fi\nPACKAGE_TIMING_DEEP="ran"\nrun codesign --verify --deep --strict',
            1,
        )[0]
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        capture = temp_dir / "codesign-argv.bin"
        fake_codesign = temp_dir / "codesign"
        fake_codesign.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\0' \"$@\" > \"$CODESIGN_CAPTURE\"\n",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        probe = temp_dir / "codesign-argv-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
run() {{ "$@"; }}
sign_path() {{{sign_path_body}
}}
IS_RELEASE=1
USE_ADHOC_SIGNING=0
USE_LOCAL_SELF_SIGNED_RELEASE=1
SIGN_IDENTITY='RepoPrompt CE Local Self-Signed Code Signing'
APP_BUNDLE='/tmp/RepoPrompt.app'
APP_ENTITLEMENTS='/tmp/RepoPrompt.entitlements'
LOCAL_SELF_SIGNED_REQUIREMENT='identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"{'1' * 40}"'
APP_SIGN_ARGS=(){app_signing_body}
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)
        env = os.environ.copy()
        env.update(
            {
                "CODESIGN_CAPTURE": str(capture),
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
            }
        )

        result = subprocess.run([str(probe)], env=env, text=True, capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            capture.read_bytes().rstrip(b"\0").decode().split("\0"),
            [
                "--force",
                "--sign",
                "RepoPrompt CE Local Self-Signed Code Signing",
                "--timestamp=none",
                "--options",
                "runtime",
                "--entitlements",
                "/tmp/RepoPrompt.entitlements",
                "--requirements",
                '=designated => identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"' + "1" * 40 + '"',
                "/tmp/RepoPrompt.app",
            ],
        )

    def test_main_executable_separate_sign_is_release_only(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        main_sign = 'sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"'
        # Static: the release line is verbatim and is the whole body of an IS_RELEASE gate.
        self.assertEqual(package_script.count(main_sign), 1)
        self.assertIn(f"if (( IS_RELEASE )); then\n{main_sign}\nfi\nAPP_SIGN_ARGS=()\n", package_script)
        self.assertLess(
            package_script.index('sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-gateway"'), package_script.index(main_sign)
        )
        # Stub probe: run the real signing-call block with sign_path recording its target paths.
        signing_calls = package_script.split("\nverify_signed_app_identity(){", 1)[1].split("\n}\n", 1)[1].split(
            'PACKAGE_TIMING_DEEP="ran"\nrun codesign --verify --deep --strict', 1
        )[0]
        # Debug with the signed component cache: misses are signed in cache entries, so the bundle
        # signs only its outer seal. Release and uncached debug keep the nested signing lines verbatim.
        # Step 6: a reused debug bundle (noop-dest/noop-clone; always 0 in release) signs nothing.
        self.assertTrue(signing_calls.startswith(
            "if (( ! DEBUG_PACKAGE_REUSED )); then\n"
            "if (( DEBUG_PACKAGE_COMPONENTS )); then\n    sign_debug_component_misses\nelse\n"
            'if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then sign_sparkle_framework '
            '"$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; fi\n'
            'sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"\n'
            'sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-gateway"\nfi\n'
        ))
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app_bundle = temp_dir / "RepoPrompt.app"
        (app_bundle / "Contents" / "Frameworks" / "Sparkle.framework").mkdir(parents=True)
        probe = temp_dir / "signing-calls-probe.sh"
        probe.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            'sign_path(){ printf \'%s\\n\' "$*"; }\n'
            'sign_sparkle_framework(){ printf \'sparkle %s\\n\' "$1"; }\n'
            "sign_debug_component_misses(){ echo components; }\n"
            f"APP_NAME=RepoPrompt\nAPP_BUNDLE='{app_bundle}'\nAPP_ENTITLEMENTS=/tmp/e.plist\n"
            "USE_ADHOC_SIGNING=0\nUSE_LOCAL_SELF_SIGNED_RELEASE=0\nIS_RELEASE=\"$1\"\nDEBUG_PACKAGE_COMPONENTS=\"$2\"\n"
            "DEBUG_PACKAGE_REUSED=\"${3:-0}\"\n"
            + signing_calls,
            encoding="utf-8",
        )
        probe.chmod(0o755)
        macos = f"{app_bundle}/Contents/MacOS"
        expected = {
            "0": [f"{macos}/repoprompt-mcp", f"{macos}/repoprompt-gateway", str(app_bundle)],
            "1": [
                f"{macos}/repoprompt-mcp",
                f"{macos}/repoprompt-gateway",
                f"{macos}/RepoPrompt",
                f"{app_bundle} --entitlements /tmp/e.plist",
            ],
        }
        for is_release, calls in expected.items():
            with self.subTest(is_release=is_release):
                result = subprocess.run([str(probe), is_release, "0"], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.splitlines(),
                    [f"sparkle {app_bundle}/Contents/Frameworks/Sparkle.framework", *calls],
                )
        with self.subTest(debug_component_cache=True):
            result = subprocess.run([str(probe), "0", "1"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["components", str(app_bundle)])
        for components in ("0", "1"):
            with self.subTest(debug_bundle_reused=True, components=components):
                result = subprocess.run([str(probe), "0", components, "1"], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [])

    def test_custom_packaging_resigns_sparkle_helpers_without_recursive_entitlement_propagation(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        info_plist = plistlib.loads((SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_bytes())

        for script in (package_script, staged_signing_script):
            self.assertIn('sign_path "$framework/Versions/B/XPCServices/Installer.xpc"', script)
            self.assertIn(
                'sign_path "$framework/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements',
                script,
            )
            self.assertIn('sign_path "$framework/Versions/B/Autoupdate"', script)
            self.assertIn('sign_path "$framework/Versions/B/Updater.app"', script)
            self.assertIn('sign_path "$framework"', script)

        self.assertIn('APP_SIGN_ARGS=()', package_script)
        self.assertNotIn('APP_SIGN_ARGS=(--deep)', package_script)
        self.assertNotIn('sign_path "$APP_BUNDLE" --deep', staged_signing_script)
        self.assertNotIn("SUEnableInstallerLauncherService", info_plist)
        self.assertIn("trap 'finish $?' EXIT", package_script)
        self.assertIn('local status="$1" now total', package_script)

    def test_release_paths_use_static_validation_in_privileged_contexts_and_token_stripped_local_smoke(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        public_update_script = (SCRIPT_DIR / "publish_public_update_test.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")

        package_outer_sign = package_script.index('sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"')
        package_layout = package_script.index('"$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"')
        package_smoke = package_script.index(
            '"$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"'
        )
        self.assertLess(package_outer_sign, package_layout)
        self.assertLess(package_layout, package_smoke)

        for privileged_script in (staged_signing_script, promote_script, public_update_script):
            self.assertIn("validate_embedded_mcp_helper_layout.sh", privileged_script)
            self.assertNotIn("smoke_embedded_mcp_helper.sh", privileged_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"', release_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_required_swiftpm_resource_bundles.sh"', release_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh"', release_script)
        self.assertIn(
            'require_file "$CONTROL_PLANE_SCRIPTS_DIR/patches/keyboardshortcuts-2.3.0-resource-lookup.patch"',
            release_script,
        )
        self.assertIn('DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"', release_script)
        self.assertIn('ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"', release_script)
        self.assertIn('DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"', promote_script)
        self.assertIn('APP_BUNDLE="$EXTRACT_DIR/$DISPLAY_NAME.app"', public_update_script)

    def test_embedded_mcp_helper_smoke_rejects_exit_137(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        helper = temp_dir / "RepoPrompt.app" / "Contents" / "MacOS" / "repoprompt-mcp"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/usr/bin/env bash\nexit 137\n", encoding="utf-8")
        helper.chmod(0o755)

        result = subprocess.run(
            [str(SCRIPT_DIR / "smoke_embedded_mcp_helper.sh"), str(temp_dir / "RepoPrompt.app"), "Fixture helper"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fixture helper failed --version smoke (exit 137)", result.stderr)

    def test_embedded_helper_smoke_rejects_canonical_path_escape(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
        helper.parent.mkdir(parents=True)
        outside = temp_dir / "outside-helper"
        outside.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        outside.chmod(0o755)
        helper.symlink_to(outside)

        result = subprocess.run(
            [str(SCRIPT_DIR / "smoke_embedded_mcp_helper.sh"), str(app), "Escaping helper"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes app bundle", result.stderr)

    def test_universal_builder_uses_isolated_architecture_scratch_paths_and_unsigned_merge(self) -> None:
        source = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")

        self.assertIn('SCRATCH_ROOT="${REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT:', source)
        self.assertIn('CLEAN_PUBLIC_SWIFTPM_BUILDS="${REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS:-1}"', source)
        self.assertIn('for arch in arm64 x86_64; do', source)
        self.assertIn('REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch"', source)
        self.assertIn('patch_keyboard_shortcuts_resource_lookup.sh', source)
        self.assertIn('--scratch-path "$scratch"', source)
        self.assertIn('--arch "$arch"', source)
        self.assertIn('--product RepoPrompt', source)
        self.assertIn('--product repoprompt-mcp', source)
        self.assertIn('--product repoprompt-gateway', source)
        self.assertIn('compare_swiftpm_release_resources.py', source)
        architecture_loop = source.split('for arch in arm64 x86_64; do', 1)[1]
        self.assertLess(source.index('run rm -rf "$SCRATCH_ROOT"'), source.index('for arch in arm64 x86_64; do'))
        self.assertLess(architecture_loop.index('"$KEYBOARD_SHORTCUTS_PATCH_HELPER"'), architecture_loop.index("swift build"))
        self.assertEqual(source.count('"$LIPO" -create'), 3)
        self.assertNotIn("codesign", source)

    def test_universal_builder_cleans_stale_resources_by_default_and_patches_each_fresh_scratch(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "source"
        root.mkdir()
        scratch = temp_dir / "scratch"
        output = temp_dir / "products" / "release"
        scratch.mkdir(parents=True)
        (scratch / ".repoprompt-public-swiftpm-scratch").write_text("fixture\n", encoding="utf-8")
        for arch in ("arm64", "x86_64"):
            stale = scratch / arch / "release" / "Stale.bundle"
            stale.mkdir(parents=True)
            (stale / "stale.txt").write_text("stale\n", encoding="utf-8")

        tools = temp_dir / "tools"
        tools.mkdir()
        patch_log = temp_dir / "patch.log"
        wrapper = tools / "without-tokens"
        wrapper.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RPCE_OPTIMIZED_DIAGNOSTICS+set}" && -z "${RPCE_OPTIMIZED_INCREMENTAL+set}" ]] || exit 42
[[ "$1" == "swift" && "$2" == "build" ]]
shift 2
scratch=""
arch=""
show=0
while (( $# )); do
    case "$1" in
        --scratch-path) scratch="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --show-bin-path) show=1; shift ;;
        *) shift ;;
    esac
done
bin="$scratch/release"
mkdir -p "$bin/Current.bundle"
printf '%s\\n' "$arch" > "$bin/RepoPrompt"
printf '%s\\n' "$arch" > "$bin/repoprompt-mcp"
printf '%s\\n' "$arch" > "$bin/repoprompt-gateway"
printf 'current\\n' > "$bin/Current.bundle/value.txt"
if (( show )); then printf '%s\\n' "$bin"; fi
""",
            encoding="utf-8",
        )
        patch = tools / "patch-keyboard-shortcuts"
        patch.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            "[[ -z \"${RPCE_OPTIMIZED_DIAGNOSTICS+set}\" && -z \"${RPCE_OPTIMIZED_INCREMENTAL+set}\" ]] || exit 42\n"
            "printf '%s\\n' \"$REPOPROMPT_SWIFTPM_SCRATCH_PATH\" >> \"$PATCH_LOG\"\n",
            encoding="utf-8",
        )
        comparator = tools / "compare-resources"
        comparator.write_text("#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n", encoding="utf-8")
        lipo = tools / "lipo"
        lipo.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-archs" ]]; then
    cat "$2"
    exit 0
fi
output=""
while (( $# )); do
    if [[ "$1" == "-output" ]]; then output="$2"; shift 2; else shift; fi
done
printf 'arm64 x86_64\\n' > "$output"
""",
            encoding="utf-8",
        )
        ditto = tools / "ditto"
        ditto.write_text("#!/usr/bin/env bash\nset -euo pipefail\ncp -R \"$1\" \"$2\"\n", encoding="utf-8")
        for tool in (wrapper, patch, comparator, lipo, ditto):
            tool.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{tools}:{env['PATH']}",
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(scratch),
                "REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS": str(wrapper),
                "REPOPROMPT_KEYBOARD_SHORTCUTS_PATCH_HELPER": str(patch),
                "REPOPROMPT_SWIFTPM_RESOURCE_COMPARATOR": str(comparator),
                "PATCH_LOG": str(patch_log),
                "LIPO": str(lipo),
                # The builder unsets both optimized-lane gates; the stubs exit 42 if either leaks.
                "RPCE_OPTIMIZED_DIAGNOSTICS": "1",
                "RPCE_OPTIMIZED_INCREMENTAL": "1",
            }
        )
        result = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(output)],
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / "Stale.bundle").exists())
        self.assertTrue((output / "Current.bundle" / "value.txt").is_file())
        self.assertEqual(
            patch_log.read_text(encoding="utf-8").splitlines(),
            [str(scratch / "arm64"), str(scratch / "x86_64")],
        )

        repository_marker = root / "must-survive.txt"
        repository_marker.write_text("keep\n", encoding="utf-8")
        unsafe_root_env = env | {"REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(root)}
        unsafe_root = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(temp_dir / "unsafe-root-output")],
            env=unsafe_root_env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(unsafe_root.returncode, 0)
        self.assertIn("repository root", unsafe_root.stderr)
        self.assertTrue(repository_marker.is_file())

        unmarked = temp_dir / "unmarked-scratch"
        unmarked.mkdir()
        unmarked_marker = unmarked / "must-survive.txt"
        unmarked_marker.write_text("keep\n", encoding="utf-8")
        unmarked_env = env | {"REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(unmarked)}
        unsafe_unmarked = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(temp_dir / "unsafe-unmarked-output")],
            env=unmarked_env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(unsafe_unmarked.returncode, 0)
        self.assertIn("unmarked public SwiftPM scratch path", unsafe_unmarked.stderr)
        self.assertTrue(unmarked_marker.is_file())

    def test_swiftpm_resource_comparator_accepts_equivalence_and_rejects_drift(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        arm = temp_dir / "arm"
        intel = temp_dir / "intel"
        for root in (arm, intel):
            (root / "Fixture.bundle" / "nested").mkdir(parents=True)
            (root / "Fixture.bundle" / "nested" / "value.txt").write_text("same\n", encoding="utf-8")
            (root / "Fixture.bundle" / "link").symlink_to("nested/value.txt")
            (root / "Sparkle.framework").mkdir()
            (root / "Sparkle.framework" / "Info.plist").write_text("same\n", encoding="utf-8")

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "compare_swiftpm_release_resources.py"), str(arm), str(intel)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        (intel / "Fixture.bundle" / "nested" / "value.txt").write_text("different\n", encoding="utf-8")
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "compare_swiftpm_release_resources.py"), str(arm), str(intel)],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("resource differs", rejected.stderr)

    def test_architecture_validator_accepts_universal_and_rejects_helper_mismatch(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        env = os.environ.copy()
        env["LIPO"] = str(fake_lipo)

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "validate_app_architectures.sh"), str(app), "arm64,x86_64", "Fixture"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        env["FAKE_THIN_HELPER"] = "1"
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "validate_app_architectures.sh"), str(app), "arm64,x86_64", "Fixture"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("matching app/helper/gateway architectures", rejected.stderr)

    def test_artifact_manifest_is_deterministic_external_and_detects_binary_drift(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        info = {
            "CFBundleExecutable": "RepoPrompt",
            "CFBundleIdentifier": "com.pvncher.repoprompt.ce",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "RepoPromptSigningMode": "release-candidate-adhoc",
        }
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        fake_codesign = app.parent / "codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *--extract-certificates*)
    [[ "${FAKE_CERTIFICATE_AVAILABLE:-0}" == "1" ]] || exit 1
    for argument in "$@"; do
      case "$argument" in
        --extract-certificates=*) printf 'fixture certificate\n' > "${argument#*=}0" ;;
      esac
    done
    ;;
  *--entitlements*)
    [[ "${FAKE_MISSING_ENTITLEMENTS:-0}" != "1" ]] || exit 1
    cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>fixture</key><true/></dict></plist>
PLIST
    ;;
  *-r-*)
    [[ "${FAKE_MISSING_REQUIREMENT:-0}" != "1" ]] || exit 0
    printf 'designated => identifier "fixture"\n' >&2
    ;;
  *)
    if [[ "${FAKE_CERTIFICATE_BACKED:-0}" == "1" ]]; then
      printf 'Identifier=fixture\nTeamIdentifier=TEAMID\nAuthority=Developer ID Application: Fixture\n' >&2
    else
      printf 'Identifier=fixture\nTeamIdentifier=not set\n' >&2
    fi
    ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = app.parent / "artifact-manifest.json"
        env = os.environ.copy()
        env.update({"LIPO": str(fake_lipo), "CODESIGN": str(fake_codesign)})
        writer = SCRIPT_DIR / "write_app_artifact_manifest.py"

        written = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(written.returncode, 0, written.stderr)
        content = manifest.read_text(encoding="utf-8")
        self.assertNotIn(str(app.parent), content)
        self.assertNotIn("generated_at", content)
        manifest_content = json.loads(content)
        self.assertIsNone(manifest_content["bundle_signing"]["leaf_certificate_sha256"])
        for executable in manifest_content["executables"]:
            self.assertIsNone(executable["signing"]["leaf_certificate_sha256"])
        # The RC fixture has no DSN, so telemetry is disabled.
        self.assertFalse(manifest_content["bundle"]["telemetry_enabled"])

        # With a DSN present, the manifest records telemetry_enabled=True but never the DSN value.
        dsn_value = "https://examplepublickey@o9999.ingest.sentry.io/424242"
        info_with_dsn = dict(info)
        info_with_dsn["RepoPromptSentryDSN"] = dsn_value
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_with_dsn))
        dsn_manifest = app.parent / "telemetry-manifest.json"
        dsn_written = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(dsn_manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(dsn_written.returncode, 0, dsn_written.stderr)
        dsn_manifest_text = dsn_manifest.read_text(encoding="utf-8")
        self.assertNotIn(dsn_value, dsn_manifest_text)
        self.assertNotIn("examplepublickey", dsn_manifest_text)
        self.assertTrue(json.loads(dsn_manifest_text)["bundle"]["telemetry_enabled"])
        # Restore the no-DSN RC Info.plist so the remainder of the test is unaffected.
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

        accepted = subprocess.run(
            [
                str(writer),
                "verify",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        env["FAKE_MISSING_REQUIREMENT"] = "1"
        missing_requirement = subprocess.run(
            [str(writer), "write", "--app", str(app), "--output", str(app.parent / "missing-requirement.json")],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(missing_requirement.returncode, 0, missing_requirement.stderr)
        missing_requirement_manifest = json.loads(
            (app.parent / "missing-requirement.json").read_text(encoding="utf-8")
        )
        self.assertIsNone(missing_requirement_manifest["bundle_signing"]["designated_requirement"])
        for executable in missing_requirement_manifest["executables"]:
            self.assertIsNone(executable["signing"]["designated_requirement"])

        env["FAKE_CERTIFICATE_BACKED"] = "1"
        certificate_backed_missing_requirement = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "certificate-backed-missing-requirement.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(certificate_backed_missing_requirement.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose a designated requirement",
            certificate_backed_missing_requirement.stderr,
        )
        env.pop("FAKE_MISSING_REQUIREMENT")
        certificate_backed_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "certificate-backed-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(certificate_backed_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            certificate_backed_missing_certificate.stderr,
        )
        env.pop("FAKE_CERTIFICATE_BACKED")

        info["RepoPromptSigningMode"] = "developer-id"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        env["FAKE_MISSING_REQUIREMENT"] = "1"
        developer_id_missing_requirement = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "developer-id-missing-requirement.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(developer_id_missing_requirement.returncode, 0)
        self.assertIn(
            "signed path did not expose a designated requirement",
            developer_id_missing_requirement.stderr,
        )
        env.pop("FAKE_MISSING_REQUIREMENT")
        developer_id_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "developer-id-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(developer_id_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            developer_id_missing_certificate.stderr,
        )

        info["RepoPromptSigningMode"] = "local-self-signed"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        local_self_signed_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "local-self-signed-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(local_self_signed_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            local_self_signed_missing_certificate.stderr,
        )

        info["RepoPromptSigningMode"] = "developer-id"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        env["FAKE_CERTIFICATE_AVAILABLE"] = "1"
        env["FAKE_MISSING_ENTITLEMENTS"] = "1"
        missing_entitlements = subprocess.run(
            [str(writer), "write", "--app", str(app), "--output", str(app.parent / "missing-entitlements.json")],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing_entitlements.returncode, 0)
        self.assertIn("did not expose parseable signed entitlements", missing_entitlements.stderr)
        env.pop("FAKE_MISSING_ENTITLEMENTS")
        env.pop("FAKE_CERTIFICATE_AVAILABLE")
        info["RepoPromptSigningMode"] = "release-candidate-adhoc"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

        with (app / "Contents" / "MacOS" / "repoprompt-mcp").open("a", encoding="utf-8") as handle:
            handle.write("drift\n")
        rejected = subprocess.run(
            [
                str(writer),
                "verify",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match app bundle", rejected.stderr)

    def test_artifact_manifest_records_certificate_from_equals_form_extraction(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        info = {
            "CFBundleExecutable": "RepoPrompt",
            "CFBundleIdentifier": "com.pvncher.repoprompt.ce",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "RepoPromptSigningMode": "developer-id",
        }
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        certificate = b"fixture leaf certificate\n"
        fake_codesign = app.parent / "codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" >> "$CODESIGN_CAPTURE"
for argument in "${@:2}"; do printf '\t%s' "$argument" >> "$CODESIGN_CAPTURE"; done
printf '\n' >> "$CODESIGN_CAPTURE"
certificate_prefix=""
for argument in "$@"; do
  case "$argument" in
    --extract-certificates=*) certificate_prefix="${argument#*=}" ;;
    --extract-certificates)
      printf 'certificate prefix must use the equals form\n' >&2
      exit 64
      ;;
  esac
done
if [[ -n "$certificate_prefix" ]]; then
  [[ "${FAKE_MISSING_CERTIFICATE_FOR:-}" != "${@: -1}" ]] || exit 1
  printf 'fixture leaf certificate\n' > "${certificate_prefix}0"
  exit 0
fi
case "$*" in
  *--entitlements*)
    printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n'
    ;;
  *-r-*)
    printf 'designated => identifier "fixture"\n' >&2
    ;;
  *)
    printf 'Identifier=fixture\nTeamIdentifier=TEAMID\nAuthority=Developer ID Application: Fixture\n' >&2
    ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = app.parent / "certificate-manifest.json"
        codesign_capture = app.parent / "codesign-argv.txt"
        env = os.environ.copy()
        env.update(
            {
                "LIPO": str(fake_lipo),
                "CODESIGN": str(fake_codesign),
                "CODESIGN_CAPTURE": str(codesign_capture),
            }
        )

        result = subprocess.run(
            [
                str(SCRIPT_DIR / "write_app_artifact_manifest.py"),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        content = json.loads(manifest.read_text(encoding="utf-8"))
        expected_fingerprint = hashlib.sha256(certificate).hexdigest()
        self.assertEqual(content["bundle_signing"]["leaf_certificate_sha256"], expected_fingerprint)
        for executable in content["executables"]:
            self.assertEqual(executable["signing"]["leaf_certificate_sha256"], expected_fingerprint)
        extraction_calls = [
            line.split("\t")
            for line in codesign_capture.read_text(encoding="utf-8").splitlines()
            if any(argument.startswith("--extract-certificates=") for argument in line.split("\t"))
        ]
        self.assertEqual(len(extraction_calls), 4)
        for arguments in extraction_calls:
            self.assertEqual(arguments[:2], ["-d", next(item for item in arguments if item.startswith("--extract-certificates="))])
            self.assertNotIn("--extract-certificates", arguments)

        covered_paths = [
            app / "Contents" / "MacOS" / "RepoPrompt",
            app / "Contents" / "MacOS" / "repoprompt-mcp",
            app / "Contents" / "MacOS" / "repoprompt-gateway",
            app,
        ]
        for index, covered_path in enumerate(covered_paths):
            with self.subTest(covered_path=covered_path):
                failure_env = env | {"FAKE_MISSING_CERTIFICATE_FOR": str(covered_path)}
                rejected = subprocess.run(
                    [
                        str(SCRIPT_DIR / "write_app_artifact_manifest.py"),
                        "write",
                        "--app",
                        str(app),
                        "--output",
                        str(app.parent / f"missing-certificate-{index}.json"),
                        "--expected-architectures",
                        "arm64,x86_64",
                    ],
                    env=failure_env,
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    f"certificate-backed signed path did not expose an extractable leaf certificate: {covered_path}",
                    rejected.stderr,
                )

    def test_packaging_path_identity_skips_nested_compatibility_link(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        architecture_release = temp_dir / ".build" / "arm64-apple-macosx" / "release"
        architecture_release.mkdir(parents=True)
        compatibility_release = temp_dir / ".build" / "release"
        compatibility_release.symlink_to(Path("arm64-apple-macosx") / "release")
        app_bundle = architecture_release / "RepoPrompt.app"
        compatibility_app_bundle = compatibility_release / "RepoPrompt.app"

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        function_body = package_script.split("paths_same(){", 1)[1].split("\n}\nfinish(){", 1)[0]
        probe = temp_dir / "path-identity-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
paths_same(){{{function_body}
}}
if [[ "$(paths_same "$1" "$2")" != "1" ]]; then
  ln -sfn "$1" "$2"
fi
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)

        result = subprocess.run(
            [str(probe), str(app_bundle), str(compatibility_app_bundle)],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(compatibility_app_bundle.is_symlink())
        self.assertFalse((app_bundle / "RepoPrompt.app").exists())

    def test_packaging_path_identity_keeps_case_distinct_missing_paths_separate(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        function_body = package_script.split("paths_same(){", 1)[1].split("\n}\nfinish(){", 1)[0]
        probe = temp_dir / "path-identity-case-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
paths_same(){{{function_body}
}}
paths_same "$1" "$2"
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)

        result = subprocess.run(
            [str(probe), str(temp_dir / "RepoPrompt.app"), str(temp_dir / "repoprompt.app")],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")

    def test_packaging_removes_stale_public_manifest_before_non_public_preflight(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        cleanup_before_metadata = """remove_stale_artifact_manifests
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"""
        manifest_write_block = package_script.split(
            'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Post-sign packaged app"',
            1,
        )[1].split(
            'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"',
            1,
        )[0]

        self.assertIn('manifests=("$ROOT_DIR"/.build/release/*-artifact-manifest.json)', package_script)
        self.assertIn(cleanup_before_metadata, package_script)
        self.assertIn("if (( PUBLIC_UNIVERSAL_RELEASE )); then", manifest_write_block)
        self.assertIn('write_app_artifact_manifest.py" write', manifest_write_block)
        self.assertIn('--output "$ARTIFACT_MANIFEST"', manifest_write_block)

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        shutil.copy2(SCRIPT_DIR / "parse_release_metadata.py", scripts / "parse_release_metadata.py")
        doctor = scripts / "doctor.sh"
        doctor.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8")
        doctor.chmod(0o755)
        metadata = root / "version.env"
        artifact_manifest = root / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        artifact_manifest.parent.mkdir(parents=True)
        env = os.environ.copy()
        env.update(
            {
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
            }
        )

        metadata.write_text("invalid metadata\n", encoding="utf-8")
        artifact_manifest.write_text("stale\n", encoding="utf-8")
        metadata_failure = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(metadata_failure.returncode, 0)
        self.assertFalse(artifact_manifest.exists())

        metadata.write_text(
            """APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
""",
            encoding="utf-8",
        )
        artifact_manifest.write_text("stale\n", encoding="utf-8")
        preflight_failure = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(preflight_failure.returncode, 42, preflight_failure.stderr)
        self.assertFalse(artifact_manifest.exists())

    def test_packaged_roundtrip_source_uses_exact_pid_and_isolated_cleanup_without_global_kill(self) -> None:
        source = (SCRIPT_DIR / "smoke_packaged_mcp_roundtrip.sh").read_text(encoding="utf-8")

        self.assertIn('env -i', source)
        self.assertIn('CFFIXED_USER_HOME="$ISOLATED_HOME"', source)
        self.assertIn('"$MCP_HELPER"', source)
        self.assertIn('[helper, "-e", "windows"]', source)
        self.assertIn('HELPER_REQUEST_TIMEOUT="${REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT:-30}"', source)
        self.assertIn('timeout=int(helper_timeout)', source)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT must be a positive integer', source)
        self.assertIn('log_phase() {', source)
        self.assertIn('windows-attempt-${attempt}.out', source)
        self.assertIn('windows-attempt-${attempt}.err', source)
        self.assertIn('CLI windows attempt ${attempt}', source)
        self.assertIn('APP_PID=$!', source)
        self.assertIn('launched-process.json', source)
        self.assertIn('verify_packaged_mcp_socket_owner.py', source)
        self.assertIn('preflight "$MCP_SOCKET_DIR"', source)
        self.assertIn('find-owner "$MCP_SOCKET_DIR" "$APP_PID" "$APP_EXECUTABLE"', source)
        self.assertIn('verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE"', source)
        self.assertLess(source.index('preflight "$MCP_SOCKET_DIR"'), source.index('APP_PID=$!'))
        roundtrip_loop = source.split('while (( $(date +%s) <= deadline )); do', 1)[1]
        self.assertLess(
            roundtrip_loop.index('verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE"'),
            roundtrip_loop.index("run_windows_request"),
        )
        self.assertIn('kill -TERM "$APP_PID"', source)
        self.assertIn('kill -KILL "$APP_PID"', source)
        self.assertIn('rm -rf "$TEMP_ROOT"', source)
        self.assertNotIn("pkill", source)
        self.assertNotIn("open -n", source)

    @unittest.skipUnless(sys.platform == "darwin", "macOS UNIX peer PID semantics")
    def test_packaged_socket_owner_helper_rejects_live_preflight_and_accepts_exact_owner(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        socket_directory = temp_dir / "repoprompt-ce-mcp"
        socket_directory.mkdir(mode=0o700)
        socket_path = socket_directory / "repoprompt-ce-7.sock"
        listener = self.start_unix_listener(socket_path)
        expected_executable = self.socket_owner_process_path(listener.pid)

        preflight = self.run_socket_owner_helper("preflight", socket_directory)
        found = self.run_socket_owner_helper("find-owner", socket_directory, listener.pid, expected_executable)
        verified = self.run_socket_owner_helper("verify-owner", socket_path, listener.pid, expected_executable)

        self.assertNotEqual(preflight.returncode, 0)
        self.assertIn("pre-existing live release socket", preflight.stderr)
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(Path(found.stdout.strip()), socket_path)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "macOS UNIX peer PID semantics")
    def test_packaged_socket_owner_helper_allows_stale_and_rejects_wrong_or_replaced_owner(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        socket_directory = temp_dir / "repoprompt-ce-mcp"
        socket_directory.mkdir(mode=0o700)
        socket_path = socket_directory / "repoprompt-ce-7.sock"
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(os.fspath(socket_path))
        stale.close()
        accepted_stale = self.run_socket_owner_helper("preflight", socket_directory)
        self.assertEqual(accepted_stale.returncode, 0, accepted_stale.stderr)

        socket_path.unlink()
        first = self.start_unix_listener(socket_path)
        first_executable = self.socket_owner_process_path(first.pid)
        socket_path.unlink()
        second = self.start_unix_listener(socket_path)
        second_executable = self.socket_owner_process_path(second.pid)

        replaced = self.run_socket_owner_helper("verify-owner", socket_path, first.pid, first_executable)
        current = self.run_socket_owner_helper("verify-owner", socket_path, second.pid, second_executable)

        self.assertNotEqual(replaced.returncode, 0)
        self.assertIn(f"belongs to pid {second.pid}", replaced.stderr)
        self.assertEqual(current.returncode, 0, current.stderr)

        socket_path.unlink()
        socket_path.write_text("not a socket\n", encoding="utf-8")
        nonsocket = self.run_socket_owner_helper("preflight", socket_directory)
        self.assertNotEqual(nonsocket.returncode, 0)
        self.assertIn("not a UNIX socket", nonsocket.stderr)

    def test_embedded_mcp_helper_layout_validator_accepts_canonical_layout(self) -> None:
        app = self.make_embedded_helper_layout()

        result = self.run_layout_validation(app)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matches the embedded helper layout policy", result.stdout)

    def test_embedded_mcp_helper_layout_validator_rejects_invalid_metadata(self) -> None:
        def helper_symlink(app: Path) -> None:
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.unlink()
            helper.symlink_to("RepoPrompt")

        def non_executable_helper(app: Path) -> None:
            (app / "Contents" / "MacOS" / "repoprompt-mcp").chmod(0o644)

        def missing_resources_link(app: Path) -> None:
            (app / "Contents" / "Resources" / "repoprompt-mcp").unlink()

        def missing_bin_link(app: Path) -> None:
            (app / "Contents" / "Resources" / "bin" / "repoprompt-mcp").unlink()

        def alternate_in_app_target(app: Path) -> None:
            link = app / "Contents" / "Resources" / "repoprompt-mcp"
            link.unlink()
            link.symlink_to("../MacOS/RepoPrompt")

        for label, mutate in (
            ("helper symlink", helper_symlink),
            ("non-executable helper", non_executable_helper),
            ("missing resources link", missing_resources_link),
            ("missing bin link", missing_bin_link),
            ("alternate in-app target", alternate_in_app_target),
        ):
            with self.subTest(label=label):
                app = self.make_embedded_helper_layout()
                mutate(app)
                result = self.run_layout_validation(app)
                self.assertNotEqual(result.returncode, 0)

    def test_release_workflows_isolate_executable_helper_smoke_and_harden_p12_cleanup(self) -> None:
        release_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        promote_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release-promote.yml").read_text(
            encoding="utf-8"
        )

        publish_job = release_workflow.split("\n  publish:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        publish_staged = "        run: ./trusted-control-plane/Scripts/release.sh publish-staged"
        cleanup_step = "      - name: Remove ephemeral keychain"
        upload_step = "      - name: Upload signed release ZIP for secret-free smoke"
        self.assertLess(publish_job.index(publish_staged), publish_job.index(cleanup_step))
        self.assertLess(publish_job.index(cleanup_step), publish_job.index(upload_step))
        signed_upload = publish_job.split(upload_step, 1)[1]
        self.assertIn("release-source/dist/*.zip", signed_upload)
        self.assertIn("release-source/dist/SHA256SUMS", signed_upload)

        signed_smoke = release_workflow.split("\n  smoke-signed-helper:", 1)[1]
        self.assertNotIn("environment: release", signed_smoke)
        self.assertIn("RepoPrompt-CE-signed-release-zip", signed_smoke)
        self.assertIn("checksum_manifests=(signed-release/*SHA256SUMS)", signed_smoke)
        self.assertIn("artifact_manifests=(signed-release/*-artifact-manifest.json)", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum manifest", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum entry", signed_smoke)
        self.assertIn("shasum -a 256 -c", signed_smoke)
        self.assertLess(signed_smoke.index("shasum -a 256 -c"), signed_smoke.index("ditto -x -k"))
        self.assertIn("validate_embedded_mcp_helper_layout.sh", signed_smoke)
        self.assertIn("validate_app_architectures.sh", signed_smoke)
        self.assertIn("write_app_artifact_manifest.py verify", signed_smoke)
        self.assertIn("smoke_packaged_mcp_roundtrip.sh", signed_smoke)
        self.assertIn('"extracted/RepoPrompt CE.app"', signed_smoke)
        self.assertIn("env -i", signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', signed_smoke)
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", signed_smoke)
        self.assertIn('HOME="$HOME"', signed_smoke)
        self.assertIn('TMPDIR="$RUNNER_TEMP"', signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"', signed_smoke)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            signed_smoke,
        )

        reviewed_smoke = promote_workflow.split("\n  smoke-reviewed-helper:", 1)[1].split("\n  promote:", 1)[0]
        self.assertNotIn("environment: release", reviewed_smoke)
        self.assertIn("contents: write", reviewed_smoke)
        self.assertIn("GH_TOKEN: ${{ github.token }}", reviewed_smoke)
        self.assertIn("reviewed_checksums_sha256", reviewed_smoke)
        self.assertIn("validate_embedded_mcp_helper_layout.sh", reviewed_smoke)
        self.assertIn("validate_app_architectures.sh", reviewed_smoke)
        self.assertIn("write_app_artifact_manifest.py verify", reviewed_smoke)
        self.assertIn("smoke_packaged_mcp_roundtrip.sh", reviewed_smoke)
        self.assertIn('"extracted/RepoPrompt CE.app"', reviewed_smoke)
        self.assertIn("env -i", reviewed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', reviewed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', reviewed_smoke)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"',
            reviewed_smoke,
        )
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            reviewed_smoke,
        )
        promote_job = promote_workflow.split("\n  promote:", 1)[1]
        self.assertIn("- smoke-reviewed-helper", promote_job)
        self.assertIn("environment: release", promote_job)

        p12_import = release_workflow.split("      - name: Import Developer ID certificate", 1)[1].split(
            "      - name: Prepare provisioning profile and notarization key", 1
        )[0]
        self.assertIn("umask 077", p12_import)
        self.assertLess(
            p12_import.index("trap cleanup_certificate_and_failed_keychain EXIT"),
            p12_import.index("base64 --decode"),
        )
        self.assertIn('rm -f "$CERTIFICATE_PATH"', p12_import)
        self.assertIn('security delete-keychain "$KEYCHAIN_PATH" || true', p12_import)
        final_cleanup = publish_job.split(cleanup_step, 1)[1].split(upload_step, 1)[0]
        self.assertIn("if: always()", final_cleanup)
        self.assertIn('KEYCHAIN_PATH="$RUNNER_TEMP/repoprompt-release.keychain-db"', final_cleanup)
        self.assertIn('CERTIFICATE_PATH="$RUNNER_TEMP/repoprompt-release.p12"', final_cleanup)
        self.assertIn('rm -f "$CERTIFICATE_PATH"', final_cleanup)
        self.assertIn('rm -rf "$RUNNER_TEMP/repoprompt-release-secrets"', final_cleanup)

    def test_sentry_symbol_upload_helper_uses_token_file_without_logging_secret(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        symbols = temp_dir / "symbols"
        symbols.mkdir()
        (symbols / "RepoPrompt.dSYM").mkdir()
        ambient_token = "sntrys_wrong_ambient_secret_token"
        token = "sntrys_fixture_secret_token"
        token_file = temp_dir / "sentry-token"
        token_file.write_text(token + "\n", encoding="utf-8")
        argv_capture = temp_dir / "argv.txt"
        token_capture = temp_dir / "token.txt"
        fake_cli = temp_dir / "sentry-cli"
        fake_cli.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ARGV_CAPTURE"
printf '%s' "${SENTRY_AUTH_TOKEN:-}" > "$TOKEN_CAPTURE"
""",
            encoding="utf-8",
        )
        fake_cli.chmod(0o755)
        env = os.environ.copy()
        env["SENTRY_AUTH_TOKEN"] = ambient_token
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE": str(token_file),
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "ARGV_CAPTURE": str(argv_capture),
                "TOKEN_CAPTURE": str(token_capture),
            }
        )

        result = subprocess.run(
            [str(SCRIPT_DIR / "upload_sentry_debug_symbols.sh"), str(symbols)],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(token, result.stdout)
        self.assertNotIn(token, result.stderr)
        argv = argv_capture.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            argv,
            [
                "debug-files",
                "upload",
                "--org",
                "fixture-org",
                "--project",
                "fixture-project",
                str(symbols),
            ],
        )
        self.assertNotIn("--include-sources", argv)
        self.assertNotIn(token, "\n".join(argv))
        self.assertEqual(token_capture.read_text(encoding="utf-8"), token)

    def run_sentry_prepare_fixture(
        self,
        lookup_mode: str,
        attempts: int = 1,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        call_log = temp_dir / "sentry-calls.log"
        release_state = temp_dir / "release-created"
        fake_cli = temp_dir / "sentry-cli"
        fake_cli.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SENTRY_CALL_LOG"
if [[ "$*" == *"releases info"* ]]; then
    case "$SENTRY_LOOKUP_MODE" in
        not-found-once)
            if [[ -f "$SENTRY_RELEASE_STATE" ]]; then
                exit 0
            fi
            printf 'error: release not found (404)\n' >&2
            exit 1
            ;;
        denied)
            printf 'error: authentication failed\n' >&2
            exit 2
            ;;
        existing)
            exit 0
            ;;
    esac
fi
if [[ "$*" == *"releases new"* ]]; then
    : > "$SENTRY_RELEASE_STATE"
fi
""",
            encoding="utf-8",
        )
        fake_cli.chmod(0o755)
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "REPOPROMPT_ENABLE_SENTRY": "1",
                "SENTRY_AUTH_TOKEN": "fixture-token",
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "SOURCE_GITHUB_REPOSITORY": "fixture/repository",
                "RELEASE_COMMIT": "0123456789abcdef",
                "SENTRY_LOOKUP_MODE": lookup_mode,
                "SENTRY_CALL_LOG": str(call_log),
                "SENTRY_RELEASE_STATE": str(release_state),
                "ATTEMPTS": str(attempts),
            }
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; for ((attempt = 0; attempt < ATTEMPTS; attempt++)); do prepare_sentry_release; done',
                "sentry-release-test",
                str(SCRIPT_DIR / "release.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        calls = call_log.read_text(encoding="utf-8").splitlines() if call_log.exists() else []
        return result, calls

    def test_sentry_release_prepare_creates_only_for_not_found_and_is_retry_safe(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("not-found-once", attempts=2)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum("releases info" in call for call in calls), 2)
        self.assertEqual(sum("releases new" in call for call in calls), 1)
        self.assertEqual(sum("releases set-commits" in call for call in calls), 2)
        self.assertTrue(
            any(
                "--org fixture-org releases new --project fixture-project "
                "com.pvncher.repoprompt.ce@" in call
                for call in calls
            )
        )
        self.assertTrue(
            all(
                "--commit fixture/repository@0123456789abcdef" in call
                for call in calls
                if "releases set-commits" in call
            )
        )

    def test_sentry_release_prepare_does_not_create_after_lookup_failure(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("denied")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum("releases info" in call for call in calls), 1)
        self.assertFalse(any("releases new" in call for call in calls))
        self.assertFalse(any("releases set-commits" in call for call in calls))
        self.assertIn("refusing to create it", result.stderr)
        self.assertNotIn("fixture-token", result.stdout + result.stderr)

    def test_sentry_symbol_flow_is_explicit_secret_safe_and_release_only_by_default(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        universal_builder = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        release_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        promote_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release-promote.yml").read_text(encoding="utf-8")
        conductor = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")

        self.assertIn('SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/$CONF"', package_script)
        self.assertNotIn("REPOPROMPT_SENTRY_SYMBOLS_DIR", package_script)
        self.assertIn("SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)", package_script)
        self.assertIn('run xcrun dsymutil "$BUILD_DIR/$exe" -o "$SENTRY_SYMBOLS_DIR/$exe.dSYM"', package_script)
        self.assertIn('if truthy "${REPOPROMPT_UPLOAD_SENTRY_SYMBOLS:-}"; then', package_script)
        self.assertIn("REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires REPOPROMPT_ENABLE_SENTRY=1", package_script)
        self.assertIn("REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires SENTRY_AUTH_TOKEN or REPOPROMPT_SENTRY_AUTH_TOKEN_FILE", package_script)
        self.assertIn("SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)", universal_builder)

        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh"', release_script)
        self.assertIn('SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"', release_script)
        self.assertIn('ditto "$SENTRY_SYMBOLS_DIR" "$stage_root/.build/sentry-symbols/release"', release_script)
        self.assertIn('upload_required_sentry_symbols', release_script)
        self.assertIn('SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"', release_script)
        self.assertIn('require_sentry_publish_configuration() {', release_script)
        self.assertIn('require_command sentry-cli', release_script)
        self.assertIn('prepare_sentry_release', release_script)
        self.assertIn('releases new', release_script)
        self.assertIn('releases set-commits', release_script)
        self.assertIn('--commit "$source_repository@$RELEASE_COMMIT"', release_script)
        self.assertIn('finalize_sentry_release', release_script)
        self.assertIn('releases finalize "$SENTRY_RELEASE_NAME"', release_script)
        self.assertNotIn('record_sentry_production_deploy', release_script)
        self.assertNotIn('releases deploys "$SENTRY_RELEASE_NAME" new', release_script)
        self.assertIn('SENTRY_AUTH_TOKEN="$(tr -d', release_script)

        self.assertIn('preflight_sentry_deploy_access', promote_script)
        self.assertIn('record_verified_sentry_deploy_if_needed', promote_script)
        self.assertIn("'$value | @uri'", promote_script)
        self.assertIn('sentry_api_request POST', promote_script)
        self.assertNotIn('sentry-cli', promote_script)
        sentry_request = promote_script.split("sentry_api_request() {", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("--retry", sentry_request)

        publish_staged = release_script.split("publish_staged_release() {", 1)[1].split("\n}\n\ncase", 1)[0]
        self.assertLess(publish_staged.index("prepare_sentry_release"), publish_staged.index("upload_required_sentry_symbols"))
        self.assertLess(publish_staged.index("upload_required_sentry_symbols"), publish_staged.index("gh release view"))
        self.assertLess(publish_staged.index("gh release view"), publish_staged.index("gh release create"))
        self.assertLess(publish_staged.index("gh release create"), publish_staged.index("finalize_sentry_release"))

        promote_case = promote_script.split('    promote)\n', 1)[1].split('        ;;', 1)[0]
        self.assertLess(promote_case.index("preflight_sentry_deploy_access"), promote_case.index("publish_reviewed_release"))
        self.assertLess(promote_case.index("publish_reviewed_release"), promote_case.index("verify_anonymous_publish"))
        self.assertLess(promote_case.index("verify_anonymous_publish"), promote_case.index("record_verified_sentry_deploy_if_needed"))

        stage_job = release_workflow.split("\n  stage:", 1)[1].split("\n  publish:", 1)[0]
        publish_job = release_workflow.split("\n  publish:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', stage_job)
        self.assertNotIn("SENTRY_AUTH_TOKEN", stage_job)
        self.assertIn("Install Sentry CLI when symbol upload is configured", publish_job)
        self.assertIn("brew install getsentry/tools/sentry-cli", publish_job)
        self.assertIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", publish_job)
        self.assertLess(
            publish_job.index("Install Sentry CLI when symbol upload is configured"),
            publish_job.index("Sign, notarize, and create draft release"),
        )
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', publish_job)
        self.assertIn("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}", publish_job)
        self.assertIn("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}", publish_job)

        promote_job = promote_workflow.split("\n  promote:", 1)[1]
        self.assertIn("Prepare Sentry promotion token file", promote_job)
        self.assertIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", promote_job)
        self.assertIn("chmod 600", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_DEPLOY_ENVIRONMENT: production", promote_job)
        self.assertIn("Remove Sentry promotion token file", promote_job)
        self.assertNotIn("sentry-cli", promote_job)

        self.assertIn('"REPOPROMPT_ENABLE_SENTRY"', conductor)
        self.assertIn('"REPOPROMPT_UPLOAD_SENTRY_SYMBOLS"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_AUTH_TOKEN_FILE"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_ORG"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_PROJECT"', conductor)
        self.assertNotIn('"SENTRY_AUTH_TOKEN"', conductor)

    def test_staged_release_extractor_rejects_alternate_in_app_cli_target(self) -> None:
        for relative, alternate_target in (
            ("Contents/Resources/repoprompt-mcp", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-mcp", "../../MacOS/RepoPrompt"),
            ("Contents/Resources/repoprompt-gateway", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-gateway", "../../MacOS/RepoPrompt"),
        ):
            with self.subTest(relative=relative):
                temp_dir = Path(tempfile.mkdtemp())
                self.addCleanup(shutil.rmtree, temp_dir, True)
                archive = temp_dir / "stage.zip"
                destination = temp_dir / "extract"
                info = zipfile.ZipInfo(f".build/release/RepoPrompt.app/{relative}")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr(info, alternate_target)

                result = subprocess.run(
                    [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
                    text=True,
                    capture_output=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected or escaping staged archive symlink", result.stderr)

    def test_staged_release_validator_rejects_alternate_in_app_cli_target(self) -> None:
        for relative, alternate_target in (
            ("Contents/Resources/repoprompt-mcp", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-mcp", "../../MacOS/RepoPrompt"),
            ("Contents/Resources/repoprompt-gateway", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-gateway", "../../MacOS/RepoPrompt"),
        ):
            with self.subTest(relative=relative):
                approved, staged, scripts = self.make_staged_release_fixture()
                link = staged / ".build" / "release" / "RepoPrompt.app" / relative
                link.unlink()
                link.symlink_to(alternate_target)

                result = self.run_staged_validation(approved, staged, scripts)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected or escaping staged symlink", result.stderr)

    def test_staged_release_validator_accepts_keyboard_shortcuts_resources_layout(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: staged release payload matches approved source", result.stdout)

    def test_staged_release_validator_rejects_keyboard_shortcuts_app_root_bundle(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        self.write_keyboard_shortcuts_bundle(app / "KeyboardShortcuts_KeyboardShortcuts.bundle")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected app bundle root entries", result.stderr)
        self.assertIn("KeyboardShortcuts_KeyboardShortcuts.bundle", result.stderr)

    def test_staged_release_validator_rejects_missing_keyboard_shortcuts_resources_bundle(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        shutil.rmtree(app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required SwiftPM resource bundle directory", result.stderr)
        self.assertIn("KeyboardShortcuts_KeyboardShortcuts.bundle", result.stderr)

    def test_resource_bundle_normalizer_rewrites_flat_keyboard_shortcuts_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "RepoPrompt.app"
            bundle = app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle"
            (bundle / "en.lproj").mkdir(parents=True)
            (bundle / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
            (bundle / "en.lproj" / "Localizable.strings").write_text('"record_shortcut" = "Record Shortcut";\n', encoding="utf-8")

            result = subprocess.run(
                [str(SCRIPT_DIR / "normalize_swiftpm_resource_bundles.sh"), str(app)],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((bundle / "Contents" / "Info.plist").is_file())
            self.assertTrue((bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.strings").is_file())
            self.assertFalse((bundle / "Info.plist").exists())
            self.assertFalse((bundle / "en.lproj").exists())

    def test_staged_release_validator_rejects_missing_keyboard_shortcuts_patch_marker(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        (app / "Contents" / "MacOS" / "RepoPrompt").write_text("unpatched fixture\n", encoding="utf-8")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing KeyboardShortcuts resource lookup patch marker", result.stderr)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", result.stderr)

    def test_keyboard_shortcuts_patch_helper_applies_and_is_idempotent(self) -> None:
        root, utilities = self.make_keyboard_shortcuts_patch_fixture()

        applied = self.run_keyboard_shortcuts_patch(root)
        applied_text = utilities.read_text(encoding="utf-8")
        skipped = self.run_keyboard_shortcuts_patch(root)

        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertIn("Applied KeyboardShortcuts resource lookup patch", applied.stdout)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", applied_text)
        self.assertIn("Bundle.main.resourceURL?.appendingPathComponent(bundleName)", applied_text)
        self.assertEqual(skipped.returncode, 0, skipped.stderr)
        self.assertIn("already applied", skipped.stdout)

    def test_keyboard_shortcuts_patch_helper_checks_pin_before_idempotent_skip(self) -> None:
        root, _ = self.make_keyboard_shortcuts_patch_fixture()
        applied = self.run_keyboard_shortcuts_patch(root)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.write_package_resolved(root, "2.3.0", revision="changed-revision")

        rejected = self.run_keyboard_shortcuts_patch(root)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("KeyboardShortcuts dependency version or revision changed", rejected.stderr)
        self.assertIn("changed-revision", rejected.stderr)
        self.assertNotIn("already applied", rejected.stdout)

    def test_keyboard_shortcuts_patch_helper_rejects_source_drift(self) -> None:
        root, _ = self.make_keyboard_shortcuts_patch_fixture(source='extension String {\n\tvar localized: String { self }\n}\n')

        result = self.run_keyboard_shortcuts_patch(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch no longer applies cleanly", result.stderr)

    def test_package_app_invokes_keyboard_shortcuts_patch_and_shared_swiftpm_bundle_validator(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        universal_builder = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")
        patch_helper = (SCRIPT_DIR / "patch_keyboard_shortcuts_resource_lookup.sh").read_text(encoding="utf-8")
        staged_validator = (SCRIPT_DIR / "validate_staged_release.sh").read_text(encoding="utf-8")
        shared_validator = (SCRIPT_DIR / "validate_required_swiftpm_resource_bundles.sh").read_text(encoding="utf-8")

        dependency_patch = package_script.index("patch_keyboard_shortcuts_resource_lookup.sh")
        first_build = package_script.index('phase "Building $APP_NAME ($CONF, host-native)"')
        universal_dependency_patch = universal_builder.index("patch_keyboard_shortcuts_resource_lookup.sh")
        universal_first_build = universal_builder.index("swift build")
        broad_resources_copy = package_script.index('for bundle in "$BUILD_DIR"/*.bundle; do run cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"; done')
        resources_validation = package_script.index("validate_required_swiftpm_resource_bundles.sh")
        outer_app_sign = package_script.index('sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"')

        self.assertIn("validate_required_swiftpm_resource_bundles.sh", staged_validator)
        self.assertIn('required_bundles = ["KeyboardShortcuts_KeyboardShortcuts.bundle"]', shared_validator)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", shared_validator)
        self.assertNotIn("RepoPromptKeyboardShortcutsResourceLookupV1", package_script)
        self.assertIn('REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch"', universal_builder)
        self.assertIn('--scratch-path "$SWIFTPM_SCRATCH_PATH"', patch_helper)
        self.assertLess(dependency_patch, first_build)
        self.assertLess(universal_dependency_patch, universal_first_build)
        self.assertLess(broad_resources_copy, resources_validation)
        self.assertLess(resources_validation, outer_app_sign)

    def test_host_native_debug_runs_one_product_less_build_and_release_keeps_three_product_builds(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        host_native = package_script.split('phase "Patching KeyboardShortcuts resource lookup"', 1)[1].split(
            'phase "Resolving build artifact paths"', 1
        )[0]
        release_branch, debug_branch = host_native.split("    if (( IS_RELEASE )); then\n", 1)[1].split("    else\n", 1)
        debug_branch = debug_branch.split("    fi\n", 1)[0]
        release_lines = [
            'phase "Building $APP_NAME ($CONF, host-native)"',
            'run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_NAME"',
            'phase "Building repoprompt-mcp ($CONF, host-native)"',
            'run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-mcp',
            'phase "Building repoprompt-gateway ($CONF, host-native)"',
            'run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-gateway',
        ]
        debug_phase = 'phase "Building debug products ($CONF, host-native)"'
        # The optimized-diagnostics lane prefixes only the debug build (an empty array for `debug`).
        debug_build = (
            'run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" ${CANONICAL_PREFIX[@]+"${CANONICAL_PREFIX[@]}"} '
            'build "${SWIFT_BUILD_ARGS[@]}"\n'
        )

        # Release keeps its three product builds verbatim (original indentation) and in order.
        positions = [("\n" + release_branch).index("\n    " + line + "\n") for line in release_lines]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn(debug_phase, release_branch)
        self.assertNotIn("CANONICAL_PREFIX", release_branch)
        self.assertEqual(release_branch.count("canonical_swift.sh"), 3)
        # Debug runs exactly one product-less build after the KeyboardShortcuts patch.
        self.assertIn(debug_phase, debug_branch)
        self.assertEqual(debug_branch.count("canonical_swift.sh"), 1)
        self.assertIn(debug_build, debug_branch)
        self.assertNotIn("--product", debug_branch)
        self.assertLess(debug_branch.index(debug_phase), debug_branch.index(debug_build))
        self.assertLess(package_script.index("patch_keyboard_shortcuts_resource_lookup.sh"), package_script.index(debug_phase))
        self.assertLess(package_script.index(debug_phase), package_script.index('phase "Resolving build artifact paths"'))
        self.assertEqual(package_script.count("--show-bin-path)"), 1)

    def test_host_native_build_commands_differ_only_between_debug_and_release(self) -> None:
        # Stub evidence: fake doctor, KeyboardShortcuts patch and canonical_swift.sh record argv;
        # the bin-path query fails on purpose so packaging stops before any bundle work.
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        shutil.copy2(SCRIPT_DIR / "parse_release_metadata.py", scripts / "parse_release_metadata.py")
        (root / "version.env").write_text(
            "APP_NAME=RepoPrompt\nDISPLAY_NAME=\"RepoPrompt CE\"\nMARKETING_VERSION=1.0.0\nBUILD_NUMBER=1\n"
            "BUNDLE_ID=com.pvncher.repoprompt.ce\nSIGNING_TEAM_ID=648A27MST5\n",
            encoding="utf-8",
        )
        calls = temp_dir / "calls.log"
        # Every stub fails (exit 42) if an optimized-lane manifest gate leaks into it: the caller
        # exports both gates below and package_app.sh must unset them.
        gate_guard = '[[ -z "${RPCE_OPTIMIZED_DIAGNOSTICS+set}" && -z "${RPCE_OPTIMIZED_INCREMENTAL+set}" ]] || exit 42\n'
        stubs = {
            "doctor.sh": gate_guard + "exit 0\n",
            "patch_keyboard_shortcuts_resource_lookup.sh": (
                gate_guard
                + 'printf "patch%s\\n" "${REPOPROMPT_SWIFTPM_SCRATCH_PATH:+ $REPOPROMPT_SWIFTPM_SCRATCH_PATH}" >> "$STUB_CALLS"\n'
            ),
            "canonical_swift.sh": (
                gate_guard
                + 'printf "swift %s\\n" "$*" >> "$STUB_CALLS"\n'
                'for arg in "$@"; do [[ "$arg" != --show-bin-path ]] || exit 7; done\n'
            ),
        }
        for name, body in stubs.items():
            stub = scripts / name
            stub.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
            stub.chmod(0o755)
        base_env = {
            key: value
            for key, value in os.environ.items()
            if key not in {
                "SIGN_IDENTITY", "REPOPROMPT_ENABLE_SENTRY", "VERBOSE", "BUNDLE_ID", "APP_NAME", "DEBUG_SECURE_STORAGE_BACKEND",
                "DEBUG_BUNDLE_ID", "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS", "REPOPROMPT_SWIFTPM_SCRATCH_PATH",
            }
            and not key.startswith(("LOCAL_SELF_SIGNED", "LOCAL_SIGNING", "ALLOW_ADHOC", "RELEASE_ALLOW"))
        }
        security_calls = temp_dir / "security.log"
        base_env.update(
            {
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "STUB_CALLS": str(calls),
                "RPCE_OPTIMIZED_DIAGNOSTICS": "1",
                "RPCE_OPTIMIZED_INCREMENTAL": "1",
                "PATH": self.install_empty_security_stub(temp_dir / "tools", security_calls) + ":" + os.environ["PATH"],
            }
        )
        canonical = scripts / "canonical_swift.sh"
        cases = {
            "debug": (
                {"ALLOW_ADHOC_SIGNING": "1", "PREFER_STABLE_DEBUG_SIGNING": "0"},
                ["patch", "swift build -c debug", "swift build -c debug --show-bin-path"],
                ["Building debug products (debug, host-native)"],
            ),
            # The lane needs an explicit Apple Development identity (no ALLOW_ADHOC_SIGNING). Only the
            # debug build and the executed bin-path query reach the stub; the echoed query is stdout only.
            "debug-optimized": (
                {"SIGN_IDENTITY": "Apple Development: Stub"},
                [
                    f"patch {root / '.build' / 'optimized-diagnostics'}",
                    "swift --rpce-optimized-diagnostics build -c release",
                    "swift --rpce-optimized-diagnostics build -c release --show-bin-path",
                ],
                ["Building debug products (debug-optimized, host-native)"],
            ),
            # Same rules; only the wrapper's lane flag and the scratch folder differ.
            "debug-optimized-incremental": (
                {"SIGN_IDENTITY": "Apple Development: Stub"},
                [
                    f"patch {root / '.build' / 'optimized-incremental'}",
                    "swift --rpce-optimized-incremental build -c release",
                    "swift --rpce-optimized-incremental build -c release --show-bin-path",
                ],
                ["Building debug products (debug-optimized-incremental, host-native)"],
            ),
            "release": (
                {
                    "LOCAL_SELF_SIGNED_RELEASE": "1",
                    "SIGN_IDENTITY": "RepoPrompt CE Stub Identity",
                    "LOCAL_SIGNING_CERTIFICATE_SHA1": "a" * 40,
                    "LOCAL_SIGNING_CERTIFICATE_SHA256": "b" * 64,
                    "LOCAL_SIGNING_SERVICE_GENERATION": "1",
                },
                [
                    "patch",
                    "swift build -c release --product RepoPrompt",
                    "swift build -c release --product repoprompt-mcp",
                    "swift build -c release --product repoprompt-gateway",
                    "swift build -c release --show-bin-path",
                ],
                [
                    "Building RepoPrompt (release, host-native)",
                    "Building repoprompt-mcp (release, host-native)",
                    "Building repoprompt-gateway (release, host-native)",
                ],
            ),
        }
        echoed_bin_path = {
            "debug": f"+ {canonical} build -c debug --show-bin-path ",
            "debug-optimized": f"+ {canonical} --rpce-optimized-diagnostics build -c release --show-bin-path ",
            "debug-optimized-incremental": f"+ {canonical} --rpce-optimized-incremental build -c release --show-bin-path ",
            "release": f"+ {canonical} build -c release --show-bin-path ",
        }
        lane_banner = "*** OPTIMIZED DIAGNOSTICS LANE: swift -c release, first-party DEBUG, debug identity ***"
        incremental_banner = (
            "*** OPTIMIZED INCREMENTAL APP LANE: swift -c release, first-party DEBUG, "
            "RepoPromptApp non-WMO incremental, rest WMO, debug identity ***"
        )
        # The default bash and macOS /bin/bash 3.2 (empty-array expansion under set -u).
        for interpreter in ([], ["/bin/bash"]):
            for conf, (extra_env, expected_calls, expected_build_phases) in cases.items():
                with self.subTest(conf=conf, interpreter=interpreter):
                    calls.unlink(missing_ok=True)
                    result = subprocess.run(
                        [*interpreter, str(SCRIPT_DIR / "package_app.sh"), conf],
                        env={**base_env, **extra_env},
                        text=True,
                        capture_output=True,
                    )
                    self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                    self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), expected_calls)
                    self.assertIn(echoed_bin_path[conf] + "\n", result.stdout)
                    self.assertEqual(result.stdout.count(lane_banner), 1 if conf == "debug-optimized" else 0)
                    self.assertEqual(
                        result.stdout.count(incremental_banner), 1 if conf == "debug-optimized-incremental" else 0
                    )
                    if conf.startswith("debug-optimized"):
                        # The identity listing came from the empty stub, never the host keychain.
                        self.assertIn("security find-identity -v -p codesigning", security_calls.read_text(encoding="utf-8"))
                    timing_prefix = '[package-timing] phase="Building '
                    build_phases = [
                        line[len('[package-timing] phase="'):].split('" elapsed_ms=', 1)[0]
                        for line in result.stdout.splitlines()
                        if line.startswith(timing_prefix)
                    ]
                    self.assertEqual(build_phases, expected_build_phases)

    def make_optimized_lane_stub_root(self, bundle_id: str = "com.pvncher.repoprompt.ce") -> tuple[Path, Path, dict]:
        """Stub repo for package_app.sh lane probes: no real Swift, signing or cache work.

        canonical_swift.sh records argv and answers --show-bin-path with $STUB_BIN_DIR (creating it
        unless it is a symlink); verify_build_lane_flags.py records argv and exits $STUB_VERIFY_STATUS;
        debug_package_cache.py records its subcommand and exits 9, so a run that reaches the cache
        stops there with no plan, publish or stamp.
        """
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        shutil.copy2(SCRIPT_DIR / "parse_release_metadata.py", scripts / "parse_release_metadata.py")
        (root / "version.env").write_text(
            "APP_NAME=RepoPrompt\nDISPLAY_NAME=\"RepoPrompt CE\"\nMARKETING_VERSION=1.0.0\nBUILD_NUMBER=1\n"
            f"BUNDLE_ID={bundle_id}\nSIGNING_TEAM_ID=648A27MST5\n",
            encoding="utf-8",
        )
        manifest = root / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("stale\n", encoding="utf-8")
        calls = temp_dir / "calls.log"
        gate_guard = '[[ -z "${RPCE_OPTIMIZED_DIAGNOSTICS+set}" && -z "${RPCE_OPTIMIZED_INCREMENTAL+set}" ]] || exit 42\n'
        stubs = {
            "doctor.sh": gate_guard + "exit 0\n",
            "patch_keyboard_shortcuts_resource_lookup.sh": (
                gate_guard
                + 'printf "patch%s\\n" "${REPOPROMPT_SWIFTPM_SCRATCH_PATH:+ $REPOPROMPT_SWIFTPM_SCRATCH_PATH}" >> "$STUB_CALLS"\n'
            ),
            "canonical_swift.sh": (
                gate_guard
                + 'printf "swift %s\\n" "$*" >> "$STUB_CALLS"\n'
                'for arg in "$@"; do\n'
                '    if [[ "$arg" == --show-bin-path ]]; then\n'
                '        [[ -L "$STUB_BIN_DIR" ]] || mkdir -p "$STUB_BIN_DIR"\n'
                '        printf "%s\\n" "$STUB_BIN_DIR"\n'
                "    fi\n"
                "done\n"
            ),
        }
        for name, body in stubs.items():
            stub = scripts / name
            stub.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
            stub.chmod(0o755)
        (scripts / "verify_build_lane_flags.py").write_text(
            "import os, sys\n"
            "open(os.environ['STUB_CALLS'], 'a').write('verify ' + ' '.join(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ['STUB_VERIFY_STATUS']))\n",
            encoding="utf-8",
        )
        (scripts / "debug_package_cache.py").write_text(
            "import os, sys\n"
            "open(os.environ['STUB_CALLS'], 'a').write('cache ' + sys.argv[1] + '\\n')\n"
            "sys.exit(9)\n",
            encoding="utf-8",
        )
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in {
                "SIGN_IDENTITY", "REPOPROMPT_ENABLE_SENTRY", "REPOPROMPT_UPLOAD_SENTRY_SYMBOLS", "VERBOSE", "BUNDLE_ID",
                "DEBUG_BUNDLE_ID", "APP_NAME", "DEBUG_SECURE_STORAGE_BACKEND", "REPOPROMPT_SWIFTPM_SCRATCH_PATH",
                "REPOPROMPT_DEBUG_PACKAGE_CACHE", "REPOPROMPT_DEBUG_APP_REUSE_SOURCE",
            }
            and not key.startswith(("LOCAL_SELF_SIGNED", "LOCAL_SIGNING", "ALLOW_ADHOC", "RELEASE_ALLOW"))
        }
        env.update(
            {
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "REPOPROMPT_DEBUG_APP_BUNDLE": str(temp_dir / "DebugApps" / "RepoPrompt.app"),
                "STUB_CALLS": str(calls),
                "STUB_BIN_DIR": str(root / ".build" / "optimized-diagnostics" / "arm64-apple-macosx" / "release"),
                "STUB_VERIFY_STATUS": "0",
                "SIGN_IDENTITY": "Apple Development: Stub",
                "RPCE_OPTIMIZED_DIAGNOSTICS": "1",
                "RPCE_OPTIMIZED_INCREMENTAL": "1",
                "PATH": self.install_empty_security_stub(temp_dir / "tools", temp_dir / "security.log")
                + ":"
                + os.environ["PATH"],
            }
        )
        return root, calls, env

    @staticmethod
    def install_empty_security_stub(tools: Path, log: Path) -> str:
        """An empty `security` on PATH: lane probes never read the host's signing-identity listing."""
        tools.mkdir(parents=True, exist_ok=True)
        stub = tools / "security"
        stub.write_text(f'#!/usr/bin/env bash\nprintf "security %s\\n" "$*" >> {shlex.quote(str(log))}\nexit 0\n',
                        encoding="utf-8")
        stub.chmod(0o755)
        return str(tools)

    @staticmethod
    def stub_calls(calls: Path) -> list[str]:
        return calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []

    def assert_reached_cache(self, result: subprocess.CompletedProcess) -> None:
        # The stub cache helper exits 9 at its first call (resolve-identity), which package_app.sh fails on.
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("debug_package_cache.py resolve-identity exited with status 9.", result.stderr)

    def test_package_app_rejects_unknown_configurations_before_any_mutation(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        validation = package_script.index(
            'case "$CONF" in\n    debug|debug-optimized|debug-optimized-incremental|release) ;;\n'
        )
        self.assertLess(package_script.index('case "$FAST_PACKAGE_MARKER" in'), validation)
        self.assertLess(validation, package_script.index('case "${REPOPROMPT_DEBUG_PACKAGE_CACHE-on}" in'))
        self.assertIn(
            'fail "Too many arguments. Usage: $0 [debug|debug-optimized|debug-optimized-incremental|release] [fast]"',
            package_script,
        )
        for conf in ("Debug", "debug-opt", "release-optimized", "optimized", "optimized-incremental",
                     "debug-incremental", "debug-optimized-incremental-app", "Debug-Optimized-Incremental"):
            with self.subTest(conf=conf):
                root, calls, env = self.make_optimized_lane_stub_root()
                result = subprocess.run(
                    [str(SCRIPT_DIR / "package_app.sh"), conf], env=env, text=True, capture_output=True
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"Unknown configuration '{conf}'. Usage: ", result.stderr)
                self.assertIn("[debug|debug-optimized|debug-optimized-incremental|release] [fast]", result.stderr)
                self.assertNotIn("Loading release metadata", result.stdout)
                self.assertTrue((root / ".build" / "release" / "RepoPrompt-artifact-manifest.json").exists())
                self.assertEqual(self.stub_calls(calls), [])

    def test_optimized_lane_preconditions_fail_before_any_build(self) -> None:
        cases = {
            "no identity, auto-detect allowed": ({"PREFER_STABLE_DEBUG_SIGNING": "1"}, ["SIGN_IDENTITY"],
                                                 "requires an explicit SIGN_IDENTITY"),
            "no identity, ad-hoc allowed": ({"ALLOW_ADHOC_SIGNING": "1"}, ["SIGN_IDENTITY"],
                                            "requires an explicit SIGN_IDENTITY"),
            "empty identity": ({"SIGN_IDENTITY": ""}, [], "requires an explicit SIGN_IDENTITY"),
            "ad-hoc identity": ({"SIGN_IDENTITY": "-", "ALLOW_ADHOC_SIGNING": "1"}, [],
                                "does not support ad-hoc signing"),
            "developer id": ({"SIGN_IDENTITY": "Developer ID Application: Stub (648A27MST5)"}, [],
                             "begin with 'Apple Development:'"),
            "lowercase prefix": ({"SIGN_IDENTITY": "apple development: Stub"}, [], "begin with 'Apple Development:'"),
            "bundle id override": ({"BUNDLE_ID": "com.pvncher.repoprompt.ce"}, [], "unset BUNDLE_ID and DEBUG_BUNDLE_ID"),
            "debug bundle id override": ({"DEBUG_BUNDLE_ID": "com.pvncher.repoprompt.ce.debug"}, [],
                                         "unset BUNDLE_ID and DEBUG_BUNDLE_ID"),
            "sentry linking": ({"REPOPROMPT_ENABLE_SENTRY": "1"}, [], "does not support Sentry"),
            "sentry linking empty": ({"REPOPROMPT_ENABLE_SENTRY": ""}, [], "does not support Sentry"),
            "sentry upload": ({"REPOPROMPT_UPLOAD_SENTRY_SYMBOLS": "0"}, [], "does not support Sentry"),
        }
        # The optimized-incremental App lane takes the same preconditions under its own name.
        for conf in ("debug-optimized", "debug-optimized-incremental"):
            for name, (extra_env, removed, message) in cases.items():
                with self.subTest(conf=conf, case=name):
                    root, calls, env = self.make_optimized_lane_stub_root()
                    env.update(extra_env)
                    for key in removed:
                        env.pop(key, None)
                    result = subprocess.run(
                        [str(SCRIPT_DIR / "package_app.sh"), conf], env=env, text=True, capture_output=True
                    )
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(f"ERROR: {conf} ", result.stderr)
                    self.assertIn(message, result.stderr)
                    # Environment preconditions run before metadata, manifest removal, doctor or any build.
                    self.assertNotIn("Loading release metadata", result.stdout)
                    self.assertTrue((root / ".build" / "release" / "RepoPrompt-artifact-manifest.json").exists())
                    self.assertEqual(self.stub_calls(calls), [])
                    self.assertNotIn("OPTIMIZED DIAGNOSTICS LANE", result.stdout)
                    self.assertNotIn("OPTIMIZED INCREMENTAL APP LANE", result.stdout)
            # A metadata bundle ID that does not resolve to the debug bundle ID fails before any build.
            with self.subTest(conf=conf, case="metadata bundle id"):
                root, calls, env = self.make_optimized_lane_stub_root(bundle_id="com.example.other")
                result = subprocess.run(
                    [str(SCRIPT_DIR / "package_app.sh"), conf], env=env, text=True, capture_output=True
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"{conf} requires the debug bundle ID com.pvncher.repoprompt.ce.debug; "
                              "resolved 'com.example.other.debug'", result.stderr)
                self.assertNotIn("Checking build environment", result.stdout)
                self.assertEqual(self.stub_calls(calls), [])
        # The plain debug lane keeps today's rules: ad-hoc, overrides and Sentry stay its own business.
        root, calls, env = self.make_optimized_lane_stub_root()
        env.pop("SIGN_IDENTITY")
        env.update({"ALLOW_ADHOC_SIGNING": "1", "PREFER_STABLE_DEBUG_SIGNING": "0", "DEBUG_BUNDLE_ID": "com.example.dbg"})
        result = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), "debug"], env=env, text=True, capture_output=True)
        self.assert_reached_cache(result)
        self.assertEqual(self.stub_calls(calls), ["patch", "swift build -c debug", "swift build -c debug --show-bin-path",
                                                  "cache resolve-identity"])

    def test_optimized_lane_verifier_runs_before_the_cache_and_any_failure_aborts(self) -> None:
        lane_calls = [
            "swift --rpce-optimized-diagnostics build -c release",
            "swift --rpce-optimized-diagnostics build -c release --show-bin-path",
        ]
        for status in (0, 1, 2, 3):
            with self.subTest(verify_status=status):
                root, calls, env = self.make_optimized_lane_stub_root()
                env["STUB_VERIFY_STATUS"] = str(status)
                result = subprocess.run(
                    [str(SCRIPT_DIR / "package_app.sh"), "debug-optimized"], env=env, text=True, capture_output=True
                )
                scratch = (root / ".build" / "optimized-diagnostics").resolve()
                verify = f"verify --build-yaml {scratch / 'release.yaml'}"
                expected = [f"patch {root / '.build' / 'optimized-diagnostics'}", *lane_calls, verify]
                self.assertIn(f"COMPAT_APP_BUNDLE={root / '.build' / 'debug' / 'RepoPrompt.app'}\n", result.stdout)
                self.assertIn('[package-timing] phase="Verifying optimized-diagnostics lane flags"', result.stdout)
                if status == 0:
                    # Verification passed; the next step is the cache (stubbed to stop here).
                    self.assert_reached_cache(result)
                    self.assertEqual(self.stub_calls(calls), [*expected, "cache resolve-identity"])
                else:
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(self.stub_calls(calls), expected)
                    self.assertIn(f"verify_build_lane_flags.py exited with status {status};", result.stderr)
                    self.assertNotIn("Computing debug package keys", result.stdout)
                self.assertFalse(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]).exists())
                self.assertFalse(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]).parent.exists())
        # The optimized-incremental App lane verifies its own scratch plan under its own contract.
        incremental_calls = [
            "swift --rpce-optimized-incremental build -c release",
            "swift --rpce-optimized-incremental build -c release --show-bin-path",
        ]
        for status in (0, 1, 2):
            with self.subTest(lane="debug-optimized-incremental", verify_status=status):
                root, calls, env = self.make_optimized_lane_stub_root()
                env["STUB_VERIFY_STATUS"] = str(status)
                env["STUB_BIN_DIR"] = str(root / ".build" / "optimized-incremental" / "arm64-apple-macosx" / "release")
                result = subprocess.run(
                    [str(SCRIPT_DIR / "package_app.sh"), "debug-optimized-incremental"],
                    env=env, text=True, capture_output=True,
                )
                scratch = (root / ".build" / "optimized-incremental").resolve()
                verify = f"verify --build-yaml {scratch / 'release.yaml'} --lane optimized-incremental"
                expected = [f"patch {root / '.build' / 'optimized-incremental'}", *incremental_calls, verify]
                self.assertIn(f"COMPAT_APP_BUNDLE={root / '.build' / 'debug' / 'RepoPrompt.app'}\n", result.stdout)
                self.assertIn('[package-timing] phase="Verifying optimized-incremental lane flags"', result.stdout)
                self.assertFalse((root / ".build" / "optimized-diagnostics").exists())
                if status == 0:
                    self.assert_reached_cache(result)
                    self.assertEqual(self.stub_calls(calls), [*expected, "cache resolve-identity"])
                else:
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(self.stub_calls(calls), expected)
                    self.assertIn(f"verify_build_lane_flags.py exited with status {status}; the build plan does not "
                                  "prove the optimized-incremental lane flags.", result.stderr)
                    self.assertNotIn("Computing debug package keys", result.stdout)
        # The plain debug lane never runs the verifier.
        root, calls, env = self.make_optimized_lane_stub_root()
        env.pop("SIGN_IDENTITY")
        env.update({"ALLOW_ADHOC_SIGNING": "1", "PREFER_STABLE_DEBUG_SIGNING": "0", "STUB_VERIFY_STATUS": "1",
                    "STUB_BIN_DIR": str(root / ".build" / "arm64-apple-macosx" / "debug")})
        result = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), "debug"], env=env, text=True, capture_output=True)
        self.assert_reached_cache(result)
        self.assertNotIn("verify", " ".join(self.stub_calls(calls)))
        self.assertIn(f"COMPAT_APP_BUNDLE={root / '.build' / 'debug' / 'RepoPrompt.app'}\n", result.stdout)

    def test_optimized_lane_requires_the_canonical_build_dir_under_its_scratch(self) -> None:
        outside = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, outside, True)
        (outside / "triple" / "release").mkdir(parents=True)
        outside_scratch = "debug-optimized BUILD_DIR must lie under "
        wrong_depth = "debug-optimized BUILD_DIR must be <scratch>/<triple>/release under "
        cases = {
            "shared debug tree": (lambda root: root / ".build" / "arm64-apple-macosx" / "debug", outside_scratch),
            "shared release tree": (lambda root: root / ".build" / "arm64-apple-macosx" / "release", outside_scratch),
            "too shallow": (lambda root: root / ".build" / "optimized-diagnostics" / "release", wrong_depth),
            "too deep": (lambda root: root / ".build" / "optimized-diagnostics" / "a" / "b" / "release", wrong_depth),
            "lookalike prefix": (
                lambda root: root / ".build" / "optimized-diagnostics-x" / "triple" / "release", outside_scratch
            ),
            # Textually under the scratch, canonically outside it.
            "symlink escape": (
                lambda root: root / ".build" / "optimized-diagnostics" / "escape" / "release", outside_scratch
            ),
        }
        for name, (bin_dir, message) in cases.items():
            with self.subTest(case=name):
                root, calls, env = self.make_optimized_lane_stub_root()
                (root / ".build" / "optimized-diagnostics").mkdir(parents=True, exist_ok=True)
                target = bin_dir(root)
                if name == "symlink escape":
                    target.parent.mkdir(parents=True)
                    target.symlink_to(outside / "triple" / "release")
                env["STUB_BIN_DIR"] = str(target)
                result = subprocess.run(
                    [str(SCRIPT_DIR / "package_app.sh"), "debug-optimized"], env=env, text=True, capture_output=True
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                calls_seen = self.stub_calls(calls)
                self.assertFalse([call for call in calls_seen if call.startswith(("verify", "cache"))], calls_seen)
        # A symlinked bin path that canonicalizes to <scratch>/<triple>/release is accepted.
        root, calls, env = self.make_optimized_lane_stub_root()
        real = root / ".build" / "optimized-diagnostics" / "arm64-apple-macosx" / "release"
        real.mkdir(parents=True)
        alias = root / ".build" / "optimized-diagnostics" / "release"
        alias.symlink_to("arm64-apple-macosx/release")
        env["STUB_BIN_DIR"] = str(alias)
        result = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug-optimized"], env=env, text=True, capture_output=True
        )
        self.assert_reached_cache(result)
        scratch = (root / ".build" / "optimized-diagnostics").resolve()
        self.assertEqual(self.stub_calls(calls)[-2:], [f"verify --build-yaml {scratch / 'release.yaml'}", "cache resolve-identity"])
        # Each optimized lane accepts only its own scratch tree: never the other lane's plan.
        for conf, own, other in (
            ("debug-optimized", "optimized-diagnostics", "optimized-incremental"),
            ("debug-optimized-incremental", "optimized-incremental", "optimized-diagnostics"),
        ):
            with self.subTest(conf=conf, bin_dir=other):
                root, calls, env = self.make_optimized_lane_stub_root()
                (root / ".build" / own).mkdir(parents=True, exist_ok=True)
                env["STUB_BIN_DIR"] = str(root / ".build" / other / "arm64-apple-macosx" / "release")
                result = subprocess.run([str(SCRIPT_DIR / "package_app.sh"), conf], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"{conf} BUILD_DIR must lie under {root / '.build' / own};", result.stderr)
                self.assertFalse([call for call in self.stub_calls(calls) if call.startswith(("verify", "cache"))])

    def test_optimized_lane_verifier_is_ordered_before_the_plan_and_outside_reuse(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        start = package_script.index("if (( IS_OPTIMIZED_LANE )); then\n    phase \"Verifying $LANE_VERIFY_LABEL lane flags\"\n")
        block = package_script[start:].split("\nfi\n", 1)[0]
        # Isolated interpreter (-I -S), like the other control-plane Python helpers. The lane argument
        # list is empty for debug-optimized (its verifier argv is unchanged) and --lane for the App lane.
        lane_args = '${LANE_VERIFY_ARGS[@]+"${LANE_VERIFY_ARGS[@]}"}'
        executed = (
            '    python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/verify_build_lane_flags.py" --build-yaml "$LANE_BUILD_YAML" '
            + lane_args + ' || LANE_VERIFY_STATUS=$?\n'
        )
        echoed = (
            '    echo_cmd python3 -I -S "$CONTROL_PLANE_SCRIPTS_DIR/verify_build_lane_flags.py" --build-yaml "$LANE_BUILD_YAML" '
            + lane_args + '\n'
        )
        self.assertIn(echoed, block + "\n")
        self.assertEqual(package_script.count("python3 -I -S \"$CONTROL_PLANE_SCRIPTS_DIR/verify_build_lane_flags.py\""), 2)
        self.assertEqual(package_script.count("verify_build_lane_flags.py\" --build-yaml"), 2)  # echo and call
        self.assertIn(executed, block + "\n")
        self.assertIn("    (( LANE_VERIFY_STATUS == 0 )) ||\n        fail ", block)
        self.assertIn('    LANE_BUILD_YAML="$LANE_BUILD_PLAN_DIR/release.yaml"\n', block)
        self.assertIn('[[ "$LANE_BUILD_DIR_CANONICAL" == "$LANE_SCRATCH_CANONICAL/"* ]]', block)
        self.assertLess(block.index('[[ "$LANE_BUILD_PLAN_DIR" == "$LANE_SCRATCH_CANONICAL" ]]'), block.index(executed.strip()))
        self.assertLess(block.index(executed.strip()), block.index("LANE_FLAGS_VERIFIED=1"))
        for reuse_state in ("DEBUG_PACKAGE_REUSED", "DEBUG_PACKAGE_OUTCOME", "debug_package_cache.py"):
            self.assertNotIn(reuse_state, block)
        # Top level (column 0), after the BUILD_DIR printout, before the keys phase and every reuse decision.
        self.assertEqual(package_script.count("\nif (( IS_OPTIMIZED_LANE )); then\n    phase \"Verifying"), 1)
        self.assertLess(package_script.index("printf 'BUILD_DIR=%s"), start)
        self.assertLess(start, package_script.index('phase "Computing debug package keys"'))
        self.assertLess(start, package_script.index('debug_package_cache.py" plan'))
        self.assertLess(start, package_script.index("noop-dest|noop-clone) DEBUG_PACKAGE_REUSED=1 ;;"))
        self.assertEqual(package_script.count("LANE_FLAGS_VERIFIED=1"), 1)

    def test_optimized_lane_derived_variables_keep_debug_and_release_values(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        derived = package_script.split('IS_RELEASE=0\n[[ "$CONF" == "release" ]] && IS_RELEASE=1\n', 1)[1].split(
            "\nif (( FAST_PACKAGE_REQUESTED )); then", 1
        )[0]
        probe = (
            "set -euo pipefail\nROOT_DIR=/repo\n"
            'for CONF in debug debug-optimized debug-optimized-incremental release; do\nIS_RELEASE=0\n'
            '[[ "$CONF" == "release" ]] && IS_RELEASE=1\n'
            + derived
            + '\nprintf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n" "$CONF" "$BUILD_LANE" "$SWIFT_CONF" '
            '"${CANONICAL_PREFIX[*]+${CANONICAL_PREFIX[*]}}" "$IS_RELEASE" "$COMPAT_CONF" "$IS_OPTIMIZED_LANE" '
            '"$OPTIMIZED_SCRATCH_DIR" "${LANE_VERIFY_ARGS[*]+${LANE_VERIFY_ARGS[*]}}" "$LANE_VERIFY_LABEL"\ndone\n'
        )
        for shell in ("bash", "/bin/bash"):
            with self.subTest(shell=shell):
                result = subprocess.run([shell, "-c", probe], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.splitlines(),
                    [
                        "debug|debug|debug||0|debug|0|/repo/.build/optimized-diagnostics||optimized-diagnostics",
                        "debug-optimized|debug-optimized|release|--rpce-optimized-diagnostics|0|debug|1"
                        "|/repo/.build/optimized-diagnostics||optimized-diagnostics",
                        "debug-optimized-incremental|debug-optimized-incremental|release|--rpce-optimized-incremental"
                        "|0|debug|1|/repo/.build/optimized-incremental|--lane optimized-incremental|optimized-incremental",
                        "release|release|release||1|release|0|/repo/.build/optimized-diagnostics||optimized-diagnostics",
                    ],
                )
        self.assertIn('SWIFT_BUILD_ARGS=(-c "$SWIFT_CONF")\n', package_script)
        self.assertIn('COMPAT_APP_BUNDLE="$ROOT_DIR/.build/$COMPAT_CONF/$APP_NAME.app"\n', package_script)
        self.assertIn('OPTIMIZED_SCRATCH_DIR="$ROOT_DIR/.build/optimized-diagnostics"\n', package_script)
        # The lane patches its own dependency checkout; the default lanes keep today's call.
        patch = package_script.split('phase "Patching KeyboardShortcuts resource lookup"\n', 1)[1].split("\n    fi\n", 1)[0]
        self.assertIn(
            '        run env REPOPROMPT_SWIFTPM_SCRATCH_PATH="$OPTIMIZED_SCRATCH_DIR" \\\n'
            '            "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh" "$ROOT_DIR"\n',
            patch,
        )
        self.assertIn('    else\n    run "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh" "$ROOT_DIR"', patch)

    def test_gate_is_unset_at_top_level_in_package_app_and_release_builder(self) -> None:
        for name in ("package_app.sh", "build_swiftpm_release_products.sh"):
            with self.subTest(script=name):
                lines = (SCRIPT_DIR / name).read_text(encoding="utf-8").splitlines()
                unsets = [index for index, line in enumerate(lines) if line.startswith("unset RPCE_OPTIMIZED_DIAGNOSTICS")]
                self.assertEqual(len(unsets), 1)
                self.assertEqual(
                    lines[unsets[0]].split("#", 1)[0].split(),
                    ["unset", "RPCE_OPTIMIZED_DIAGNOSTICS", "RPCE_OPTIMIZED_INCREMENTAL"],
                )
                code_before = [
                    line for line in lines[: unsets[0]] if line.strip() and not line.lstrip().startswith("#")
                ]
                # Only the shebang, comments and `set -euo pipefail` precede it.
                self.assertEqual(code_before, ["set -euo pipefail"], name)

    def test_debug_provenance_adds_build_lane_keys_only_for_fresh_bundles(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        launch = (
            '    BUILD_LANE_FOR_PROVENANCE="$BUILD_LANE" LANE_FLAGS_VERIFIED_FOR_PROVENANCE="$LANE_FLAGS_VERIFIED" \\\n'
            '    ROOT_DIR_FOR_PROVENANCE="$ROOT_DIR" APP_BUNDLE_FOR_PROVENANCE="$APP_BUNDLE" '
            'GIT_STATE_FOR_PROVENANCE="$DEBUG_PACKAGE_GIT_STATE" python3 - <<\'PY\'\n'
        )
        self.assertEqual(package_script.count(launch), 1)
        reuse_gate = package_script.rindex("    if (( ! DEBUG_PACKAGE_REUSED )); then\n", 0, package_script.index(launch))
        self.assertNotIn("\n    fi\n", package_script[reuse_gate:package_script.index(launch)])
        writer = package_script.split(launch, 1)[1].split("\nPY\n", 1)[0]
        common = {"version", "repoRoot", "worktreePath", "worktreeName", "branch", "commit", "dirty", "buildTimeEpoch",
                  "buildTimeISO"}
        expected = {
            ("debug", "0"): {"buildLane": "debug", "swiftConfiguration": "debug", "optimization": "Onone",
                             "assertConfiguration": "Debug", "laneFlagsVerified": None},
            ("debug-optimized", "1"): {"buildLane": "debug-optimized", "swiftConfiguration": "release",
                                       "optimization": "O", "assertConfiguration": "Release", "laneFlagsVerified": True},
            ("debug-optimized", "0"): None,
            ("debug-optimized-incremental", "1"): {
                "buildLane": "debug-optimized-incremental", "swiftConfiguration": "release", "optimization": "O",
                "assertConfiguration": "Release", "laneFlagsVerified": True,
            },
            ("debug-optimized-incremental", "0"): None,
            ("release", "0"): None,
        }
        for (lane, verified), labels in expected.items():
            with self.subTest(lane=lane, verified=verified), tempfile.TemporaryDirectory() as tmp:
                bundle = Path(tmp) / "RepoPrompt.app"
                (bundle / "Contents" / "Resources").mkdir(parents=True)
                env = dict(
                    os.environ,
                    BUILD_LANE_FOR_PROVENANCE=lane,
                    LANE_FLAGS_VERIFIED_FOR_PROVENANCE=verified,
                    ROOT_DIR_FOR_PROVENANCE=tmp,
                    APP_BUNDLE_FOR_PROVENANCE=str(bundle),
                    GIT_STATE_FOR_PROVENANCE=json.dumps({"branch": "main", "commit": "a" * 40, "dirty": False}),
                )
                result = subprocess.run([sys.executable, "-"], input=writer, text=True, env=env, capture_output=True)
                path = bundle / "Contents" / "Resources" / "RepoPromptDebugProvenance.json"
                if labels is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ERROR:", result.stderr)
                    self.assertFalse(path.exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(set(payload), common | set(labels))
                self.assertEqual(payload["version"], 1)
                self.assertEqual({key: payload[key] for key in labels}, labels)

    def test_runtime_bundle_verifier_is_removed_without_changing_sparkle_or_anti_debug_startup(self) -> None:
        app_delegate = (SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "AppDelegate.swift").read_text(
            encoding="utf-8"
        )
        application_security = (
            SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "ApplicationSecurity.swift"
        ).read_text(encoding="utf-8")
        sparkle_manager = (
            SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "Sparkle" / "SparkleUpdateManager.swift"
        ).read_text(encoding="utf-8")
        security_root = SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "Infrastructure" / "Security"
        runtime_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (SCRIPT_DIR.parent / "Sources" / "RepoPrompt").rglob("*.swift")
        )

        self.assertNotIn("BundleVerificationService", app_delegate)
        self.assertNotIn("Application integrity check failed", app_delegate)
        self.assertFalse((security_root / "BundleVerificationService.swift").exists())
        self.assertFalse((security_root / "BundleVerifier.swift").exists())
        self.assertEqual(app_delegate.count("sparkleManager.startUpdater()"), 2)
        self.assertIn("ApplicationSecurity.startMonitoring()", app_delegate)
        self.assertIn("ApplicationSecurity.enableAntiDebugging()", app_delegate)
        self.assertNotIn("BundleVerifier", application_security)
        self.assertNotIn("verifyBundleSignature", application_security)
        self.assertNotIn("SecStaticCodeCheckValidity", application_security)
        self.assertNotIn("BundleVerifier.verifyBundleSignature", runtime_sources)
        manager_init = sparkle_manager.split("init(updaterController: SPUStandardUpdaterController) {", 1)[1].split(
            "\n    func startUpdater()", 1
        )[0]
        self.assertNotIn("updaterController.startUpdater()", manager_init)
        self.assertIn("guard sparkleConfigurationValid, !updaterStarted else { return }", sparkle_manager)
        self.assertIn(
            "guard updaterStarted, sparkleConfigurationValid, activeUserInitiatedChannel == nil else {",
            sparkle_manager,
        )

    def test_ci_secret_scan_covers_introduced_commit_range_and_checked_out_tree(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn('gitleaks git --redact --log-opts="$range" .', workflow)
        self.assertIn("gitleaks dir --redact .", workflow)

    def test_swift_style_lint_uses_config_discovery_without_script_input_overhead(self) -> None:
        root = SCRIPT_DIR.parent
        style_script = (SCRIPT_DIR / "swift_style.sh").read_text(encoding="utf-8")
        swiftlint_config = (root / ".swiftlint.yml").read_text(encoding="utf-8")
        lint_body = style_script.split("run_swiftlint(){", 1)[1].split("\n}", 1)[0]

        self.assertIn('local args=(lint --strict --config "$ROOT_DIR/.swiftlint.yml" --quiet --force-exclude)', lint_body)
        self.assertNotIn("SCRIPT_INPUT_FILE", lint_body)
        self.assertNotIn("--use-script-input-files", lint_body)

        style_paths_body = style_script.split("STYLE_PATHS=(", 1)[1].split("\n)", 1)[0]
        style_paths = [
            line.strip().strip('"')
            for line in style_paths_body.splitlines()
            if line.strip().startswith('"')
        ]
        for style_path in style_paths:
            self.assertIn(f"  - {style_path}", swiftlint_config)

        for excluded_path in (
            ".build",
            ".swiftpm",
            "build",
            "Carthage",
            "DerivedData",
            "Generated",
            "Pods",
            "Vendor",
            "Packages/RepoPromptAgentProviders/.build",
            "Sources/CSwiftPCRE2",
            "Sources/RepoPromptC",
            "Sources/RepoPromptPlatform/ThirdParty/SwiftPCRE2",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPromptSharedFragments.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Build.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+DeepPlan.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Investigate.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Optimize.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+OracleExport.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Orchestrate.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Refactor.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Reminder.swift",
            "Sources/RepoPromptAgentCore/AI/Prompts/Workflows/WorkflowPrompt+Review.swift",
        ):
            self.assertIn(f"  - {excluded_path}", swiftlint_config)

    def test_publish_staged_validates_before_creating_dist(self) -> None:
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        publish_staged = release_script.split("publish_staged_release() {", 1)[1].split("\n}", 1)[0]

        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"'),
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
        )
        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
            publish_staged.index("prepare_dist"),
        )


    def test_main_tip_workflow_keeps_tip_separate_and_uses_hardened_smoke(self) -> None:
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")

        self.assertIn("name: Publish Tip", tip_workflow)
        self.assertIn("group: main-tip-channel", tip_workflow)
        self.assertIn("should-publish", tip_workflow)
        self.assertIn("stable-appcast.xml", tip_workflow)
        self.assertIn('build_number="$stable_build_number.$((build_sequence / 100)).$((build_sequence % 100))"', tip_workflow)
        self.assertIn("environment: tip-release", tip_workflow)
        self.assertIn("TIP_UPDATE_REPOSITORY_TOKEN", tip_workflow)
        self.assertIn("repoprompt-ce-tip-updates", tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"', tip_workflow)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            tip_workflow,
        )
        self.assertIn("Check out approved tip source as data", tip_workflow)
        self.assertIn("extract_staged_release.py", tip_workflow)
        self.assertIn("RELEASE_COMMIT: ${{ needs.setup.outputs.commit }}", tip_workflow)
        self.assertIn("REPOPROMPT_APPROVED_SOURCE_ROOT: ${{ github.workspace }}/approved-source", tip_workflow)
        self.assertIn("REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE: ${{ needs.setup.outputs.build-number }}", tip_workflow)
        self.assertIn("tip-source/dist/*-metadata.json", tip_workflow)
        self.assertNotIn("stable-release-channel", tip_workflow)
        self.assertNotIn("release-draft-creation", tip_workflow)
        self.assertNotIn("PUBLIC_UPDATE_REPOSITORY_TOKEN", tip_workflow)

        self.assertIn('TIP_BUILD_NUMBER="$BUILD_NUMBER.$((TIP_BUILD_SEQUENCE / 100)).$((TIP_BUILD_SEQUENCE % 100))"', tip_script)
        self.assertLess(
            tip_script.index('if [[ -z "${TIP_BUILD_NUMBER:-}" ]]'),
            tip_script.index('git rev-list --count "$TIP_COMMIT"'),
        )
        self.assertIn('TIP_TAG="${TIP_TAG:-tip-$TIP_SHORT_SHA}"', tip_script)
        self.assertIn('TIP_UPDATE_REPOSITORY="${TIP_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-tip-updates}"', tip_script)
        self.assertNotIn("--prerelease", tip_script)
        self.assertIn("--latest", tip_script)
        self.assertIn("--target main", tip_script)
        self.assertIn('fail "TIP_UPDATE_REPOSITORY must not target the source or stable update repository"', tip_script)
        self.assertIn('REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER"', tip_script)
        self.assertEqual(tip_script.count('REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER"'), 3)
        self.assertNotIn('BUILD_NUMBER="$TIP_BUILD_NUMBER"', tip_script)
        self.assertIn("stage|sign|publish-tip", tip_script)

        sign_tip = tip_script.split("sign_tip() {", 1)[1].split("\n}", 1)[0]
        generate_appcast = sign_tip.index('"$TRUSTED_ROOT/Vendor/Sparkle/bin/generate_appcast"')
        validate_appcast = sign_tip.index("validate_generated_tip_appcast")
        write_checksums = sign_tip.index('shasum -a 256', validate_appcast)
        self.assertLess(generate_appcast, validate_appcast)
        self.assertLess(validate_appcast, write_checksums)
        self.assertIn('fail "Tip appcast enclosure is missing an EdDSA signature"', tip_script)
        self.assertIn('fail "Tip Sparkle private key does not match the app bundle SUPublicEDKey"', tip_script)
        self.assertIn('fail "Tip Sparkle private key does not reproduce the generated appcast signature"', tip_script)
        self.assertIn('"$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"', tip_script)

        capture_override = package_script.index(
            'RELEASE_BUILD_NUMBER_OVERRIDE="${REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE:-}"'
        )
        load_metadata = package_script.index('load_release_metadata "$ROOT_DIR"')
        apply_override = package_script.index('BUILD_NUMBER="$RELEASE_BUILD_NUMBER_OVERRIDE"')
        self.assertLess(capture_override, load_metadata)
        self.assertLess(load_metadata, apply_override)
        self.assertIn(
            'fail "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE must be a valid numeric build version"',
            package_script,
        )

    def test_main_tip_setup_uses_anonymous_release_lookup_helper(self) -> None:
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        setup_job = tip_workflow.split("\n  setup:", 1)[1].split("\n  stage:", 1)[0]
        before_publish, publish_job = tip_workflow.split("\n  publish:", 1)

        self.assertIn("permissions:\n  contents: read", tip_workflow)
        self.assertIn("./Scripts/lookup_public_tip_release.sh", setup_job)
        self.assertNotIn("GITHUB_TOKEN", setup_job)
        self.assertNotIn("Authorization:", setup_job)
        self.assertNotIn("api.github.com", setup_job)
        self.assertNotIn("TIP_UPDATE_REPOSITORY_TOKEN", before_publish)
        self.assertIn("TIP_GH_TOKEN: ${{ secrets.TIP_UPDATE_REPOSITORY_TOKEN }}", publish_job)
        self.assertEqual(tip_workflow.count("TIP_UPDATE_REPOSITORY_TOKEN"), 1)

    def test_public_tip_release_lookup_helper_handles_github_outcomes_safely(self) -> None:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        tools = root / "tools"
        tools.mkdir()
        calls = root / "curl-calls"
        archive_basename = "RepoPrompt-tip-fixture-1.2.3"
        fake_curl = tools / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]

def option(name):
    return args[args.index(name) + 1]

request_headers = [args[index + 1] for index, value in enumerate(args) if value == "--header"]
if any(header.lower().startswith("authorization:") for header in request_headers):
    raise SystemExit(90)
if any(option_name in args for option_name in ("--user", "--netrc", "--netrc-file", "-u")):
    raise SystemExit(91)
if "Accept: application/vnd.github+json" not in request_headers:
    raise SystemExit(92)
if "X-GitHub-Api-Version: 2022-11-28" not in request_headers:
    raise SystemExit(93)
if option("--connect-timeout") != "10" or option("--max-time") != "30":
    raise SystemExit(94)

calls = Path(os.environ["FAKE_CURL_CALLS"])
with calls.open("a", encoding="utf-8") as handle:
    handle.write("call\\n")

scenario = os.environ["FAKE_GITHUB_SCENARIO"]
if scenario == "transport":
    raise SystemExit(7)

status = {
    "found": 200,
    "absent": 404,
    "rate-403-primary": 403,
    "rate-403-secondary": 403,
    "rate-429": 429,
    "server": 503,
    "unexpected-403": 403,
    "redirect-final-unexpected-403": 403,
    "malformed": 200,
    "malformed-flags": 200,
}[scenario]
remaining = "0" if scenario in {"rate-403-primary", "rate-429"} else "42"
headers = [
    f"HTTP/1.1 {status} Fixture",
    "X-GitHub-Request-Id: fixture-request",
    f"X-RateLimit-Remaining: {remaining}",
    "X-RateLimit-Reset: 1234567890",
]
if scenario in {"rate-403-primary", "rate-429"}:
    headers.append("Retry-After: 0")
if scenario == "redirect-final-unexpected-403":
    headers = [
        "HTTP/1.1 302 Fixture",
        "X-GitHub-Request-Id: intermediate-request",
        "X-RateLimit-Remaining: 0",
        "X-RateLimit-Reset: 1111111111",
        "Retry-After: 30",
        "",
        "HTTP/2 403 Fixture",
        "X-GitHub-Request-Id: final-request",
    ]
Path(option("--dump-header")).write_text("\\r\\n".join(headers) + "\\r\\n\\r\\n", encoding="utf-8")

archive = os.environ["FAKE_ARCHIVE_BASENAME"]
expected = [
    f"{archive}.zip",
    f"{archive}.dmg",
    "appcast.xml",
    "SHA256SUMS",
    f"{archive}-artifact-manifest.json",
    f"{archive}-metadata.json",
]
if scenario == "found":
    body = {"draft": False, "prerelease": False, "assets": [{"name": name} for name in expected]}
elif scenario == "rate-403-secondary":
    body = {"message": "You have exceeded a secondary rate limit. SECRET_BODY_MARKER"}
elif scenario in {"unexpected-403", "redirect-final-unexpected-403"}:
    body = {"message": "Resource not accessible by integration. SECRET_BODY_MARKER"}
elif scenario == "malformed":
    body = []
elif scenario == "malformed-flags":
    body = {"assets": [{"name": name} for name in expected]}
else:
    body = {"message": "SECRET_BODY_MARKER"}
Path(option("--output")).write_text(json.dumps(body), encoding="utf-8")
sys.stdout.write(str(status))
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        fake_sleep = tools / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_sleep.chmod(0o755)

        scenarios = (
            ("found", 0, "found", 1, "found"),
            ("absent", 0, "not-found", 1, "not-found"),
            ("rate-403-primary", 1, "", 3, "rate-limited"),
            ("rate-403-secondary", 1, "", 3, "rate-limited"),
            ("rate-429", 1, "", 3, "rate-limited"),
            ("server", 1, "", 3, "server-failure"),
            ("transport", 1, "", 3, "transport-failure"),
            ("unexpected-403", 1, "", 1, "unexpected-failure"),
            ("redirect-final-unexpected-403", 1, "", 1, "unexpected-failure"),
            ("malformed", 1, "", 1, "malformed"),
            ("malformed-flags", 1, "", 1, "malformed"),
        )
        helper = SCRIPT_DIR / "lookup_public_tip_release.sh"
        for scenario, returncode, stdout, attempt_count, classification in scenarios:
            with self.subTest(scenario=scenario):
                calls.unlink(missing_ok=True)
                env = os.environ.copy()
                env.update(
                    {
                        "PATH": f"{tools}:{env['PATH']}",
                        "TMPDIR": str(root),
                        "FAKE_CURL_CALLS": str(calls),
                        "FAKE_GITHUB_SCENARIO": scenario,
                        "FAKE_ARCHIVE_BASENAME": archive_basename,
                    }
                )
                result = subprocess.run(
                    [str(helper), "example/public-tip", "tip-fixture", archive_basename],
                    env=env,
                    text=True,
                    capture_output=True,
                )

                self.assertEqual(result.returncode, returncode, result.stderr)
                self.assertEqual(result.stdout.strip(), stdout)
                self.assertEqual(len(calls.read_text(encoding="utf-8").splitlines()), attempt_count)
                self.assertIn(f"classification={classification}", result.stderr)
                self.assertNotIn("SECRET_BODY_MARKER", result.stdout + result.stderr)
                if scenario == "redirect-final-unexpected-403":
                    self.assertNotIn("classification=rate-limited", result.stderr)
                    self.assertIn(
                        "request_id=final-request rate_limit_remaining=unavailable "
                        "rate_limit_reset=unavailable retry_after=unavailable",
                        result.stderr,
                    )
                for diagnostic in result.stderr.splitlines():
                    self.assertRegex(
                        diagnostic,
                        r"^GitHub public tip lookup classification=[a-z-]+ status=[0-9]{3} "
                        r"request_id=[^ ]+ rate_limit_remaining=[^ ]+ rate_limit_reset=[^ ]+ "
                        r"retry_after=[^ ]+$",
                    )

    def test_generated_tip_appcast_validation_executes_crypto_and_rejects_missing_signature(self) -> None:
        root = SCRIPT_DIR.parent
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app_bundle = temp_dir / "RepoPrompt.app"
        info_plist = app_bundle / "Contents" / "Info.plist"
        archive = temp_dir / "RepoPrompt-tip-fixture.zip"
        appcast = temp_dir / "appcast.xml"
        private_key_file = temp_dir / "private-key"
        validator_tmp_dir = temp_dir / "validator-tmp"
        info_plist.parent.mkdir(parents=True)
        archive.write_text("signed tip archive\n", encoding="utf-8")
        private_key = base64.b64encode(bytes(range(32))).decode("ascii")
        private_key_file.write_text(private_key, encoding="utf-8")
        public_key = self.run_checked(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(private_key_file)]
        ).stdout.strip()
        info_plist.write_bytes(plistlib.dumps({"SUPublicEDKey": public_key}))
        signature = self.run_checked(
            [
                str(root / "Vendor" / "Sparkle" / "bin" / "sign_update"),
                "--ed-key-file",
                str(private_key_file),
                "-p",
                str(archive),
            ]
        ).stdout.strip()

        def write_appcast(
            enclosure_signature: str,
            *,
            title: str = "Tip build v9.8.7",
            display_version: str = "Tip build v9.8.7",
        ) -> None:
            appcast.write_text(
                f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>{title}</title>
      <sparkle:version>1.2.3</sparkle:version>
      <sparkle:shortVersionString>{display_version}</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/tip/{archive.name}"
                 length="{archive.stat().st_size}"
                 sparkle:edSignature="{enclosure_signature}" />
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )

        env = os.environ.copy()
        env.update(
            {
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(SCRIPT_DIR),
                "TIP_COMMIT": "0" * 40,
                "TIP_BUILD_NUMBER": "1.2.3",
                "TIP_DOWNLOAD_URL_PREFIX": "https://example.invalid/tip/",
                "SPARKLE_PRIVATE_KEY": private_key,
                "VALIDATOR_APP_BUNDLE": str(app_bundle),
                "VALIDATOR_UPDATE_ZIP": str(archive),
                "VALIDATOR_APPCAST": str(appcast),
                "VALIDATOR_TMP_DIR": str(validator_tmp_dir),
            }
        )
        command = [
            "bash",
            "-c",
            """source "$1"
APP_BUNDLE="$VALIDATOR_APP_BUNDLE"
UPDATE_ZIP="$VALIDATOR_UPDATE_ZIP"
APPCAST="$VALIDATOR_APPCAST"
TMP_DIR="$VALIDATOR_TMP_DIR"
mkdir -p "$TMP_DIR"
MARKETING_VERSION="9.8.7"
validate_generated_tip_appcast""",
            "tip-appcast-validation",
            str(SCRIPT_DIR / "main_tip_release.sh"),
        ]

        write_appcast(signature)
        accepted = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        duplicate_version_tree = ET.parse(appcast)
        duplicate_version_item = duplicate_version_tree.getroot().find("./channel/item")
        self.assertIsNotNone(duplicate_version_item)
        assert duplicate_version_item is not None
        ET.SubElement(
            duplicate_version_item,
            "{http://www.andymatuschak.org/xml-namespaces/sparkle}version",
        ).text = "999"
        duplicate_version_tree.write(appcast, encoding="utf-8", xml_declaration=True)
        rejected_duplicate_version = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected_duplicate_version.returncode, 0)
        self.assertIn(
            "tip appcast item must contain exactly one sparkle:version",
            rejected_duplicate_version.stderr,
        )

        write_appcast(signature, title="Version 9.8.7")
        rejected_title = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected_title.returncode, 0)
        self.assertIn("Tip appcast title mismatch", rejected_title.stderr)

        write_appcast(signature, display_version="9.8.7")
        rejected_display_version = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected_display_version.returncode, 0)
        self.assertIn("Tip appcast display version mismatch", rejected_display_version.stderr)

        write_appcast("")
        rejected_signature = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected_signature.returncode, 0)
        self.assertIn("Tip appcast enclosure is missing an EdDSA signature", rejected_signature.stderr)

    def test_tip_appcast_label_changes_display_metadata_without_changing_comparison_version(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        appcast = temp_dir / "appcast.xml"
        appcast.write_text(
            """<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><title>Version 9.8.7</title>
    <sparkle:version>29.8.52</sparkle:version>
    <sparkle:shortVersionString>9.8.7</sparkle:shortVersionString>
  </item></channel>
</rss>
""",
            encoding="utf-8",
        )
        command = [
            "bash",
            "-c",
            """source "$1"
APPCAST="$2"
MARKETING_VERSION="9.8.7"
label_generated_tip_appcast""",
            "tip-appcast-label",
            str(SCRIPT_DIR / "main_tip_release.sh"),
            str(appcast),
        ]

        labeled = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(labeled.returncode, 0, labeled.stderr)
        item = ET.parse(appcast).getroot().find("./channel/item")
        self.assertIsNotNone(item)
        assert item is not None
        sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        self.assertEqual(item.findtext(f"{{{sparkle}}}version"), "29.8.52")
        self.assertEqual(item.findtext(f"{{{sparkle}}}shortVersionString"), "Tip build v9.8.7")
        self.assertEqual(item.findtext("title"), "Tip build v9.8.7")

    def test_release_sentry_runtime_wiring_uses_protected_dsn_and_stable_resolution(self) -> None:
        root = SCRIPT_DIR.parent
        package_manifest = (root / "Package.swift").read_text(encoding="utf-8")
        package_resolved = json.loads((root / "Package.resolved").read_text(encoding="utf-8"))
        notice_inventory = (root / "ThirdPartyLicenses" / "swiftpm" / "inventory.tsv").read_text(encoding="utf-8")
        release_workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        ci_workflow = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        release_candidate_workflow = (root / ".github" / "workflows" / "release-candidate.yml").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        bootstrap_source = (
            root
            / "Sources"
            / "RepoPrompt"
            / "Infrastructure"
            / "Telemetry"
            / "SentryTelemetryBootstrap.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('.package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1")', package_manifest)
        self.assertIn('let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")', package_manifest)
        self.assertIn('repoPromptAppDependencies.append(sentryDependency)', package_manifest)
        self.assertIn('repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertIn('repoPromptTestDependencies.append(sentryDependency)', package_manifest)
        self.assertIn('repoPromptTestSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', release_workflow)
        self.assertIn('name: Sentry-enabled Build', ci_workflow)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', ci_workflow)
        self.assertIn('swift build --product RepoPrompt', ci_workflow)
        self.assertIn('swift test --filter SentryTelemetryPrivacyTests', ci_workflow)
        self.assertIn('smoke_packaged_mcp_roundtrip.sh', release_candidate_workflow)
        self.assertIn('".build/release/RepoPrompt.app"', release_candidate_workflow)
        self.assertIn("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}", release_workflow)
        self.assertIn("REPOPROMPT_ENABLE_SENTRY=1", release_script)
        self.assertIn('if [[ -n "${SENTRY_DSN:-}" ]]; then', staged_signing_script)
        self.assertIn('plutil -replace RepoPromptSentryDSN -string "$SENTRY_DSN"', staged_signing_script)
        self.assertIn('Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN")', bootstrap_source)
        self.assertIn('REPOPROMPT_TELEMETRY_DISABLED', bootstrap_source)
        self.assertIn('GlobalSettingsStore.shared.telemetryEnabled()', bootstrap_source)
        self.assertIn('options.beforeSend', bootstrap_source)
        self.assertIn('options.enableCaptureFailedRequests = false', bootstrap_source)
        self.assertIn('options.enableAutoSessionTracking = false', bootstrap_source)
        self.assertIn('event.request = nil', bootstrap_source)
        self.assertIn('event.user = nil', bootstrap_source)
        self.assertIn('event.serverName = nil', bootstrap_source)
        self.assertIn('deviceIdentifierKeys', bootstrap_source)
        self.assertIn('geoPayloadKeys', bootstrap_source)
        self.assertIn('event.dist = nil', bootstrap_source)
        self.assertIn('scrub(stacktrace: event.stacktrace)', bootstrap_source)
        self.assertIn('event.debugMeta?.forEach', bootstrap_source)
        self.assertIn('options.tracesSampleRate = performanceTracingEnabled ? 0.05 : 0', bootstrap_source)
        self.assertIn('#if DEBUG\n                if let value = ProcessInfo.processInfo.environment["REPOPROMPT_SENTRY_DSN"]', bootstrap_source)
        self.assertIn('Official Sentry-enabled release publishing requires SENTRY_AUTH_TOKEN', release_script)
        self.assertIn('SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"', release_script)
        self.assertIn('prepare_sentry_release', release_script)
        self.assertIn('finalize_sentry_release', release_script)
        self.assertNotIn('record_sentry_production_deploy', release_script)
        self.assertIn('record_verified_sentry_deploy_if_needed', promote_script)

        pins = {pin["identity"]: pin for pin in package_resolved["pins"]}
        self.assertEqual(pins["sentry-cocoa"]["state"]["version"], "9.17.1")
        self.assertIn("sentry-cocoa\t9.17.1\thttps://github.com/getsentry/sentry-cocoa", notice_inventory)

    def test_modern_sparkle_key_seed_derives_public_key(self) -> None:
        descriptor, key_path = tempfile.mkstemp()
        os.close(descriptor)
        key_file = Path(key_path)
        self.addCleanup(key_file.unlink, missing_ok=True)
        key_file.write_text(base64.b64encode(bytes(range(32))).decode("ascii"), encoding="utf-8")

        result = subprocess.run(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(base64.b64decode(result.stdout.strip())), 32)

    def test_legacy_sparkle_key_export_is_rejected(self) -> None:
        descriptor, key_path = tempfile.mkstemp()
        os.close(descriptor)
        key_file = Path(key_path)
        self.addCleanup(key_file.unlink, missing_ok=True)
        key_file.write_text(base64.b64encode(bytes(96)).decode("ascii"), encoding="utf-8")

        result = subprocess.run(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("modern 32-byte seed", result.stderr)

    def test_sparkle_signature_verifier_rejects_modified_signature(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        key_file = temp_dir / "key"
        public_key_file = temp_dir / "public-key"
        archive = temp_dir / "archive.zip"
        key_file.write_text(base64.b64encode(bytes(range(32))).decode("ascii"), encoding="utf-8")
        archive.write_text("signed archive\n", encoding="utf-8")
        public_key = self.run_checked(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)]
        ).stdout.strip()
        public_key_file.write_text(public_key, encoding="utf-8")
        signature = subprocess.run(
            [
                str(SCRIPT_DIR.parent / "Vendor" / "Sparkle" / "bin" / "sign_update"),
                "--ed-key-file",
                str(key_file),
                "-p",
                str(archive),
            ],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

        accepted = subprocess.run(
            [
                "xcrun",
                "swift",
                str(SCRIPT_DIR / "verify_sparkle_signature.swift"),
                str(public_key_file),
                signature,
                str(archive),
            ],
            text=True,
            capture_output=True,
        )
        rejected = subprocess.run(
            [
                "xcrun",
                "swift",
                str(SCRIPT_DIR / "verify_sparkle_signature.swift"),
                str(public_key_file),
                base64.b64encode(bytes(64)).decode("ascii"),
                str(archive),
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not verify", rejected.stderr)

    def test_github_tokens_are_scrubbed_before_swiftpm_commands(self) -> None:
        helper = SCRIPT_DIR / "run_without_github_tokens.sh"
        result = subprocess.run(
            [
                str(helper),
                "bash",
                "-c",
                '[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -z "${SOURCE_GH_TOKEN:-}" ]]',
            ],
            env={
                "PATH": os.environ["PATH"],
                "GH_TOKEN": "source-token",
                "GITHUB_TOKEN": "workflow-token",
                "SOURCE_GH_TOKEN": "explicit-source-token",
            },
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve', release_script)
        # Three release product builds, one debug product-less build, and the bin-path echo plus query.
        # The last three carry the optimized-diagnostics lane prefix (empty outside debug-optimized).
        lane_prefix = '${CANONICAL_PREFIX[@]+"${CANONICAL_PREFIX[@]}"} build'
        build_reference = re.compile(
            r'"\$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift\.sh" (?:' + re.escape(lane_prefix[: -len(" build")]) + r" )?build"
        )
        self.assertEqual(len(build_reference.findall(package_script)), 6)
        self.assertEqual(package_script.count('"$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh"'), 6)
        self.assertEqual(package_script.count(lane_prefix), 3)
        prefixed_lines = [line.strip() for line in package_script.splitlines() if lane_prefix in line]
        self.assertEqual(
            prefixed_lines,
            [
                'run "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" ' + lane_prefix + ' "${SWIFT_BUILD_ARGS[@]}"',
                'echo_cmd "$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" ' + lane_prefix + ' -c "$SWIFT_CONF" --show-bin-path',
                'BUILD_DIR="$("$CONTROL_PLANE_SCRIPTS_DIR/canonical_swift.sh" '
                + lane_prefix
                + ' -c "$SWIFT_CONF" --show-bin-path)"',
            ],
        )
        self.assertNotIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift build', package_script)
        self.assertIn(
            '"$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"',
            package_script,
        )
        self.assertIn("unset GH_TOKEN GITHUB_TOKEN SOURCE_GH_TOKEN", release_script)

    def test_sparkle_vendor_manifest_rejects_extra_file_and_symlink_redirect(self) -> None:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        vendor = root / "Vendor" / "Sparkle"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        vendor.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "verify_sparkle_vendor.sh", scripts / "verify_sparkle_vendor.sh")
        scripts.joinpath("verify_sparkle_vendor.sh").chmod(0o755)
        source_vendor = SCRIPT_DIR.parent / "Vendor" / "Sparkle"
        shutil.copy2(source_vendor / "INSTALLED_MANIFEST.tsv", vendor / "INSTALLED_MANIFEST.tsv")
        shutil.copytree(source_vendor / "bin", vendor / "bin")
        shutil.copytree(
            source_vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework",
            vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework",
            symlinks=True,
        )

        accepted = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        extra = vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework" / "unexpected"
        extra.write_text("unexpected\n", encoding="utf-8")
        rejected_extra = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected_extra.returncode, 0)
        self.assertIn("extra=", rejected_extra.stderr)
        extra.unlink()

        headers = vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework" / "Headers"
        headers.unlink()
        headers.symlink_to("Versions/B/PrivateHeaders")
        rejected_link = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected_link.returncode, 0)
        self.assertIn("changed=", rejected_link.stderr)

    def test_staged_release_validator_rejects_contents_and_frameworks_symlinks(self) -> None:
        for relative in ("Contents", "Contents/Frameworks"):
            with self.subTest(relative=relative):
                approved, staged, scripts = self.make_staged_release_fixture()
                accepted = self.run_staged_validation(approved, staged, scripts)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)

                target = staged / ".build" / "release" / "RepoPrompt.app" / relative
                moved = target.with_name(f"{target.name}-real")
                target.rename(moved)
                target.symlink_to(moved.name, target_is_directory=True)
                rejected = self.run_staged_validation(approved, staged, scripts)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("must be a real directory", rejected.stderr)

    def test_staged_release_extractor_rejects_absolute_symlink(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        archive = temp_dir / "stage.zip"
        destination = temp_dir / "extract"
        member = ".build/release/RepoPrompt.app/Contents"
        info = zipfile.ZipInfo(member)
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr(info, "/tmp/repoprompt-stage-escape")

        result = subprocess.run(
            [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute target", result.stderr)

    def test_staged_release_extractor_rejects_existing_destination(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        archive = temp_dir / "stage.zip"
        destination = temp_dir / "extract"
        destination.mkdir()
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("version.env", "fixture\n")

        result = subprocess.run(
            [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination already exists", result.stderr)

    def test_release_metadata_parser_accepts_allowlisted_values(self) -> None:
        root = self.make_metadata_root()

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata "{root}"; printf "%s|%s|%s\\n" "$APP_NAME" "$MARKETING_VERSION" "$BUILD_NUMBER"',
            ],
            text=True,
            capture_output=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "RepoPrompt|1.0.0|1\n")

    def test_release_metadata_parser_accepts_three_component_tip_build(self) -> None:
        root = self.make_metadata_root()
        metadata_path = root / "version.env"
        metadata_path.write_text(
            metadata_path.read_text(encoding="utf-8").replace("BUILD_NUMBER=1", "BUILD_NUMBER=28.7.95"),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata "{root}"; printf "%s\n" "$BUILD_NUMBER"',
            ],
            text=True,
            capture_output=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "28.7.95\n")

    def test_release_metadata_parser_rejects_shell_execution(self) -> None:
        root = self.make_metadata_root()
        marker = root / "executed"
        metadata = (root / "version.env").read_text(encoding="utf-8")
        (root / "version.env").write_text(
            metadata.replace("APP_NAME=RepoPrompt", f"APP_NAME=$(touch {marker})"),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; load_release_metadata "{root}"',
            ],
            text=True,
            capture_output=True,
            timeout=30,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_mcp_cli_version_sync_updates_source_and_check_detects_drift(self) -> None:
        root = self.make_metadata_root()
        source = root / "Sources" / "RepoPromptMCP" / "main.swift"
        source.parent.mkdir(parents=True)
        source.write_text('let CLI_VERSION = "9.9.9"\n', encoding="utf-8")
        env = os.environ.copy()
        env["REPOPROMPT_RELEASE_SOURCE_ROOT"] = str(root)
        helper = SCRIPT_DIR / "sync_mcp_cli_version.sh"

        rejected = subprocess.run([str(helper), "--check"], env=env, text=True, capture_output=True)
        synced = subprocess.run([str(helper)], env=env, text=True, capture_output=True)
        accepted = subprocess.run([str(helper), "--check"], env=env, text=True, capture_output=True)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Run ./Scripts/release.sh sync-cli-version", rejected.stderr)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        self.assertEqual(source.read_text(encoding="utf-8"), 'let CLI_VERSION = "1.0.0"\n')
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_release_preflight_requires_synchronized_mcp_cli_version(self) -> None:
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")

        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh"', release_script)
        self.assertIn('"$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh" --check', release_script)
        self.assertIn("sync-cli-version) sync_mcp_cli_version", release_script)

    def test_remote_release_commit_helper_rejects_moved_tag(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "tag", "v1.0.0")
        self.git(work, "push", "origin", "main", "v1.0.0")

        accepted = self.run_remote_verify(work, first)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        self.commit_file(work, "second")
        self.git(work, "tag", "-f", "v1.0.0")
        self.git(work, "push", "--force", "origin", "v1.0.0")

        rejected = self.run_remote_verify(work, first)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Remote release tag moved", rejected.stderr)

    def test_release_ref_helper_requires_tag_reachable_from_main(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "tag", "v1.0.0")
        self.git(work, "push", "origin", "main", "v1.0.0")

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "v1.0.0"],
            cwd=work,
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(accepted.stdout.strip(), first)

        self.git(work, "checkout", "-b", "unmerged")
        self.commit_file(work, "unmerged")
        self.git(work, "tag", "v1.0.1")
        self.git(work, "push", "origin", "v1.0.1")
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "v1.0.1"],
            cwd=work,
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("not reachable from protected main", rejected.stderr)

    def test_release_ref_helper_rejects_noncanonical_tag(self) -> None:
        result = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "release-1.0.0"],
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical", result.stderr)

    def make_universal_architecture_fixture(self) -> tuple[Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        paths = [
            app / "Contents" / "MacOS" / "RepoPrompt",
            app / "Contents" / "MacOS" / "repoprompt-mcp",
            app / "Contents" / "MacOS" / "repoprompt-gateway",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Sparkle",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Autoupdate",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "Updater.app"
            / "Contents"
            / "MacOS"
            / "Updater",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "XPCServices"
            / "Installer.xpc"
            / "Contents"
            / "MacOS"
            / "Installer",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "XPCServices"
            / "Downloader.xpc"
            / "Contents"
            / "MacOS"
            / "Downloader",
        ]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"#!/usr/bin/env bash\n# {path.name}\n", encoding="utf-8")
            path.chmod(0o755)
        fake_lipo = temp_dir / "lipo"
        fake_lipo.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
if [[ "${FAKE_THIN_HELPER:-0}" == "1" && "$path" == *repoprompt-mcp ]]; then
    printf 'arm64\n'
else
    printf 'arm64 x86_64\n'
fi
""",
            encoding="utf-8",
        )
        fake_lipo.chmod(0o755)
        return app, fake_lipo

    def make_embedded_helper_layout(self) -> Path:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        macos = app / "Contents" / "MacOS"
        resources_bin = app / "Contents" / "Resources" / "bin"
        macos.mkdir(parents=True)
        resources_bin.mkdir(parents=True)
        (macos / "RepoPrompt").write_text("RepoPrompt\n", encoding="utf-8")
        for helper_name in ("repoprompt-mcp", "repoprompt-gateway"):
            helper = macos / helper_name
            helper.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            helper.chmod(0o755)
            (app / "Contents" / "Resources" / helper_name).symlink_to(f"../MacOS/{helper_name}")
            (resources_bin / helper_name).symlink_to(f"../../MacOS/{helper_name}")
        return app

    def start_unix_listener(self, socket_path: Path) -> subprocess.Popen[str]:
        ready = socket_path.with_suffix(".ready")
        ready.unlink(missing_ok=True)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import socket, sys\n"
                "listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
                "listener.bind(sys.argv[1])\n"
                "listener.listen(8)\n"
                "open(sys.argv[2], 'w', encoding='utf-8').close()\n"
                "while True:\n"
                "    client, _ = listener.accept()\n"
                "    with client:\n"
                "        while client.recv(4096):\n"
                "            pass\n",
                os.fspath(socket_path),
                os.fspath(ready),
            ],
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

        def stop() -> None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if process.stderr is not None:
                process.stderr.close()

        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not ready.exists():
            if process.poll() is not None:
                self.fail(f"UNIX listener exited early: {process.stderr.read() if process.stderr else ''}")
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "UNIX listener did not become ready")
        return process

    def socket_owner_process_path(self, pid: int) -> Path:
        result = self.run_socket_owner_helper("process-path", pid)
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(result.stdout.strip())

    @staticmethod
    def run_socket_owner_helper(*arguments: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "verify_packaged_mcp_socket_owner.py"), *(str(argument) for argument in arguments)],
            text=True,
            capture_output=True,
            timeout=10,
        )

    @staticmethod
    def run_layout_validation(app: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "validate_embedded_mcp_helper_layout.sh"), str(app), "Fixture helper layout"],
            text=True,
            capture_output=True,
        )

    def make_metadata_root(self) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        (root / "version.env").write_text(
            """\
APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
""",
            encoding="utf-8",
        )
        return root

    def make_keyboard_shortcuts_patch_fixture(self, source: str | None = None) -> tuple[Path, Path]:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        utilities = root / ".build" / "checkouts" / "KeyboardShortcuts" / "Sources" / "KeyboardShortcuts" / "Utilities.swift"
        utilities.parent.mkdir(parents=True)
        utilities.write_text(source if source is not None else self.keyboard_shortcuts_upstream_utilities(), encoding="utf-8")
        self.write_package_resolved(root, "2.3.0")
        return root, utilities

    @staticmethod
    def keyboard_shortcuts_upstream_utilities() -> str:
        return """\
import SwiftUI

#if os(macOS)
import Carbon.HIToolbox


extension String {
\t/**
\tMakes the string localizable.
\t*/
\tvar localized: String {
\t\tNSLocalizedString(self, bundle: .module, comment: self)
\t}
}


extension Data {
\tvar toString: String? { String(data: self, encoding: .utf8) }
}
"""

    @staticmethod
    def write_package_resolved(
        root: Path,
        version: str,
        revision: str = "045cf174010beb335fa1d2567d18c057b8787165",
    ) -> None:
        (root / "Package.resolved").write_text(
            json.dumps(
                {"pins": [{"identity": "keyboardshortcuts", "state": {"revision": revision, "version": version}}]},
                indent=2,
            ),
            encoding="utf-8",
        )

    @staticmethod
    def run_keyboard_shortcuts_patch(root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "patch_keyboard_shortcuts_resource_lookup.sh"), str(root)],
            text=True,
            capture_output=True,
        )

    def make_staged_release_fixture(self) -> tuple[Path, Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        approved = temp_dir / "approved"
        staged = temp_dir / "staged"
        scripts = temp_dir / "Scripts"
        app = staged / ".build" / "release" / "RepoPrompt.app"
        for directory in (
            approved / "AppBundle",
            approved / "ThirdPartyLicenses" / "fixture",
            staged / "ThirdPartyLicenses" / "fixture",
            app / "Contents" / "Frameworks" / "Sparkle.framework",
            app / "Contents" / "MacOS",
            app / "Contents" / "Resources" / "bin",
            app / "Contents" / "Resources" / "Legal" / "ThirdPartyLicenses" / "fixture",
            scripts,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        for name in (
            "load_release_metadata.sh",
            "parse_release_metadata.py",
            "validate_embedded_mcp_helper_layout.sh",
            "validate_app_architectures.sh",
            "write_app_artifact_manifest.py",
            "validate_packaged_legal.sh",
            "validate_required_swiftpm_resource_bundles.sh",
            "validate_staged_release.sh",
        ):
            shutil.copy2(SCRIPT_DIR / name, scripts / name)
            scripts.joinpath(name).chmod(0o755)
        metadata = """\
APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
"""
        for root in (approved, staged):
            (root / "version.env").write_text(metadata, encoding="utf-8")
            (root / "LICENSE").write_text("license\n", encoding="utf-8")
            (root / "THIRD_PARTY_NOTICES.md").write_text("notices\n", encoding="utf-8")
            (root / "ThirdPartyLicenses" / "fixture" / "LICENSE").write_text("fixture\n", encoding="utf-8")
        template = (SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_text(encoding="utf-8")
        (approved / "AppBundle" / "Info.plist.template").write_text(template, encoding="utf-8")
        for key, value in {
            "__APP_NAME__": "RepoPrompt",
            "__DISPLAY_NAME__": "RepoPrompt CE",
            "__BUNDLE_ID__": "com.pvncher.repoprompt.ce",
            "__MARKETING_VERSION__": "1.0.0",
            "__BUILD_NUMBER__": "1",
            "__URL_SCHEME__": "repoprompt-ce",
            "__DEBUG_SECURE_STORAGE_BACKEND__": "alternate-in-memory",
            "__SIGNING_MODE__": "release-candidate-adhoc",
            "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
            "__LOCAL_SECURE_STORAGE_GENERATION__": "",
        }.items():
            template = template.replace(key, value)
        (app / "Contents" / "Info.plist").write_text(template, encoding="utf-8")
        for name in ("RepoPrompt", "repoprompt-mcp", "repoprompt-gateway"):
            executable = app / "Contents" / "MacOS" / name
            content = "RepoPromptKeyboardShortcutsResourceLookupV1\n" if name == "RepoPrompt" else name
            executable.write_text(content, encoding="utf-8")
            executable.chmod(0o755)
        sparkle_executables = [
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Sparkle",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Autoupdate",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Updater.app" / "Contents" / "MacOS" / "Updater",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "XPCServices" / "Installer.xpc" / "Contents" / "MacOS" / "Installer",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "XPCServices" / "Downloader.xpc" / "Contents" / "MacOS" / "Downloader",
        ]
        for executable in sparkle_executables:
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text(executable.name, encoding="utf-8")
            executable.chmod(0o755)
        for helper_name in ("repoprompt-mcp", "repoprompt-gateway"):
            (app / "Contents" / "Resources" / helper_name).symlink_to(f"../MacOS/{helper_name}")
            (app / "Contents" / "Resources" / "bin" / helper_name).symlink_to(f"../../MacOS/{helper_name}")
        self.write_keyboard_shortcuts_bundle(app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle")
        self.write_gateway_pwa_bundle(app / "Contents" / "Resources" / "RepoPromptCE_RepoPromptGateway.bundle")
        legal = app / "Contents" / "Resources" / "Legal"
        shutil.copy2(staged / "LICENSE", legal / "LICENSE")
        shutil.copy2(staged / "THIRD_PARTY_NOTICES.md", legal / "THIRD_PARTY_NOTICES.md")
        shutil.copy2(
            staged / "ThirdPartyLicenses" / "fixture" / "LICENSE",
            legal / "ThirdPartyLicenses" / "fixture" / "LICENSE",
        )
        (staged / "RELEASE_COMMIT").write_text("fixture-release-commit\n", encoding="utf-8")
        fake_lipo = scripts / "fake-lipo"
        fake_lipo.write_text("#!/usr/bin/env bash\nprintf 'arm64 x86_64\\n'\n", encoding="utf-8")
        fake_lipo.chmod(0o755)
        fake_codesign = scripts / "fake-codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *--extract-certificates*) exit 1 ;;
  *--entitlements*) printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\\n' ;;
  *-r-*) printf 'designated => identifier "fixture"\\n' >&2 ;;
  *) printf 'Identifier=fixture\\nTeamIdentifier=not set\\n' >&2 ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = staged / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        manifest_env = os.environ.copy()
        manifest_env.update({"LIPO": str(fake_lipo), "CODESIGN": str(fake_codesign)})
        subprocess.run(
            [
                str(scripts / "write_app_artifact_manifest.py"),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=manifest_env,
            check=True,
            text=True,
            capture_output=True,
        )
        return approved, staged, scripts

    @staticmethod
    def write_keyboard_shortcuts_bundle(bundle: Path) -> None:
        resources = bundle / "Contents" / "Resources"
        (resources / "en.lproj").mkdir(parents=True, exist_ok=True)
        (bundle / "Contents" / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
        (resources / "en.lproj" / "Localizable.strings").write_text('"record_shortcut" = "Record Shortcut";\n', encoding="utf-8")

    @staticmethod
    def write_gateway_pwa_bundle(bundle: Path) -> None:
        pwa = bundle / "pwa"
        pwa.mkdir(parents=True, exist_ok=True)
        for asset in ("index.html", "app.js", "sw.js", "manifest.webmanifest"):
            (pwa / asset).write_text(f"fixture {asset}\n", encoding="utf-8")

    @staticmethod
    def run_staged_validation(approved: Path, staged: Path, scripts: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "RELEASE_COMMIT": "fixture-release-commit",
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(staged),
                "LIPO": str(scripts / "fake-lipo"),
                "CODESIGN": str(scripts / "fake-codesign"),
            }
        )
        return subprocess.run(
            [str(scripts / "validate_staged_release.sh")],
            env=env,
            text=True,
            capture_output=True,
        )

    def make_git_remote(self) -> tuple[Path, Path]:
        parent = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, parent, True)
        remote = parent / "remote.git"
        work = parent / "work"
        self.run_checked(["git", "init", "--bare", str(remote)])
        self.run_checked(["git", "clone", str(remote), str(work)])
        self.git(work, "config", "user.email", "release-tests@example.com")
        self.git(work, "config", "user.name", "Release Tests")
        self.git(work, "config", "commit.gpgsign", "false")
        self.git(work, "checkout", "-b", "main")
        return remote, work

    def commit_file(self, work: Path, content: str) -> str:
        (work / "value.txt").write_text(content, encoding="utf-8")
        self.git(work, "add", "value.txt")
        self.git(work, "commit", "-m", content)
        return self.git(work, "rev-parse", "HEAD").stdout.strip()

    def run_remote_verify(self, work: Path, expected: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "verify_remote_release_commit.sh"), "v1.0.0", expected],
            cwd=work,
            text=True,
            capture_output=True,
        )

    def git(self, work: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return self.run_checked(["git", *args], cwd=work)

    @staticmethod
    def run_checked(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True)


class PackageTimingTests(unittest.TestCase):
    """Debug-packaging Step 0: [package-timing] records and their summarizer."""

    def test_package_app_emits_parseable_timing_records_and_failed_runs_are_excluded(self) -> None:
        import summarize_package_phases as summarizer

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        shutil.copy2(SCRIPT_DIR / "parse_release_metadata.py", scripts / "parse_release_metadata.py")
        doctor = scripts / "doctor.sh"
        doctor.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8")
        doctor.chmod(0o755)
        (root / "version.env").write_text(
            'APP_NAME=RepoPrompt\nDISPLAY_NAME="RepoPrompt CE"\nMARKETING_VERSION=1.0.0\nBUILD_NUMBER=1\n'
            "BUNDLE_ID=com.pvncher.repoprompt.ce\nSIGNING_TEAM_ID=648A27MST5\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update({"REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts), "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root)})
        result = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug"], env=env, text=True, capture_output=True
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        lines = result.stdout.splitlines()
        # The human-readable heading format is unchanged.
        self.assertRegex(result.stdout, r"(?m)^==> \[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] Checking build environment "
                                        r"\(previous: \d+s, total: \d+s\)$")
        timing = [line for line in lines if line.startswith("[package-timing]")]
        names = [summarizer._PHASE_RE.search(line).group(1) for line in timing[:-1]]
        self.assertEqual(names, ["startup", "Loading release metadata", "Checking build environment"])
        self.assertRegex(timing[-1], r"^\[package-timing\] summary outcome=fresh deep=skipped:not-reached "
                                     r"total_ms=(\d+|\?) status=42$")
        runs = summarizer.parse_runs(lines, "stub")
        self.assertEqual(len(runs), 1)
        payload = summarizer.summarize(runs)
        self.assertEqual(payload["runs"], 0)
        self.assertEqual(payload["excludedRuns"], [{"source": "stub", "index": 0, "reason": "status=42"}])

    def test_summarizer_reports_phase_medians_iqr_and_non_compile_time(self) -> None:
        import summarize_package_phases as summarizer

        def run_log(build_ms: int, sign_ms: int, deep: str = "ran") -> list[str]:
            total = 100 + build_ms + 50 + sign_ms
            return [
                "==> [2026-10-16 10:00:00] Loading release metadata (previous: 0s, total: 0s)",
                '[package-timing] phase="startup" elapsed_ms=100 total_ms=100',
                f'[package-timing] phase="Building RepoPrompt (debug, host-native)" elapsed_ms={build_ms} total_ms=1',
                '[package-timing] phase="Resolving build artifact paths" elapsed_ms=50 total_ms=2',
                f'[package-timing] phase="Signing app bundle" elapsed_ms={sign_ms} total_ms=3',
                f"[package-timing] summary outcome=fresh deep={deep} total_ms={total} status=0",
            ]

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        log = temp_dir / "runs.log"
        lines = run_log(3000, 4000) + run_log(3200, 4100) + run_log(2800, 4200) + run_log(3100, 3900)
        # A backward wall-clock jump shows as a negative phase even when the final total is positive.
        clock_jump = run_log(3000, 4000)
        clock_jump[3] = '[package-timing] phase="Resolving build artifact paths" elapsed_ms=-1200 total_ms=1900'
        lines += clock_jump
        lines += ['[package-timing] phase="startup" elapsed_ms=10 total_ms=10',
                  "[package-timing] summary outcome=fresh deep=ran total_ms=-5 status=0"]
        lines += ['[package-timing] phase="startup" elapsed_ms=? total_ms=?',
                  "[package-timing] summary outcome=fresh deep=ran total_ms=? status=0",
                  '[package-timing] phase="startup" elapsed_ms=5 total_ms=5']
        log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        output = temp_dir / "summary.json"
        self.assertEqual(summarizer.main([str(log), "--output", str(output)]), 0)
        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(payload["runs"], 4)
        self.assertEqual(
            [item["reason"] for item in payload["excludedRuns"]],
            ["negative elapsed_ms for phase 'Resolving build artifact paths' (wall-clock jump; repeat the sample)",
             "negative total_ms (wall-clock jump; repeat the sample)", "unknown total_ms", "no summary record"],
        )
        self.assertEqual(list(payload["phases"]), ["startup", "Building RepoPrompt (debug, host-native)",
                                                   "Resolving build artifact paths", "Signing app bundle"])
        self.assertEqual(payload["phases"]["Signing app bundle"]["median_ms"], 4050)
        self.assertEqual(payload["build_ms"]["median_ms"], 3050)
        self.assertEqual([run["non_compile_ms"] for run in payload["perRun"]], [4150, 4250, 4350, 4050])
        self.assertEqual(payload["non_compile_ms"]["median_ms"], 4200)
        self.assertEqual(payload["non_compile_ms"]["iqr_ms"], 150)
        self.assertEqual(payload["deep"], {"ran": 4})
        # A run killed before its summary never merges into the next run, and VERBOSE=1 shell
        # tracing of the record printf is ignored instead of read as a malformed record.
        xtrace = ("+ printf '[package-timing] phase=\"%s\" elapsed_ms=%s total_ms=%s\\n' startup 1 1",
                  "++ printf '[package-timing] summary outcome=%s deep=%s total_ms=%s status=%s\\n' fresh ran 9 0",
                  "+ package_timing_record")
        interrupted = ['[package-timing] phase="startup" elapsed_ms=1 total_ms=1',
                       '[package-timing] phase="Building RepoPrompt (debug, host-native)" elapsed_ms=9000 total_ms=9001']
        combined = temp_dir / "combined.log"
        combined.write_text("\n".join([*interrupted, *xtrace, *run_log(3000, 4000), *xtrace]) + "\n", encoding="utf-8")
        runs = summarizer.parse_runs(combined.read_text(encoding="utf-8").splitlines(), "combined")
        self.assertEqual([len(run["phases"]) for run in runs], [2, 4])
        payload = summarizer.summarize(runs)
        self.assertEqual(payload["runs"], 1)
        self.assertEqual(payload["excludedRuns"], [{"source": "combined", "index": 0, "reason": "no summary record"}])
        self.assertEqual(payload["perRun"][0]["build_ms"], 3000)
        self.assertEqual(payload["perRun"][0]["non_compile_ms"], 4150)
        empty = temp_dir / "empty.log"
        empty.write_text("no timing here\n", encoding="utf-8")
        self.assertEqual(summarizer.main([str(empty), "--output", str(temp_dir / "empty.json")]), 1)


if __name__ == "__main__":
    unittest.main()
