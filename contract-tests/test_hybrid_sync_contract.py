import collections
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class HybridSyncContractTests(unittest.TestCase):
    def test_hybrid_sync_tla_model_exhaustive_invariants(self):
        """Exhaustive finite-state check mirroring spec/HybridSync.tla (including pushDirty & PushFail)."""
        mac, iphone = "mac", "iphone"
        vis, hid = "visibleAlert", "hiddenAlert"
        max_ver = 1

        # State tuple:
        # (mac_st, ios_st, mac_obs, ios_obs, cloud_obs,
        #  mac_flag, ios_flag, mac_ver, ios_ver, cloud_flag, cloud_ver, cloud_del,
        #  mac_dirty, ios_dirty, mac_fwd_healthy)
        init = (
            "local_only", "local_only",
            frozenset(), frozenset(), frozenset(),
            False, False, 0, 0, False, 0, False,
            False, False, True,
        )

        visited = {init}
        queue = collections.deque([init])
        transitions = 0
        saw_outage_warning = False
        saw_recovery_dual_capture = False

        def next_states(s):
            (mst, ist, mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd) = s
            out = []
            # PairDevice
            if mst == "local_only":
                out.append(("paired", ist, mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel,
                            bool(mobs) or mver > 0, idir, mfwd))
            if ist == "local_only":
                out.append((mst, "paired", mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel,
                            mdir, bool(iobs) or iver > 0, mfwd))
            # RevokeDevice
            if mst == "paired":
                out.append(("revoked", ist, mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd))
            if ist == "paired":
                out.append((mst, "revoked", mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd))
            # SetMacForwarding
            out.append((mst, ist, mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, not mfwd))
            # MacCapture
            for a in (vis, hid):
                if a == vis and not mfwd:
                    continue
                if (a, mac) not in mobs:
                    out.append((mst, ist, mobs | {(a, mac)}, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel,
                                True if a != hid else mdir, idir, mfwd))
            # IPhoneCapture (independent of macForwardingHealthy)
            if (vis, iphone) not in iobs:
                out.append((mst, ist, mobs, iobs | {(vis, iphone)}, cobs, mflg, iflg, mver, iver, cflg, cver, cdel,
                            mdir, True, mfwd))
            # PushObservations
            if mst == "paired" and mdir and not cdel:
                elig = frozenset(o for o in mobs if o[0] != hid)
                if elig - cobs:
                    out.append((mst, ist, mobs, iobs, cobs | elig, mflg, iflg, mver, iver, cflg, cver, cdel,
                                mver > cver, idir, mfwd))
            if ist == "paired" and idir and not cdel:
                elig = frozenset(o for o in iobs if o[0] != hid)
                if elig - cobs:
                    out.append((mst, ist, mobs, iobs, cobs | elig, mflg, iflg, mver, iver, cflg, cver, cdel,
                                mdir, iver > cver, mfwd))
            # PushFail (no-op preserving dirty flag)
            if (mst == "paired" and mdir) or (ist == "paired" and idir):
                out.append(s)
            # PullObservations
            if mst == "paired" and (cobs - mobs):
                out.append((mst, ist, mobs | cobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd))
            if ist == "paired" and (cobs - iobs):
                out.append((mst, ist, mobs, iobs | cobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd))
            # LocalWorkflowEdit
            if mver < max_ver:
                for nf in (False, True):
                    out.append((mst, ist, mobs, iobs, cobs, nf, iflg, mver + 1, iver, cflg, cver, cdel, True, idir, mfwd))
            if iver < max_ver:
                for nf in (False, True):
                    out.append((mst, ist, mobs, iobs, cobs, mflg, nf, mver, iver + 1, cflg, cver, cdel, mdir, True, mfwd))
            # PushWorkflow
            if mst == "paired" and not cdel and mver > cver:
                elig = frozenset(o for o in mobs if o[0] != hid)
                out.append((mst, ist, mobs, iobs, cobs, mflg, iflg, mver, iver, mflg, mver, cdel,
                            bool(elig - cobs), idir, mfwd))
            if ist == "paired" and not cdel and iver > cver:
                elig = frozenset(o for o in iobs if o[0] != hid)
                out.append((mst, ist, mobs, iobs, cobs, mflg, iflg, mver, iver, iflg, iver, cdel,
                            mdir, bool(elig - cobs), mfwd))
            # PullWorkflow
            if mst == "paired" and not cdel and cver > mver:
                out.append((mst, ist, mobs, iobs, cobs, cflg, iflg, cver, iver, cflg, cver, cdel, mdir, idir, mfwd))
            if ist == "paired" and not cdel and cver > iver:
                out.append((mst, ist, mobs, iobs, cobs, mflg, cflg, mver, cver, cflg, cver, cdel, mdir, idir, mfwd))
            # CommitDeleteTombstone
            if (mst == "paired" or ist == "paired") and not cdel and cobs:
                out.append((mst, ist, mobs, iobs, frozenset(), mflg, iflg, mver, iver, cflg, cver, True, mdir, idir, mfwd))
            return out

        while queue:
            s = queue.popleft()
            (mst, ist, mobs, iobs, cobs, mflg, iflg, mver, iver, cflg, cver, cdel, mdir, idir, mfwd) = s

            # HiddenNeverLeaksToCloudOrIPhone
            for o in cobs:
                self.assertNotEqual(o[0], hid)
            for o in iobs:
                self.assertNotEqual(o[0], hid)
            # TombstoneBlocksResurrection
            if cdel:
                self.assertEqual(cobs, frozenset())
            # DirtyFlagProtectsUnpushedData
            if mst == "paired" and not cdel:
                if any(o[0] != hid and o not in cobs for o in mobs):
                    self.assertTrue(mdir, f"Mac dirty flag lost unpushed data: {s}")
            if ist == "paired" and not cdel:
                if any(o[0] != hid and o not in cobs for o in iobs):
                    self.assertTrue(idir, f"iPhone dirty flag lost unpushed data: {s}")
            # ForwardingHealthSoundness
            warning = (mst == "paired") and ((vis, iphone) in mobs) and ((vis, mac) not in mobs)
            if mst != "paired":
                self.assertFalse(warning)
            if (vis, mac) in mobs:
                self.assertFalse(warning)
            if warning:
                self.assertTrue(any(o[0] == vis for o in mobs))
                if not mfwd:
                    saw_outage_warning = True
            if mfwd and (vis, iphone) in mobs and (vis, mac) in mobs:
                saw_recovery_dual_capture = True

            for ns in next_states(s):
                transitions += 1
                (nmst, nist, nmobs, niobs, ncobs, nmflg, niflg, nmver, niver, ncflg, ncver, ncdel, _, _, _) = ns
                self.assertTrue(mobs.issubset(nmobs))
                self.assertTrue(iobs.issubset(niobs))
                self.assertGreaterEqual(ncver, cver)
                if cdel:
                    self.assertTrue(ncdel)
                if ncobs != cobs or ncver != cver or ncdel != cdel:
                    self.assertTrue(mst == "paired" or ist == "paired")
                if mst != "paired" and nmobs != mobs:
                    for added in nmobs - mobs:
                        self.assertEqual(added[1], mac)
                if ist != "paired" and niobs != iobs:
                    for added in niobs - iobs:
                        self.assertEqual(added[1], iphone)

                if ns not in visited:
                    visited.add(ns)
                    queue.append(ns)

        self.assertGreater(len(visited), 1000)
        self.assertGreater(transitions, 5000)
        self.assertTrue(saw_outage_warning, "Outage warning state must be reachable")
        self.assertTrue(saw_recovery_dual_capture, "Recovery dual-capture state must be reachable")

    def test_cloudkit_entitlements_and_build_script_contract(self):
        ios_ent = ROOT / "ios" / "NotifdexiOS" / "NotifdexiOS.entitlements"
        self.assertTrue(ios_ent.is_file(), "Missing ios/NotifdexiOS/NotifdexiOS.entitlements")
        ios_ent_text = ios_ent.read_text(encoding="utf-8")
        self.assertIn("iCloud.com.notifdex.shared", ios_ent_text)
        self.assertIn("CloudKit", ios_ent_text)

        pbxproj = (ROOT / "ios" / "NotifdexiOS.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("CODE_SIGN_ENTITLEMENTS = NotifdexiOS/NotifdexiOS.entitlements;", pbxproj)

        mac_ent = ROOT / "Resources" / "NotifdexMac.entitlements"
        self.assertTrue(mac_ent.is_file(), "Missing Resources/NotifdexMac.entitlements")
        mac_ent_text = mac_ent.read_text(encoding="utf-8")
        self.assertIn("iCloud.com.notifdex.shared", mac_ent_text)
        self.assertIn("CloudKit", mac_ent_text)
        self.assertIn("com.apple.application-identifier", mac_ent_text)
        self.assertIn("HNH4DY9A2T.com.notifdex.mac", mac_ent_text)
        self.assertIn("com.apple.developer.team-identifier", mac_ent_text)

        build_app = (ROOT / "tools" / "build-app.sh").read_text(encoding="utf-8")
        self.assertIn("NOTIFDEX_PROVISIONING_PROFILE", build_app)
        self.assertIn("Resources/NotifdexMac.entitlements", build_app)

