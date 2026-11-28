import collections
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class StorageCleanupContractTests(unittest.TestCase):
    def test_storage_cleanup_tla_model_exhaustive_invariants(self):
        """Exhaustive finite-state check mirroring spec/StorageCleanup.tla."""
        old_norm, old_prot, rec_norm, rec_prot = "old_n", "old_p", "rec_n", "rec_p"
        all_obs = frozenset({old_norm, old_prot, rec_norm, rec_prot})
        old_obs = frozenset({old_norm, old_prot})
        prot_obs = frozenset({old_prot, rec_prot})
        user_data = frozenset({"people", "notes", "workspaces", "rules"})

        # State: (obs, pending, user_data, phase, wal_pending, pruned_old, pruned_all, integrity_ok, used_clear_all)
        init = (all_obs, frozenset(), user_data, "idle", False, False, False, True, False)
        visited = {init}
        queue = collections.deque([init])
        transitions = 0

        def next_states(s):
            obs, pend, udata, phase, wal, p_old, p_all, ok, clear_all = s
            out = []
            if phase == "idle":
                targets = frozenset(o for o in obs if o in old_obs and o not in prot_obs)
                if targets:
                    out.append((obs, targets, udata, "deleting_age", wal, p_old, p_all, ok, clear_all))
                if obs:
                    out.append((obs, obs, udata, "deleting_all", wal, p_old, p_all, ok, clear_all))
                if wal:
                    out.append((obs, pend, udata, "idle", False, p_old, p_all, ok, clear_all))
                for o in (old_norm, rec_norm):
                    if o not in obs and not (p_old and o in old_obs) and not p_all:
                        out.append((obs | {o}, pend, udata, "idle", wal, p_old, p_all, ok, clear_all))
            elif phase in ("deleting_age", "deleting_all"):
                # CommitDelete
                out.append((
                    obs - pend, frozenset(), udata, "vacuuming", True, True,
                    True if phase == "deleting_all" else p_all, ok,
                    True if phase == "deleting_all" else clear_all
                ))
                # CrashDuringDelete (atomic rollback)
                out.append((obs, frozenset(), udata, "idle", wal, p_old, p_all, ok, clear_all))
            elif phase == "vacuuming":
                # CompleteMaintenance
                out.append((obs, pend, udata, "idle", False, p_old, p_all, ok, clear_all))
                # InterruptMaintenance
                out.append((obs, pend, udata, "idle", wal, p_old, p_all, ok, clear_all))
            return out

        while queue:
            s = queue.popleft()
            obs, pend, udata, phase, wal, p_old, p_all, ok, clear_all = s
            self.assertEqual(udata, user_data)
            self.assertTrue(ok)
            if not clear_all:
                self.assertTrue(prot_obs.issubset(obs))
            if p_old:
                self.assertNotIn(old_norm, obs)

            for ns in next_states(s):
                transitions += 1
                nobs, _, _, nphase, _, np_old, np_all, _, _ = ns
                if phase in ("deleting_age", "deleting_all") and nphase == "idle":
                    self.assertEqual(nobs, obs)
                if p_old:
                    self.assertTrue(np_old)
                if p_all:
                    self.assertTrue(np_all)
                if ns not in visited:
                    visited.add(ns)
                    queue.append(ns)

        self.assertGreaterEqual(len(visited), 10)
        self.assertGreaterEqual(transitions, 15)
        self.assertTrue((ROOT / "spec" / "StorageCleanup.tla").is_file())
        self.assertTrue((ROOT / "spec" / "StorageCleanup.cfg").is_file())

    def test_macos_and_ios_expose_storage_management_with_confirmation(self):
        mac_view = ROOT / "Sources" / "NotifdexApp" / "StorageManagementView.swift"
        ios_view = ROOT / "ios" / "NotifdexiOS" / "UI" / "StorageManagementView.swift"
        core_file = ROOT / "Sources" / "NotifdexCore" / "StorageManagement.swift"
        self.assertTrue(core_file.is_file())
        self.assertTrue(mac_view.is_file())
        self.assertTrue(ios_view.is_file())
        mac_text = mac_view.read_text(encoding="utf-8")
        ios_text = ios_view.read_text(encoding="utf-8")
        self.assertIn("Storage & Cleanup", mac_text)
        self.assertIn("Clear all notification history", mac_text)
        self.assertIn("confirmingStorageCleanup", mac_text)
        self.assertIn("Storage & Cleanup", ios_text)
        self.assertIn("Clear All Notification History", ios_text)
        self.assertIn("confirmationDialog", ios_text)


if __name__ == "__main__":
    unittest.main()
