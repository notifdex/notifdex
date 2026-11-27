import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_APP = ROOT / "tools" / "build-app.sh"
RENDER_CASK = ROOT / "tools" / "render-homebrew-cask.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-macos.yml"
RELEASE_GUIDE = ROOT / "docs" / "release-signing.md"
GITIGNORE = ROOT / ".gitignore"


class ReleaseAndHomebrewContractTests(unittest.TestCase):
    def test_build_app_supports_developer_id_signing_and_preserves_adhoc_fallback(self):
        script = BUILD_APP.read_text(encoding="utf-8")
        for required in (
            "NOTIFDEX_VERSION",
            "NOTIFDEX_BUILD_NUMBER",
            "NOTIFDEX_SIGNING_IDENTITY",
            "NOTIFDEX_EXPECTED_TEAM_ID",
            "--options runtime",
            "--timestamp",
            "--identifier com.notifdex.mac",
            "codesign --verify --deep --strict",
            "codesign --force --sign - --identifier com.notifdex.mac",
            'identifier "com.notifdex.mac"',
            "subject.OU] =",
        ):
            self.assertIn(required, script)

    def test_render_homebrew_cask_generates_valid_cask_and_rejects_bad_inputs(self):
        sha = "a" * 64
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "Casks" / "notifdex.rb"
            res = subprocess.run(
                ["bash", str(RENDER_CASK), "0.1.0", sha, str(out)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)
            cask = out.read_text(encoding="utf-8")
            for required in (
                'cask "notifdex" do',
                'version "0.1.0"',
                f'sha256 "{sha}"',
                'url "https://github.com/notifdex/notifdex/releases/download/v#{version}/Notifdex-#{version}-macOS-universal.zip"',
                'homepage "https://notifdex.com/"',
                'depends_on macos: :sonoma',
                'app "Notifdex.app"',
                'uninstall quit: "com.notifdex.mac"',
                '"~/Library/Application Support/Notifdex"',
            ):
                self.assertIn(required, cask)
            self.assertNotIn('">= :sonoma"', cask)
            self.assertNotIn("rolodex", cask.lower())

        bad_version = subprocess.run(
            ["bash", str(RENDER_CASK), "not-a-version", sha],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(bad_version.returncode, 0)

        bad_sha = subprocess.run(
            ["bash", str(RENDER_CASK), "0.1.0", "shortsha"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(bad_sha.returncode, 0)

    def test_release_workflow_signs_notarizes_staples_verifies_and_cleans_up(self):
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        for required in (
            '"v*.*.*"',
            "workflow_dispatch:",
            "swift test",
            "-warnings-as-errors",
            "NOTIFDEX_UNIVERSAL",
            "bash tools/build-app.sh",
            "bash tools/smoke-app.sh",
            "xcrun notarytool submit",
            "--wait",
            "xcrun notarytool log",
            "xcrun stapler staple dist/Notifdex.app",
            "xcrun stapler validate dist/Notifdex.app",
            "spctl --assess --type execute",
            "bash tools/render-homebrew-cask.sh",
            "HOMEBREW_TAP_DEPLOY_KEY",
            "git@github.com:notifdex/homebrew-tap.git",
            "StrictHostKeyChecking=yes",
            "if: always()",
            "security delete-keychain",
            'rm -rf "$RUNNER_TEMP/tap-ssh"',
        ):
            self.assertIn(required, workflow)

        # GitHub Actions rejects references to `secrets.*` inside step/job `if:` expressions.
        invalid_if_lines = [
            f"line {idx}: {line.strip()}"
            for idx, line in enumerate(workflow.splitlines(), start=1)
            if re.match(r"^\s*if\s*:", line) and "secrets." in line
        ]
        self.assertEqual(
            invalid_if_lines,
            [],
            f"Workflow must not reference secrets.* in if: expressions: {invalid_if_lines}",
        )

    def test_release_guide_and_gitignore_guard_signing_credentials(self):
        guide = RELEASE_GUIDE.read_text(encoding="utf-8")
        self.assertIn("HNH4DY9A2T", guide)
        self.assertIn("brew install --cask notifdex/tap/notifdex", guide)
        self.assertIn("brew upgrade --cask notifdex", guide)

        gitignore = GITIGNORE.read_text(encoding="utf-8")
        for pattern in (
            "*.p12",
            "*.p8",
            "*.cer",
            "*.certSigningRequest",
            "*.provisionprofile",
            "*.mobileprovision",
        ):
            self.assertIn(pattern, gitignore)

    def test_macos_developer_id_cloudkit_production_entitlements_and_workflow_wiring(self):
        import plistlib

        release_ent_path = ROOT / "Resources" / "NotifdexMacRelease.entitlements"
        self.assertTrue(
            release_ent_path.is_file(),
            "Missing Resources/NotifdexMacRelease.entitlements for Developer ID Production CloudKit",
        )
        release_ent = plistlib.loads(release_ent_path.read_bytes())
        self.assertEqual(release_ent.get("com.apple.application-identifier"), "HNH4DY9A2T.com.notifdex.mac")
        self.assertEqual(release_ent.get("com.apple.developer.team-identifier"), "HNH4DY9A2T")
        self.assertEqual(release_ent.get("com.apple.developer.icloud-container-environment"), "Production")
        self.assertEqual(
            release_ent.get("com.apple.developer.icloud-container-identifiers"),
            ["iCloud.com.notifdex.shared"],
        )
        self.assertEqual(release_ent.get("com.apple.developer.icloud-services"), ["CloudKit"])

        dev_ent = plistlib.loads((ROOT / "Resources" / "NotifdexMac.entitlements").read_bytes())
        self.assertEqual(dev_ent.get("com.apple.developer.icloud-container-environment"), "Development")

        script = BUILD_APP.read_text(encoding="utf-8")
        for required in (
            "NOTIFDEX_PROVISIONING_PROFILE",
            "NOTIFDEX_ENTITLEMENTS",
            "embedded.provisionprofile",
            "security cms -D -i",
            "com.apple.developer.icloud-container-environment",
            "com.apple.developer.aps-environment",
        ):
            self.assertIn(required, script)

        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        for required in (
            "APPLE_MAC_CLOUDKIT_PROFILE_BASE64",
            "Resources/NotifdexMacRelease.entitlements",
            "NOTIFDEX_PROVISIONING_PROFILE",
            "NOTIFDEX_ENTITLEMENTS",
            "notifdex-mac-developer-id.provisionprofile",
        ):
            self.assertIn(required, workflow)

        guide = RELEASE_GUIDE.read_text(encoding="utf-8")
        self.assertIn("APPLE_MAC_CLOUDKIT_PROFILE_BASE64", guide)
        self.assertIn("iCloud.com.notifdex.shared", guide)

        ops = (ROOT / "docs" / "operations.md").read_text(encoding="utf-8")
        for required in (
            "com.notifdex.ios",
            "com.notifdex.mac",
            "iCloud.com.notifdex.shared",
            "NotifdexSyncZone",
            "NotifdexSyncBatch",
            "Notifdex macOS Developer ID CloudKit",
            "com.apple.developer.aps-environment",
        ):
            self.assertIn(required, ops)


if __name__ == "__main__":
    unittest.main()
