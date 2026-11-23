import re
import unittest
from pathlib import Path


APP_SOURCES = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexApp"


class MacOSBuildContractTests(unittest.TestCase):
    def test_app_avoids_swiftui_state_macro(self):
        # The macOS 27 standalone Command Line Tools build failed when @State
        # needed a SwiftUI macro plugin that was absent on that toolchain.
        state_attribute = re.compile(r"^\s*@(?:SwiftUI\.)?State\b", re.MULTILINE)
        violations = []
        for source in sorted(APP_SOURCES.rglob("*.swift")):
            text = source.read_text(encoding="utf-8")
            for match in state_attribute.finditer(text):
                line = text.count("\n", 0, match.end()) + 1
                violations.append(f"{source.relative_to(APP_SOURCES)}:{line}")
        self.assertEqual(violations, [], "Use observable model state in the macOS app.")
