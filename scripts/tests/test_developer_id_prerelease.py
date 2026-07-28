from __future__ import annotations

import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


prerelease = load_script(
    "developer_id_prerelease_validation", "validate-developer-id-prerelease.py"
)


class PrereleaseMetadataTests(unittest.TestCase):
    def test_preview_tag_is_exactly_bound_to_version_and_build(self) -> None:
        prerelease.validate_preview_tag(
            "preview-v2026.7.12-build.13", "2026.7.12", "13"
        )
        with self.assertRaisesRegex(ValueError, "must be exactly"):
            prerelease.validate_preview_tag(
                "v2026.7.12", "2026.7.12", "13"
            )

    def test_notary_result_requires_accepted_status_and_clean_log(self) -> None:
        result = prerelease.inspect_notary_result(
            {"status": "Accepted", "id": "submission-id"},
            {"issues": []},
        )
        self.assertEqual(result, ("submission-id", 0, 0))
        with self.assertRaisesRegex(ValueError, "not 'Accepted'"):
            prerelease.inspect_notary_result(
                {"status": "Invalid", "id": "submission-id"}, {"issues": []}
            )
        with self.assertRaisesRegex(ValueError, "1 error"):
            prerelease.inspect_notary_result(
                {"status": "Accepted", "id": "submission-id"},
                {"issues": [{"severity": "error"}]},
            )
        with self.assertRaisesRegex(ValueError, "1 warning"):
            prerelease.inspect_notary_result(
                {"status": "Accepted", "id": "submission-id"},
                {"issues": [{"severity": "warning"}]},
            )


class ReleaseSecurityFailureTests(unittest.TestCase):
    def run_command(
        self, *args: str, env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            args,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def make_app(
        self,
        directory: Path,
        *,
        runtime: bool,
        get_task_allow: bool = False,
    ) -> Path:
        app = directory / "Fixture.app"
        executable = app / "Contents" / "MacOS" / "fixture"
        executable.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)
        info = {
            "CFBundleIdentifier": "invalid.example.fixture",
            "CFBundleExecutable": "fixture",
            "CFBundlePackageType": "APPL",
        }
        with (app / "Contents" / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        command = ["codesign", "--force", "--sign", "-"]
        if runtime:
            command.extend(["--options", "runtime"])
        if get_task_allow:
            entitlements = directory / "entitlements.plist"
            with entitlements.open("wb") as file:
                plistlib.dump({"com.apple.security.get-task-allow": True}, file)
            command.extend(["--entitlements", str(entitlements)])
        command.append(str(app))
        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return app

    def test_missing_secrets_fail_before_release_work(self) -> None:
        env = dict(os.environ)
        for name in (
            "MACOS_CERTIFICATE_P12_BASE64",
            "MACOS_CERTIFICATE_PASSWORD",
            "APPLE_NOTARY_KEY_P8_BASE64",
            "APPLE_NOTARY_KEY_ID",
            "APPLE_NOTARY_ISSUER_ID",
            "FLORALMD_SPARKLE_ED_PRIVATE_KEY",
        ):
            env.pop(name, None)
        result = self.run_command(
            "bash", "scripts/developer-id-prerelease.sh", "--check-secrets", env=env
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required release secret", result.stderr)

    def test_wrong_signing_identity_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary), runtime=True)
            result = self.run_command(
                "bash",
                "scripts/sign-release-code.sh",
                str(app),
                "Developer ID Application: definitely-not-present",
            )
        self.assertNotEqual(result.returncode, 0)

    def test_get_task_allow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(
                Path(temporary), runtime=True, get_task_allow=True
            )
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("get-task-allow", result.stderr)

    def test_missing_hardened_runtime_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary), runtime=False)
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hardened runtime", result.stderr)

    def test_unstapled_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "Fixture.dmg"
            artifact.write_bytes(b"not notarized")
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "stapled",
                str(artifact),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stapled", result.stderr)

    def test_checksum_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            dmg = directory / "Fixture.dmg"
            checksum = directory / "Fixture.sha256"
            dmg.write_bytes(b"fixture bytes")
            checksum.write_text(
                f"{'0' * 64}  {dmg.name}\n", encoding="utf-8"
            )
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "checksum",
                str(dmg),
                str(checksum),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)

    def test_valid_signature_metadata_reaches_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "Fixture.app"
            app.mkdir()
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            codesign = fake_bin / "codesign"
            codesign.write_text(
                """#!/bin/bash
case "$1" in
    --verify)
        exit 0
        ;;
    -dvvv)
        printf '%s\\n' \\
            'CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded' \\
            'Timestamp=Jul 29, 2026 at 12:00:00' \\
            'Authority=Developer ID Application: Fixture' >&2
        exit 0
        ;;
    -d)
        exit 0
        ;;
esac
exit 1
""",
                encoding="utf-8",
            )
            codesign.chmod(0o755)
            env = dict(os.environ)
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = self.run_command(
                "bash",
                "scripts/verify-release-artifact.sh",
                "signed-app",
                str(app),
                env=env,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


class DeveloperIDWorkflowTests(unittest.TestCase):
    def test_release_secrets_are_isolated_to_protected_job(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "developer-id-prerelease.yml"
        ).read_text(encoding="utf-8")
        test_job, release_job = workflow.split("\n  release:\n", maxsplit=1)
        self.assertNotIn("secrets.", test_job)
        self.assertIn("environment: production", release_job)
        self.assertIn("secrets.MACOS_CERTIFICATE_P12_BASE64", release_job)
        self.assertIn("permissions:\n      contents: write", release_job)

    def test_preview_never_updates_stable_feed(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "developer-id-prerelease.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("--prerelease", workflow)
        self.assertNotIn("update-appcast.py", workflow)
        self.assertNotIn("HEAD:feed", workflow)
        self.assertNotIn("ref: feed", workflow)

    def test_actions_are_pinned_to_full_commit_shas(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "developer-id-prerelease.yml"
        ).read_text(encoding="utf-8")
        for line in workflow.splitlines():
            if "uses:" not in line:
                continue
            reference = line.split("@", maxsplit=1)[1].split()[0]
            self.assertRegex(reference, r"^[0-9a-f]{40}$")

    def test_final_dmg_is_not_modified_after_checksum(self) -> None:
        script = (ROOT / "scripts" / "developer-id-prerelease.sh").read_text(
            encoding="utf-8"
        )
        checksum_index = script.index('CHECKSUM="$(dirname "$DMG")')
        self.assertNotIn("codesign --force", script[checksum_index:])
        self.assertNotIn("stapler staple", script[checksum_index:])
        self.assertIn('HASH_BEFORE="$(shasum -a 256 "$DMG"', script)
        self.assertIn('[ "$HASH_BEFORE" = "$HASH_AFTER" ]', script)
        self.assertIn("does not match the app's embedded public key", script)
        self.assertIn('"$SIGN_UPDATE" --verify --ed-key-file -', script)


if __name__ == "__main__":
    unittest.main()
