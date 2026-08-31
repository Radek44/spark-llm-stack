#!/usr/bin/env python3
"""Deterministic contract checks for the Qwen/SGLang broker lifecycle adapter."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path


sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "scripts/qwen-sglang-broker-lifecycle"
REGISTRY_FINGERPRINT = "a" * 64


def load_adapter():
    loader = importlib.machinery.SourceFileLoader("qwen_sglang_broker_lifecycle", str(ADAPTER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("cannot load lifecycle adapter")
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


def identity(module, pid: int = 321, start: str = "777"):
    return module.ProcessIdentity("boot-a", pid, start, 1000)


def active_row(
    module,
    generation: int,
    holder=None,
    state: str = "active",
    fingerprint: str = REGISTRY_FINGERPRINT,
):
    holder = holder or identity(module)
    return {
        "resident_id": "qwen-sglang",
        "generation": generation,
        "service_key": "sglang_qwen38",
        "service_unit": "sglang-qwen38-nvfp4.service",
        "lease_label": "sglang-qwen38",
        "lease_profile": "llm",
        "lease_mode": "exclusive",
        "holder_boot_id": holder.boot_id,
        "holder_pid": holder.pid,
        "holder_start_identity": holder.start_identity,
        "holder_uid": holder.uid,
        "compute_process_count": 1,
        "lock_device": 66306,
        "lock_inode": 4993910,
        "registry_fingerprint": fingerprint,
        "state": state,
    }


class FakeHost:
    def __init__(self, module):
        self.module = module
        self.registry_fingerprint = REGISTRY_FINGERPRINT
        self.snapshots = [module.ServiceSnapshot("active", 321, "/user.slice/qwen")]
        self.identities = {321: identity(module)}
        self.ready = True
        self.rows = []
        self.register_calls = []
        self.release_calls = []
        self.cuda = ()
        self.lock_absent = True
        self.dispatch_calls = 0
        self.fail_register_after_commit = False
        self.register_override = None
        self.identity_errors = {}
        self.adoption_error = None
        self.adoption_proofs = []
        self.registry_checks = 0
        self.registry_fail_at = None

    def service_snapshot(self):
        if len(self.snapshots) > 1:
            return self.snapshots.pop(0)
        return self.snapshots[0]

    def process_identity(self, pid):
        if pid in self.identity_errors:
            raise self.identity_errors[pid]
        value = self.identities.get(pid)
        if value is None:
            raise self.module.ProcessAbsent("process is absent")
        return value

    def health_ready(self):
        return self.ready

    def broker_residencies(self):
        return [dict(row) for row in self.rows]

    def register_residency(self, generation):
        self.register_calls.append(generation)
        holder = self.process_identity(self.service_snapshot().main_pid)
        row = active_row(self.module, generation, holder)
        if self.register_override is not None:
            row.update(self.register_override)
        self.rows = [row]
        if self.fail_register_after_commit:
            self.fail_register_after_commit = False
            raise self.module.LifecycleError("simulated lost response")
        return dict(row)

    def release_residency(self, generation):
        self.release_calls.append(generation)
        row = next(row for row in self.rows if row["resident_id"] == "qwen-sglang")
        row = dict(row)
        row["state"] = "released"
        self.rows = [row]
        return row

    def cuda_pids(self):
        return tuple(self.cuda)

    def outer_lock_absent(self, device, inode):
        return self.lock_absent

    def prove_active_residency(self, row, holder):
        self.adoption_proofs.append((dict(row), holder))
        if self.adoption_error is not None:
            raise self.adoption_error

    def assert_registry_current(self):
        self.registry_checks += 1
        if self.registry_fail_at == self.registry_checks:
            raise self.module.LifecycleError("registry changed during proof")

    def dispatch_registration(self):
        self.dispatch_calls += 1


class Clock:
    def __init__(self):
        self.value = 0.0

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.value += max(seconds, 0.01)


class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_adapter()

    def make_lifecycle(self, host=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        state_dir = Path(temporary.name) / "state"
        host = host or FakeHost(self.module)
        clock = Clock()
        store = self.module.StateStore(state_dir)
        lifecycle = self.module.Lifecycle(
            store,
            host,
            monotonic=clock.now,
            sleep=clock.sleep,
            poll_seconds=0.01,
        )
        return lifecycle, store, host

    def test_static_wiring_matches_registry_contract_and_stays_default_off(self):
        launcher = (ROOT / "scripts/run-sglang-qwen38").read_text(encoding="utf-8")
        unit = (ROOT / "sglang-qwen38-nvfp4.service").read_text(encoding="utf-8")
        lifecycle_unit = (ROOT / "qwen-sglang-broker-lifecycle.service").read_text(
            encoding="utf-8"
        )
        adapter = ADAPTER.read_text(encoding="utf-8")
        self.assertIn("--label sglang-qwen38", launcher)
        self.assertIn("--workload qwen-sglang", launcher)
        self.assertIn("--client-id sglang", launcher)
        self.assertIn("QWEN38_BROKER_RESIDENCY", launcher)
        self.assertIn("--broker-mode shadow", launcher)
        self.assertIn('Environment="QWEN38_BROKER_RESIDENCY=false"', unit)
        self.assertIn("EnvironmentFile=-%h/.config/spark-llm-stack/qwen-sglang-broker.env", unit)
        self.assertIn("Wants=qwen-sglang-broker-lifecycle.service", unit)
        self.assertIn("qwen-sglang-broker-lifecycle pre-start", unit)
        self.assertIn("qwen-sglang-broker-lifecycle hook-stop", unit)
        self.assertNotIn("WantedBy=", unit.split("[Install]", 1)[0])
        self.assertIn('Environment="QWEN38_BROKER_RESIDENCY=false"', lifecycle_unit)
        self.assertIn("After=sglang-qwen38-nvfp4.service", lifecycle_unit)
        self.assertIn("qwen-sglang-broker-lifecycle recover", lifecycle_unit)
        self.assertLess(
            unit.index("docker rm -f qwen38-sglang"),
            unit.index("qwen-sglang-broker-lifecycle hook-stop"),
        )
        self.assertIsNone(
            re.search(
                r'"--user",\s*"(?:start|stop|restart|enable|disable)"', adapter
            )
        )

    def test_first_registration_is_generation_one_and_durable(self):
        lifecycle, store, host = self.make_lifecycle()
        generation = lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(generation, 1)
        self.assertEqual(host.register_calls, [1])
        document = store.read()
        self.assertEqual(document["high_watermark"], 1)
        self.assertEqual(document["residency"]["state"], "registered")
        self.assertEqual(stat.S_IMODE(store.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(store.directory.stat().st_mode), 0o700)

    def test_retry_adopts_a_broker_commit_after_lost_response(self):
        lifecycle, store, host = self.make_lifecycle()
        host.fail_register_after_commit = True
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(store.read()["residency"]["state"], "pending")
        generation = lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(generation, 1)
        self.assertEqual(host.register_calls, [1])
        self.assertEqual(len(host.adoption_proofs), 1)
        self.assertEqual(store.read()["residency"]["state"], "registered")

    def test_retry_refuses_adoption_when_live_broker_proof_is_unavailable(self):
        lifecycle, store, host = self.make_lifecycle()
        host.fail_register_after_commit = True
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        host.adoption_error = self.module.LifecycleError("lock proof unavailable")
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(host.register_calls, [1])
        self.assertEqual(store.read()["residency"]["state"], "pending")

    def test_retry_refuses_adoption_if_registry_changes_during_live_proof(self):
        lifecycle, store, host = self.make_lifecycle()
        host.fail_register_after_commit = True
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        host.registry_fail_at = host.registry_checks + 3
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(host.register_calls, [1])
        self.assertEqual(len(host.adoption_proofs), 1)
        self.assertEqual(store.read()["residency"]["state"], "pending")

    def test_stale_registry_row_is_refreshed_with_a_new_generation(self):
        host = FakeHost(self.module)
        host.rows = [active_row(self.module, 5, fingerprint="b" * 64)]
        lifecycle, store, host = self.make_lifecycle(host)
        self.assertEqual(lifecycle.register(readiness_timeout=0.1), 6)
        self.assertEqual(host.register_calls, [6])
        self.assertEqual(host.rows[0]["registry_fingerprint"], REGISTRY_FINGERPRINT)
        self.assertEqual(store.read()["high_watermark"], 6)
        self.assertEqual(host.adoption_proofs, [])

    def test_retry_reuses_pending_generation_for_the_same_service_identity(self):
        lifecycle, store, host = self.make_lifecycle()
        original = host.register_residency

        def fail_without_commit(generation):
            host.register_calls.append(generation)
            raise self.module.LifecycleError("simulated pre-commit failure")

        host.register_residency = fail_without_commit
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        host.register_residency = original
        self.assertEqual(lifecycle.register(readiness_timeout=0.1), 1)
        self.assertEqual(host.register_calls, [1, 1])
        self.assertEqual(store.read()["high_watermark"], 1)

    def test_new_service_identity_advances_past_local_and_broker_high_watermarks(self):
        lifecycle, store, host = self.make_lifecycle()
        self.assertEqual(lifecycle.register(readiness_timeout=0.1), 1)
        newer = identity(self.module, pid=654, start="888")
        host.snapshots = [self.module.ServiceSnapshot("active", 654, "/user.slice/qwen2")]
        host.identities = {654: newer}
        host.rows = [active_row(self.module, 7, identity(self.module), state="released")]
        self.assertEqual(lifecycle.register(readiness_timeout=0.1), 8)
        self.assertEqual(host.register_calls, [1, 8])
        self.assertEqual(store.read()["high_watermark"], 8)

    def test_broker_rollback_cannot_move_generation_below_local_high_watermark(self):
        host = FakeHost(self.module)
        host.rows = [active_row(self.module, 7)]
        lifecycle, store, host = self.make_lifecycle(host)
        with store.transaction() as transaction:
            transaction.document["high_watermark"] = 10
            transaction.document["residency"] = lifecycle._state_entry(
                10, "released", identity(self.module), active_row(self.module, 10)
            )
            transaction.write()
        self.assertEqual(lifecycle.register(readiness_timeout=0.1), 11)
        self.assertEqual(host.register_calls, [11])
        self.assertEqual(store.read()["high_watermark"], 11)
        self.assertEqual(host.adoption_proofs, [])

    def test_registration_requires_active_systemd_and_http_readiness(self):
        for snapshot, ready in (
            (self.module.ServiceSnapshot("activating", 321, "/user.slice/qwen"), False),
            (self.module.ServiceSnapshot("active", 321, "/user.slice/qwen"), False),
            (self.module.ServiceSnapshot("inactive", 0, ""), True),
        ):
            with self.subTest(snapshot=snapshot, ready=ready):
                host = FakeHost(self.module)
                host.snapshots = [snapshot]
                host.ready = ready
                lifecycle, _store, host = self.make_lifecycle(host)
                with self.assertRaises(self.module.LifecycleError):
                    lifecycle.register(readiness_timeout=0.02)
                self.assertEqual(host.register_calls, [])

    def test_registration_rejects_any_broker_proof_mismatch(self):
        for override in (
            {"resident_id": "other"},
            {"generation": 99},
            {"service_unit": "wrong.service"},
            {"lease_label": "wrong"},
            {"holder_start_identity": "wrong"},
            {"registry_fingerprint": "b" * 64},
            {"state": "released"},
        ):
            with self.subTest(override=override):
                host = FakeHost(self.module)
                host.register_override = override
                lifecycle, store, _host = self.make_lifecycle(host)
                with self.assertRaises(self.module.LifecycleError):
                    lifecycle.register(readiness_timeout=0.1)
                self.assertEqual(store.read()["residency"]["state"], "pending")

    def registered_lifecycle(self):
        lifecycle, store, host = self.make_lifecycle()
        lifecycle.register(readiness_timeout=0.1)
        host.snapshots = [self.module.ServiceSnapshot("deactivating", 0, "/user.slice/qwen")]
        host.identities = {}
        host.cuda = ()
        host.lock_absent = True
        return lifecycle, store, host

    def test_release_requires_service_pid_cuda_and_outer_lock_disappearance(self):
        blockers = ("service", "pid", "cuda", "lock")
        for blocker in blockers:
            with self.subTest(blocker=blocker):
                lifecycle, _store, host = self.registered_lifecycle()
                if blocker == "service":
                    host.snapshots = [
                        self.module.ServiceSnapshot("active", 321, "/user.slice/qwen")
                    ]
                elif blocker == "pid":
                    host.identities = {321: identity(self.module)}
                elif blocker == "cuda":
                    host.cuda = (999,)
                else:
                    host.lock_absent = False
                with self.assertRaises(self.module.LifecycleError):
                    lifecycle.release(release_timeout=0.02)
                self.assertEqual(host.release_calls, [])

    def test_release_is_exact_and_idempotent_after_all_absence_proofs(self):
        lifecycle, store, host = self.registered_lifecycle()
        self.assertEqual(lifecycle.release(release_timeout=0.1), 1)
        self.assertEqual(host.release_calls, [1])
        self.assertEqual(store.read()["residency"]["state"], "released")
        self.assertEqual(lifecycle.release(release_timeout=0.1), 1)
        self.assertEqual(host.release_calls, [1])

    def test_corrupt_state_fails_closed_before_broker_mutation(self):
        lifecycle, store, host = self.make_lifecycle()
        store.directory.mkdir(parents=True, mode=0o700)
        store.path.write_text("not json", encoding="utf-8")
        store.path.chmod(0o600)
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(host.register_calls, [])

    def test_semantically_corrupt_state_fails_closed_before_broker_mutation(self):
        corruptions = (
            {
                "schema_version": True,
                "high_watermark": 0,
                "residency": None,
            },
            {
                "schema_version": 1,
                "high_watermark": True,
                "residency": None,
            },
            {
                "schema_version": 1,
                "high_watermark": 1,
                "residency": {
                    "generation": True,
                    "state": "pending",
                    "holder_boot_id": "boot-a",
                    "holder_pid": True,
                    "holder_start_identity": "777",
                    "holder_uid": False,
                    "lock_device": None,
                    "lock_inode": None,
                },
            },
            {
                "schema_version": 1,
                "high_watermark": 1,
                "residency": {
                    "generation": 1,
                    "state": "registered",
                    "holder_boot_id": "boot-a",
                    "holder_pid": 321,
                    "holder_start_identity": "777",
                    "holder_uid": 1000,
                    "lock_device": None,
                    "lock_inode": None,
                },
            },
        )
        for document in corruptions:
            with self.subTest(document=document):
                lifecycle, store, host = self.make_lifecycle()
                store.directory.mkdir(parents=True, mode=0o700)
                store.path.write_text(json.dumps(document), encoding="utf-8")
                store.path.chmod(0o600)
                with self.assertRaises(self.module.LifecycleError):
                    lifecycle.register(readiness_timeout=0.1)
                self.assertEqual(host.register_calls, [])

    def test_dangling_state_symlink_fails_closed_before_broker_mutation(self):
        lifecycle, store, host = self.make_lifecycle()
        store.directory.mkdir(parents=True, mode=0o700)
        store.path.symlink_to(store.directory / "missing-state")
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.register(readiness_timeout=0.1)
        self.assertEqual(host.register_calls, [])

    def test_pid_reuse_is_not_treated_as_the_registered_holder(self):
        lifecycle, store, host = self.registered_lifecycle()
        host.identities = {321: identity(self.module, pid=321, start="reused")}
        self.assertEqual(lifecycle.release(release_timeout=0.1), 1)
        self.assertEqual(host.release_calls, [1])
        self.assertEqual(store.read()["residency"]["state"], "released")

    def test_ambiguous_process_probe_error_blocks_release(self):
        lifecycle, store, host = self.registered_lifecycle()
        host.identity_errors[321] = self.module.LifecycleError("permission denied")
        with self.assertRaises(self.module.LifecycleError):
            lifecycle.release(release_timeout=0.1)
        self.assertEqual(host.release_calls, [])
        self.assertEqual(store.read()["residency"]["state"], "registered")

    def test_host_probe_registry_fingerprint_matches_broker_canonical_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            registry = {
                "gpu_broker": {
                    "residencies": {
                        "qwen-sglang": {
                            "service": "sglang_qwen38",
                            "unit": "sglang-qwen38-nvfp4.service",
                            "compute_process_count": 1,
                            "lease": {
                                "label": "sglang-qwen38",
                                "profile": "llm",
                                "mode": "exclusive",
                            },
                        }
                    },
                    "rollout": {"mode": "off"},
                },
                "services": {
                    "sglang_qwen38": {
                        "unit": "sglang-qwen38-nvfp4.service",
                        "manual": True,
                        "endpoint": "http://127.0.0.1:8171",
                        "health_path": "/health",
                    }
                },
                "resources": {"host_gpu_lock": "/tmp/dgx-gpu.lock"},
            }
            registry_path = Path(temporary) / "registry.json"
            registry_path.write_text(json.dumps(registry, indent=2), encoding="utf-8")
            probe = self.module.HostProbe(registry_path, Path("/nonexistent/agentos-gpu"))
            expected = hashlib.sha256(
                json.dumps(registry, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest()
            self.assertEqual(probe.registry_fingerprint, expected)
            registry["gpu_broker"]["rollout"]["mode"] = "shadow"
            registry_path.write_text(json.dumps(registry, indent=2), encoding="utf-8")
            with self.assertRaises(self.module.LifecycleError):
                probe.assert_registry_current()

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux /proc/locks contract")
    def test_host_probe_parses_exact_cross_process_flock_holder(self):
        with tempfile.NamedTemporaryFile() as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            info = os.fstat(lock_file.fileno())
            lines = Path("/proc/locks").read_text(encoding="ascii").splitlines()
            self.assertEqual(
                self.module.HostProbe._parse_lock_holder(
                    lines, device=info.st_dev, inode=info.st_ino
                ),
                os.getpid(),
            )
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lines = Path("/proc/locks").read_text(encoding="ascii").splitlines()
            self.assertIsNone(
                self.module.HostProbe._parse_lock_holder(
                    lines, device=info.st_dev, inode=info.st_ino
                )
            )

    def test_recover_registers_starting_service_or_releases_absent_service(self):
        lifecycle, _store, host = self.make_lifecycle()
        host.snapshots = [
            self.module.ServiceSnapshot("activating", 321, "/user.slice/qwen"),
            self.module.ServiceSnapshot("active", 321, "/user.slice/qwen"),
        ]
        self.assertEqual(lifecycle.recover(readiness_timeout=0.1, release_timeout=0.1), 1)
        self.assertEqual(host.register_calls, [1])

        host.snapshots = [self.module.ServiceSnapshot("inactive", 0, "")]
        host.identities = {}
        host.cuda = ()
        host.lock_absent = True
        self.assertEqual(lifecycle.recover(readiness_timeout=0.1, release_timeout=0.1), 1)
        self.assertEqual(host.release_calls, [1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
