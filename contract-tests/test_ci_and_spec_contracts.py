import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CIAndSpecContractTests(unittest.TestCase):
    def test_every_tla_cfg_is_checked_by_check_model_script(self):
        script = (ROOT / "tools" / "check-model.sh").read_text(encoding="utf-8")
        cfgs = sorted(p.name for p in (ROOT / "spec").glob("*.cfg"))
        self.assertTrue(cfgs, "Expected TLA+ model configurations in spec/")
        missing = [cfg for cfg in cfgs if cfg not in script]
        self.assertEqual(missing, [], f"Unchecked TLA+ configs in tools/check-model.sh: {missing}")

    def test_every_core_sql_resource_is_declared_in_package_and_packager(self):
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        build_app = (ROOT / "tools" / "build-app.sh").read_text(encoding="utf-8")
        sql_files = sorted(p.name for p in (ROOT / "Sources" / "NotifdexCore").glob("*.sql"))
        self.assertTrue(sql_files, "Expected SQL schema files in Sources/NotifdexCore/")
        missing_in_pkg = [name for name in sql_files if f'Sources/NotifdexCore/{name}' not in package]
        self.assertEqual(missing_in_pkg, [], f"SQL files missing from Package.swift: {missing_in_pkg}")
        uses_glob = "Sources/NotifdexCore/*.sql" in build_app
        if not uses_glob:
            missing_in_build = [name for name in sql_files if name not in build_app]
            self.assertEqual(missing_in_build, [], f"SQL files missing from tools/build-app.sh: {missing_in_build}")

    def test_ci_pins_tla_tools_checksum_and_uses_contract_tests(self):
        workflow = (ROOT / ".github" / "workflows" / "checks.yml").read_text(encoding="utf-8")
        self.assertIn("sha256sum -c -", workflow)
        self.assertRegex(workflow, r"[0-9a-f]{64}\s+\$RUNNER_TEMP/tla2tools\.jar")
        self.assertIn("discover -s contract-tests", workflow)
        self.assertIn("-warnings-as-errors", workflow)

    def test_no_python_tests_in_swift_tests_directory(self):
        stray_python = sorted(p.name for p in (ROOT / "Tests").glob("*.py"))
        self.assertEqual(stray_python, [], f"Move Python contract tests to contract-tests/: {stray_python}")
