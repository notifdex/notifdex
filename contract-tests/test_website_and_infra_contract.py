import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEBSITE = ROOT / "website"
INFRA = ROOT / "infra" / "cloudflare"
WORKFLOWS = ROOT / ".github" / "workflows"


class WebsiteAndCloudflareInfraContractTests(unittest.TestCase):
    def test_website_build_and_check_scripts_pass(self):
        build = subprocess.run(
            ["npm", "run", "build"],
            cwd=WEBSITE,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(build.returncode, 0, msg=build.stdout + build.stderr)

        check = subprocess.run(
            ["npm", "run", "check"],
            cwd=WEBSITE,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(check.returncode, 0, msg=check.stdout + check.stderr)

    def test_website_avoids_rolodex_branding_and_includes_required_links(self):
        src_dir = WEBSITE / "src"
        text_suffixes = {".html", ".css", ".js", ".svg", ".txt", ".xml", ""}
        combined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(src_dir.iterdir())
            if path.is_file() and path.suffix in text_suffixes
        )
        self.assertIsNone(re.search(r"\brolodex\b", combined, re.IGNORECASE))

        self.assertTrue((src_dir / "app-icon.png").is_file())
        self.assertTrue((src_dir / "favicon.png").is_file())

        index_html = (src_dir / "index.html").read_text(encoding="utf-8")
        self.assertIn('rel="canonical" href="https://notifdex.com/"', index_html)
        self.assertIn("/app-icon.png", index_html)
        self.assertIn("https://github.com/notifdex/notifdex#run-the-menu-bar-app", index_html)
        self.assertIn("https://github.com/notifdex/notifdex/issues", index_html)
        self.assertIn('href="/privacy.html"', index_html)

        styles_css = (src_dir / "styles.css").read_text(encoding="utf-8")
        self.assertIn("scroll-margin-top:", styles_css)
        self.assertIn('html[data-theme="dark"]', styles_css)
        self.assertIn('id="theme-toggle"', index_html)

        headers = (src_dir / "_headers").read_text(encoding="utf-8")
        self.assertIn("https://notifdex.pages.dev/*", headers)
        self.assertIn("https://*.notifdex.pages.dev/*", headers)
        self.assertIn("X-Robots-Tag: noindex, nofollow", headers)

    def test_opentofu_versions_lockfile_and_r2_backend_contract(self):
        version_pin = (INFRA / ".opentofu-version").read_text(encoding="utf-8").strip()
        self.assertRegex(version_pin, r"^\d+\.\d+\.\d+$")

        lockfile = (INFRA / ".terraform.lock.hcl").read_text(encoding="utf-8")
        self.assertIn('provider "registry.opentofu.org/cloudflare/cloudflare"', lockfile)

        backend_example = (INFRA / "backend.hcl.example").read_text(encoding="utf-8")
        self.assertIn('bucket                      = "notifdex-tfstate"', backend_example)
        self.assertNotIn("ie-tfstate", backend_example)
        self.assertIn("use_lockfile                = true", backend_example)

        main_tf = (INFRA / "main.tf").read_text(encoding="utf-8")
        for required_snippet in (
            'resource "cloudflare_pages_project" "website"',
            'resource "cloudflare_pages_domain" "apex"',
            'resource "cloudflare_dns_record" "apex"',
            'resource "cloudflare_dns_record" "www"',
            'resource "cloudflare_ruleset" "canonical_redirects"',
            'phase       = "http_request_dynamic_redirect"',
            "preserve_query_string = true",
            "status_code           = 301",
            'setting_id = "ssl"',
            'setting_id = "always_use_https"',
            'setting_id = "min_tls_version"',
            'path_includes                  = ["website/*"]',
        ):
            self.assertIn(required_snippet, main_tf)
        # Cloudflare Pages watch paths use single-* wildcards (matching '/'); '**' silently skips all builds.
        self.assertNotIn('"website/**"', main_tf)

    def test_workflows_and_gitignore_isolate_website_and_protect_infra_applies(self):
        version_pin = (INFRA / ".opentofu-version").read_text(encoding="utf-8").strip()

        website_ci = (WORKFLOWS / "website-ci.yml").read_text(encoding="utf-8")
        self.assertIn('"website/**"', website_ci)
        self.assertIn("npm run build", website_ci)
        self.assertIn("npm run check", website_ci)

        infra_ci = (WORKFLOWS / "cloudflare-infra.yml").read_text(encoding="utf-8")
        self.assertIn(f'tofu_version: "{version_pin}"', infra_ci)
        self.assertIn("tofu fmt -check", infra_ci)
        self.assertIn("tofu validate", infra_ci)
        self.assertIn("environment: cloudflare-prod", infra_ci)
        self.assertIn("github.ref == 'refs/heads/main'", infra_ci)
        self.assertIn("group: cloudflare-infra", infra_ci)
        self.assertIn("cancel-in-progress: false", infra_ci)
        self.assertIn("confirm_commit", infra_ci)

        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for ignored in (
            "website/dist/",
            "infra/**/.terraform/",
            "infra/**/*.tfstate",
            "infra/**/backend.hcl",
            "infra/**/*.tfvars",
        ):
            self.assertIn(ignored, gitignore)
