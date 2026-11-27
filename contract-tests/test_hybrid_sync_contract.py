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

    def test_auto_sync_tla_model_exhaustive_invariants(self):
        """Exhaustive finite-state check mirroring spec/AutoSync.tla."""
        max_failures = 3
        # State: (paired, auto_enabled, sync_state, pending_trigger, failure_streak, in_flight)
        init = (False, True, "idle", False, 0, 0)
        visited = {init}
        queue = collections.deque([init])
        transitions = 0

        def next_states(s):
            paired, auto_en, st, pend, streak, inflight = s
            out = []
            # Pair
            if not paired:
                if st == "running":
                    out.append((True, auto_en, "running", auto_en, streak, inflight))
                else:
                    out.append((True, auto_en, "debouncing" if auto_en else "idle", pend, streak, inflight))
            # Revoke
            if paired:
                out.append((False, auto_en, "running" if st == "running" else "idle", False, 0, inflight))
            # SetAutoEnabled
            for flag in (False, True):
                if flag != auto_en:
                    if not flag and st in ("debouncing", "backoff"):
                        out.append((paired, flag, "idle", False, streak, inflight))
                    elif flag and paired and st == "idle":
                        out.append((paired, flag, "debouncing", pend, streak, inflight))
                    else:
                        out.append((paired, flag, st, pend, streak, inflight))
            # AutoTrigger
            if paired and auto_en:
                if st == "idle":
                    out.append((paired, auto_en, "debouncing", pend, streak, inflight))
                elif st in ("running", "backoff"):
                    out.append((paired, auto_en, st, True, streak, inflight))
                else:
                    out.append(s)
            # ManualTrigger
            if paired:
                if st == "running":
                    out.append((paired, auto_en, st, True, streak, inflight))
                else:
                    out.append((paired, auto_en, "running", False, streak, 1))
            # StartScheduledRun
            if paired and auto_en and st in ("debouncing", "backoff"):
                out.append((paired, auto_en, "running", False, streak, 1))
            # FinishSuccess
            if st == "running":
                next_st = "debouncing" if (paired and auto_en and pend) else "idle"
                out.append((paired, auto_en, next_st, False, 0, 0))
            # FinishFailure
            if st == "running":
                if paired and auto_en:
                    next_streak = streak + 1 if streak < max_failures else max_failures
                    out.append((paired, auto_en, "backoff", True, next_streak, 0))
                else:
                    out.append((paired, auto_en, "idle", False, 0, 0))
            return out

        while queue:
            s = queue.popleft()
            paired, auto_en, st, pend, streak, inflight = s
            # SingleFlight
            self.assertIn(inflight, (0, 1))
            self.assertEqual(st == "running", inflight == 1)
            # UnpairedNeverSchedules
            if not paired:
                self.assertIn(st, ("idle", "running"))
                self.assertFalse(pend)
                self.assertEqual(streak, 0)
            # DisabledAutoNeverArmsTimer
            if not auto_en:
                self.assertIn(st, ("idle", "running"))
            # BackoffBounded
            self.assertLessEqual(streak, max_failures)
            if st == "backoff":
                self.assertGreater(streak, 0)
                self.assertTrue(paired and auto_en)

            for ns in next_states(s):
                transitions += 1
                n_paired, n_auto, n_st, _, _, _ = ns
                # MidSyncTriggerNotDropped
                if st == "running" and paired and auto_en and pend and n_st != "running":
                    self.assertIn(n_st, ("debouncing", "backoff"))
                if ns not in visited:
                    visited.add(ns)
                    queue.append(ns)

        self.assertGreaterEqual(len(visited), 25)
        self.assertGreater(transitions, 100)

