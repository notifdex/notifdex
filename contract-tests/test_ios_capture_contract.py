import collections
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class IOSCaptureContractTests(unittest.TestCase):
    def test_ios_capture_tla_model_exhaustive_invariants(self):
        """Exhaustive finite-state check mirroring spec/IOSCapture.tla."""
        apps = ("x", "gmail")
        events = ("evX", "evGmail")
        app_of = {"evX": "x", "evGmail": "gmail"}
        no_event = None

        # State tuple:
        # (selected, configured, verified, paused, in_flight, stored, acknowledged, last_result)
        init = (
            frozenset(apps),
            frozenset(),
            frozenset(),
            False,
            no_event,
            frozenset(),
            frozenset(),
            "none",
        )

        visited = {init}
        queue = collections.deque([init])
        transitions_checked = 0

        def next_states(state):
            selected, configured, verified, paused, in_flight, stored, ack, last_result = state
            out = []

            # ToggleSelectedApp(a)
            for a in apps:
                new_sel = selected - {a} if a in selected else selected | {a}
                out.append((new_sel, configured, verified, paused, in_flight, stored, ack, last_result))

            # SetPaused(b)
            out.append((selected, configured, verified, not paused, in_flight, stored, ack, last_result))

            # ConfigureAutomation(a)
            for a in apps:
                if a not in configured:
                    out.append((selected, configured | {a}, verified, paused, in_flight, stored, ack, last_result))

            # DisableAutomation(a)
            for a in apps:
                if a in configured:
                    out.append((selected, configured - {a}, verified, paused, in_flight, stored, ack, last_result))

            # ShortcutInvoke(e)
            if in_flight is no_event:
                for e in events:
                    if app_of[e] in configured:
                        out.append((
                            selected, configured, verified | {app_of[e]}, paused, e, stored, ack, last_result
                        ))

            # IntentSkip
            if in_flight is not no_event and (paused or app_of[in_flight] not in selected):
                out.append((selected, configured, verified, paused, no_event, stored, ack, "skipped"))

            # IntentCommitNew
            if (
                in_flight is not no_event
                and not paused
                and app_of[in_flight] in selected
                and in_flight not in stored
            ):
                out.append((
                    selected, configured, verified, paused, no_event,
                    stored | {in_flight}, ack | {in_flight}, "captured"
                ))

            # IntentCommitDuplicate
            if (
                in_flight is not no_event
                and not paused
                and app_of[in_flight] in selected
                and in_flight in stored
            ):
                out.append((
                    selected, configured, verified, paused, no_event,
                    stored, ack | {in_flight}, "duplicate"
                ))

            # IntentCommitFail
            if (
                in_flight is not no_event
                and not paused
                and app_of[in_flight] in selected
                and in_flight not in stored
            ):
                out.append((selected, configured, verified, paused, no_event, stored, ack, "failed"))

            return out

        while queue:
            s = queue.popleft()
            selected, configured, verified, paused, in_flight, stored, ack, last_result = s

            # Invariant: AcknowledgedIsDurable
            self.assertTrue(ack.issubset(stored), f"AcknowledgedIsDurable violated: {s}")
            # Invariant: StoredImpliesVerifiedApp
            for e in stored:
                self.assertIn(app_of[e], verified, f"StoredImpliesVerifiedApp violated: {s}")

            for ns in next_states(s):
                transitions_checked += 1
                n_sel, _, n_ver, _, n_inf, n_sto, n_ack, n_res = ns

                # Action property: DurableNeverDisappears
                self.assertTrue(stored.issubset(n_sto), f"DurableNeverDisappears violated: {s} -> {ns}")

                # Action property: SkipAndFailNeverWrite
                if in_flight is not no_event and n_inf is no_event and n_res in ("skipped", "failed"):
                    self.assertEqual(n_sto, stored)
                    self.assertEqual(n_ack, ack)
                if in_flight is not no_event and n_inf is no_event and (paused or app_of[in_flight] not in selected):
                    self.assertEqual(n_sto, stored)
                    self.assertEqual(n_res, "skipped")

                # Action property: ToggleNeverFabricatesVerification
                if n_sel != selected:
                    self.assertEqual(n_ver, verified)
                    self.assertEqual(n_sto, stored)

                if ns not in visited:
                    visited.add(ns)
                    queue.append(ns)

        self.assertGreater(len(visited), 100)
        self.assertGreater(transitions_checked, 500)

    def test_ios_project_is_isolated_from_macos_package(self):
        package_swift = (ROOT / "Package.swift").read_text(encoding="utf-8")
        self.assertIn('"ios"', package_swift)
        self.assertNotIn("ios/", package_swift)
        self.assertTrue((ROOT / "ios" / "NotifdexiOS.xcodeproj" / "project.pbxproj").is_file())
        intent_swift = (ROOT / "ios" / "NotifdexiOS" / "Intents" / "CaptureNotificationIntent.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("CaptureNotificationIntent: AppIntent", intent_swift)
        self.assertIn("var app: String", intent_swift)
        self.assertIn("var title: String?", intent_swift)
        self.assertIn("var subtitle: String?", intent_swift)
        self.assertIn("var body: String?", intent_swift)
        self.assertIn("supportedModes: IntentModes = .background", intent_swift)
        self.assertIn("authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed", intent_swift)

    def test_ios_testflight_app_store_readiness_contract(self):
        import plistlib
        import struct

        # AppIcon.png must be an opaque 1024x1024 PNG (color type 2 = RGB, no alpha channel).
        icon_path = ROOT / "ios" / "NotifdexiOS" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
        self.assertTrue(icon_path.is_file(), "Missing iOS AppIcon.png")
        raw = icon_path.read_bytes()
        self.assertEqual(raw[:8], b"\x89PNG\r\n\x1a\n", "AppIcon.png must be a valid PNG")
        width, height, _bit_depth, color_type = struct.unpack(">IIBB", raw[16:26])
        self.assertEqual((width, height), (1024, 1024), "iOS AppIcon.png must be 1024x1024")
        self.assertEqual(color_type, 2, "iOS AppIcon.png must be opaque RGB (no alpha channel) for App Store Connect")

        # PrivacyInfo.xcprivacy must exist, declare no tracking, and be bundled in Resources.
        privacy_path = ROOT / "ios" / "NotifdexiOS" / "PrivacyInfo.xcprivacy"
        self.assertTrue(privacy_path.is_file(), "Missing ios/NotifdexiOS/PrivacyInfo.xcprivacy")
        privacy = plistlib.loads(privacy_path.read_bytes())
        self.assertFalse(privacy.get("NSPrivacyTracking", True))
        self.assertEqual(privacy.get("NSPrivacyCollectedDataTypes"), [])

        pbxproj = (ROOT / "ios" / "NotifdexiOS.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("PrivacyInfo.xcprivacy in Resources", pbxproj)

        # Info.plist must declare remote-notification background mode and export compliance exemption.
        info_plist = plistlib.loads((ROOT / "ios" / "NotifdexiOS" / "Info.plist").read_bytes())
        self.assertIn("remote-notification", info_plist.get("UIBackgroundModes", []))
        self.assertIs(info_plist.get("ITSAppUsesNonExemptEncryption"), False)

        # Entitlements must include APNs environment alongside CloudKit container.
        ent = plistlib.loads((ROOT / "ios" / "NotifdexiOS" / "NotifdexiOS.entitlements").read_bytes())
        self.assertIn("aps-environment", ent)
        self.assertIn("iCloud.com.notifdex.shared", ent.get("com.apple.developer.icloud-container-identifiers", []))
