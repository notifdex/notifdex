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
                'depends_on macos: ">= :sonoma"',
                'app "Notifdex.app"',
                'uninstall quit: "com.notifdex.mac"',
                '"~/Library/Application Support/Notifdex"',
            ):
                self.assertIn(required, cask)
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

    def test_release_guide_and_gitignore_guard_signing_credentials(self):
        guide = RELEASE_GUIDE.read_text(encoding="utf-8")
        self.assertIn("HNH4DY9A2T", guide)
        self.assertIn("brew install --cask notifdex/tap/notifdex", guide)
        self.assertIn("brew upgrade --cask notifdex", guide)

        gitignore = GITIGNORE.read_text(encoding="utf-8")
        for pattern in ("*.p12", "*.p8", "*.cer", "*.certSigningRequest"):
            self.assertIn(pattern, gitignore)


if __name__ == "__main__":
    unittest.main()
