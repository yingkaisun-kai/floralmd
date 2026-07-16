from __future__ import annotations

import importlib.util
import plistlib
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


release_version = load_script("release_version", "validate-release-version.py")
update_appcast = load_script("update_appcast", "update-appcast.py")
changelog_tools = load_script("changelog_tools", "changelog_tools.py")
changelog_html = load_script("changelog_html", "changelog-to-html.py")


class ChangelogToolsTests(unittest.TestCase):
    def bilingual_section(self) -> list[str]:
        return [
            "",
            "### 中文",
            "",
            "#### 修复",
            "- 修复 `<tag>`，并保留 **重点**。",
            "",
            "### English",
            "",
            "#### Fixed",
            "- Fixed `<tag>` while preserving **emphasis** across",
            "  a wrapped bullet line.",
            "",
        ]

    def test_extracts_exact_version_until_next_version_heading(self) -> None:
        lines = [
            "## [2026.7.0] — 2026-07-15\n",
            *[line + "\n" for line in self.bilingual_section()],
            "## [2026.7.01] — 2026-07-16\n",
            "### 中文\n",
        ]
        section = changelog_tools.extract_section("2026.7.0", lines)
        self.assertIn("### English", section)
        self.assertNotIn("## [2026.7.01] — 2026-07-16", section)

    def test_release_markdown_keeps_chinese_block_before_english(self) -> None:
        lines = ["## [2026.7.0] — 2026-07-15\n"] + [
            line + "\n" for line in self.bilingual_section()
        ]
        notes = changelog_tools.release_notes("2026.7.0", lines)
        self.assertLess(notes.index("### 中文"), notes.index("### English"))
        self.assertIn("#### 修复\n- 修复", notes)
        self.assertIn("#### Fixed\n- Fixed", notes)
        self.assertIn("\n  a wrapped bullet line.\n", notes)
        self.assertNotRegex(notes, r"\*\*(?:中文|English)[：:]\*\*")

    def test_missing_language_block_is_rejected_for_calver(self) -> None:
        section = ["### 中文", "", "#### 修复", "- 修复问题。"]
        with self.assertRaisesRegex(
            changelog_tools.ChangelogFormatError, "exactly one '### English'"
        ):
            changelog_tools.validate_section("2026.7.0", section)

    def test_omitted_specific_categories_are_allowed(self) -> None:
        section = self.bilingual_section()
        changelog_tools.validate_section("2026.7.0", section)

    def test_language_without_any_category_is_rejected(self) -> None:
        section = [
            "### 中文",
            "- 中文说明。",
            "### English",
            "#### Fixed",
            "- English note.",
        ]
        with self.assertRaisesRegex(
            changelog_tools.ChangelogFormatError, "at least one 中文 category"
        ):
            changelog_tools.validate_section("2026.7.0", section)

    def test_missing_version_keeps_empty_output_contract(self) -> None:
        lines = ["## [2026.7.0] — 2026-07-15\n"]
        self.assertEqual(changelog_tools.release_notes("2026.7.9", lines), "")
        self.assertEqual(changelog_tools.extract_section("2026.7.9", lines), [])

    def test_inline_language_labels_are_rejected(self) -> None:
        section = self.bilingual_section()
        section.insert(4, "- **中文：**旧格式。")
        with self.assertRaisesRegex(
            changelog_tools.ChangelogFormatError, "inline language label"
        ):
            changelog_tools.validate_section("2026.7.0", section)

    def test_sparkle_html_renders_headings_bullets_and_safe_inline_markup(self) -> None:
        body = changelog_html.to_html(
            changelog_tools.trim_section(self.bilingual_section())
        )
        self.assertIn("<h3>中文</h3>", body)
        self.assertIn("<h4>修复</h4>", body)
        self.assertIn("<h3>English</h3>", body)
        self.assertIn("<h4>Fixed</h4>", body)
        self.assertIn("<code>&lt;tag&gt;</code>", body)
        self.assertIn("<strong>emphasis</strong>", body)
        self.assertIn("preserving <strong>emphasis</strong> across a wrapped", body)
        self.assertNotIn("**", body)
        self.assertNotIn("`<tag>`", body)

    def test_repository_calver_notes_follow_bilingual_contract(self) -> None:
        lines = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8").splitlines(True)
        notes = changelog_tools.release_notes("2026.7.0", lines)
        html = changelog_html.to_html(
            changelog_tools.trim_section(
                changelog_tools.extract_section("2026.7.0", lines)
            )
        )
        self.assertTrue(notes.startswith("### 中文\n"))
        self.assertLess(notes.index("### 中文"), notes.index("### English"))
        self.assertNotRegex(notes, r"\*\*(?:中文|English)[：:]\*\*")
        self.assertNotIn("**", html)


class ReleaseVersionTests(unittest.TestCase):
    def test_accepts_first_calver_release(self) -> None:
        release_version.validate_release(
            version="2026.7.0", tag="v2026.7.0", build="1"
        )

    def test_accepts_next_patch_in_same_month(self) -> None:
        release_version.validate_release(
            version="2026.7.1",
            tag="v2026.7.1",
            build="2",
            previous_version="2026.7.0",
            previous_build="1",
        )

    def test_accepts_first_release_in_later_month(self) -> None:
        release_version.validate_release(
            version="2026.9.0",
            tag="v2026.9.0",
            build="3",
            previous_version="2026.7.1",
            previous_build="2",
        )

    def test_rejects_zero_padded_month(self) -> None:
        with self.assertRaisesRegex(ValueError, "not FloralMD CalVer"):
            release_version.parse_calver("2026.07.0")

    def test_rejects_legacy_tag_for_new_release(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be exactly"):
            release_version.validate_release(
                version="2026.7.0", tag="v0.2.0", build="1"
            )

    def test_rejects_nonpositive_build(self) -> None:
        with self.assertRaisesRegex(ValueError, "positive integer"):
            release_version.validate_release(
                version="2026.7.0", tag="v2026.7.0", build="0"
            )

    def test_build_reset_is_only_valid_without_a_public_parent(self) -> None:
        with self.assertRaisesRegex(ValueError, "greater than previous"):
            release_version.validate_release(
                version="2026.7.0",
                tag="v2026.7.0",
                build="1",
                previous_build="6",
            )

    def test_rejects_skipped_patch_in_same_month(self) -> None:
        with self.assertRaisesRegex(ValueError, "not the next"):
            release_version.validate_successor("2026.7.0", "2026.7.2")

    def test_rejects_nonzero_patch_in_new_month(self) -> None:
        with self.assertRaisesRegex(ValueError, "not the next"):
            release_version.validate_successor("2026.7.2", "2026.8.1")

    def test_rejects_reused_build_number(self) -> None:
        with self.assertRaisesRegex(ValueError, "greater than previous"):
            release_version.validate_release(
                version="2026.7.1",
                tag="v2026.7.1",
                build="1",
                previous_version="2026.7.0",
                previous_build="1",
            )

    def test_repository_metadata_is_internally_consistent(self) -> None:
        with (ROOT / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        version = info["CFBundleShortVersionString"]
        build = info["CFBundleVersion"]
        release_version.validate_release(
            version=version, tag=f"v{version}", build=build
        )
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn(f"\n## [{version}] — ", changelog)


class AppcastTests(unittest.TestCase):
    def make_args(self, version: str, build: str):
        return type(
            "Args",
            (),
            {
                "version": version,
                "build": build,
                "url": f"https://example.invalid/FloralMD-{version}.dmg",
                "signature": "test-signature",
                "length": 123,
                "pub_date": "Wed, 15 Jul 2026 00:00:00 +0000",
                "description_file": None,
            },
        )()

    def test_calver_item_uses_short_version_and_build(self) -> None:
        item = update_appcast.make_item(self.make_args("2026.7.0", "1"))
        self.assertIn('sparkle:shortVersionString="2026.7.0"', item)
        self.assertIn('sparkle:version="1"', item)
        self.assertIn("FloralMD-2026.7.0.dmg", item)


class WorkflowConfigurationTests(unittest.TestCase):
    def test_ci_and_release_use_macos_26_with_isolated_cache(self) -> None:
        for workflow in ("ci.yml", "release.yml"):
            text = (ROOT / ".github" / "workflows" / workflow).read_text(
                encoding="utf-8"
            )
            self.assertIn("runs-on: macos-26", text)
            self.assertIn("spm-v3-macos26-", text)
            self.assertNotIn("runs-on: macos-14", text)

    def test_release_checksum_uses_portable_asset_name(self) -> None:
        text = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            '(cd build && shasum -a 256 "FloralMD-${VERSION}.dmg" '
            '> "FloralMD-${VERSION}.sha256")',
            text,
        )
        self.assertNotIn('shasum -a 256 "$DMG"', text)

    def test_release_notes_use_shared_validated_extractor(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        local_release = (ROOT / "scripts" / "release.sh").read_text(
            encoding="utf-8"
        )
        expected = 'python3 scripts/extract-release-notes.py "$APP_VERSION"'
        self.assertIn(expected, workflow)
        self.assertIn(
            'python3 scripts/extract-release-notes.py "$VERSION"', local_release
        )
        self.assertNotIn('awk "BEGIN{p=0} /^## \\[', workflow)
        self.assertNotIn('awk "BEGIN{p=0} /^## \\[', local_release)


class QuickLookBundleConfigurationTests(unittest.TestCase):
    def test_quick_look_source_plists_use_non_release_placeholders(self) -> None:
        for relative_path in (
            "Resources/QuickLook/Info.plist",
            "Resources/Debug/QuickLook-Info.plist",
        ):
            with (ROOT / relative_path).open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info.get("CFBundleShortVersionString"), "0.0.0")
            self.assertEqual(info.get("CFBundleVersion"), "0")

    def test_quick_look_variants_declare_and_embed_the_app_icon(self) -> None:
        for relative_path in (
            "Resources/QuickLook/Info.plist",
            "Resources/Debug/QuickLook-Info.plist",
        ):
            with (ROOT / relative_path).open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info.get("CFBundleIconFile"), "AppIcon")

        script = (ROOT / "scripts" / "build-app.sh").read_text(encoding="utf-8")
        self.assertIn(
            'cp Resources/AppIcon.icns "${QUICK_LOOK_BUNDLE}/Contents/Resources/AppIcon.icns"',
            script,
        )
        self.assertIn("Quick Look extension icon differs from the host app icon", script)
        self.assertIn("Quick Look extension version differs from the host app version", script)
        self.assertIn("Quick Look extension build differs from the host app build", script)


class ProductionUpdateIntegrationTests(unittest.TestCase):
    def test_app_menu_is_compiled_only_for_production(self) -> None:
        source = (ROOT / "Sources" / "floralmd" / "App" / "main.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("#if FLORALMD_PRODUCTION\nimport Sparkle\n#endif", source)
        self.assertIn("SPUStandardUpdaterController", source)
        self.assertIn('AppCopy.text("Check for Updates…", "检查更新…")', source)
        self.assertIn("#selector(SPUStandardUpdaterController.checkForUpdates(_:))", source)
        self.assertIn("checkForUpdates.target = updaterController", source)

    def test_bundle_builder_enforces_update_variant_contract(self) -> None:
        script = (ROOT / "scripts" / "build-app.sh").read_text(encoding="utf-8")
        self.assertIn("Debug binary contains the production update menu", script)
        self.assertIn("Production bundle has the wrong Sparkle feed URL", script)
        self.assertIn("Production bundle does not link and embed Sparkle", script)
        self.assertIn("Production binary has no manual update menu", script)


if __name__ == "__main__":
    unittest.main()
