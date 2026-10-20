#!/usr/bin/env python3
"""Launcher safety checks; these tests do not establish any native UI behavior."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
import textwrap
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("native_run", Path(__file__).with_name("run.py"))
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class SafetyTests(unittest.TestCase):
    def test_wrong_host_refuses_before_artifact_access_or_launch(self):
        with patch.object(launcher.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(ValueError, "requires Linux"):
                launcher.preflight("wayland")

    def test_image_machine_and_format_must_match(self):
        elf = bytearray(128)
        elf[:6] = b"\x7fELF\x02\x01"
        elf[18:20] = b"\x3e\x00"
        pe = bytearray(128)
        pe[:2] = b"MZ"
        struct.pack_into("<I", pe, 60, 80)
        pe[80:86] = b"PE\x00\x00\x64\x86"
        self.assertTrue(launcher.machine_x64(elf))
        self.assertTrue(launcher.machine_x64(pe))
        elf[18:20] = b"\xb7\x00"  # ARM64 must not pass an x64 gate.
        pe[84:86] = b"\x4c\x01"  # x86 must not pass either.
        self.assertFalse(launcher.machine_x64(elf))
        self.assertFalse(launcher.machine_x64(pe))
        self.assertFalse(launcher.machine_x64(b"not an executable"))
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "dbeer-gpui.exe"
            image.write_bytes(elf)
            with self.assertRaises(ValueError):
                launcher.artifact(image, "windows")

    def test_child_isolation_preserves_home_and_desktop_bus(self):
        original = {"HOME": "/owned-user", "DBUS_SESSION_BUS_ADDRESS": "synthetic-bus",
                    "DBEER_GPUI_HELPER_PATH": "/wrong-helper", "DBEER_TEST_PASSWORD": "must-not-inherit"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with patch.dict(os.environ, original, clear=True):
                env = launcher.child_environment(root, Path("/exact/helper"), "wayland")
            self.assertEqual(env["HOME"], "/owned-user")
            self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "synthetic-bus")
            self.assertEqual(env["DBEER_GPUI_HELPER_PATH"], "/exact/helper")
            self.assertNotIn("DBEER_TEST_PASSWORD", env)
            for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR"):
                self.assertTrue(Path(env[name]).is_relative_to(root))
            self.assertEqual(original["HOME"], "/owned-user")

    @unittest.skipIf(os.name == "nt", "POSIX mechanics check; target-native path remains unrun")
    def test_timeout_only_terminates_owned_child_and_preserves_fixtures(self):
        self.exercise_child("timeout")

    @unittest.skipIf(os.name == "nt", "POSIX mechanics check; target-native path remains unrun")
    def test_identity_mismatch_refuses_and_only_cleans_up_child(self):
        self.exercise_child("mismatch")

    def exercise_child(self, condition):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            executable = root / "dbeer-gpui"
            executable.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(300)\n")
            executable.chmod(0o700)
            sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
            args = SimpleNamespace(desktop="wayland", command="operator", executable=executable,
                                   helper=root / "dbeer-core", timeout=0.15)
            try:
                with patch.object(launcher, "OUTPUT", root / "runs"), \
                     patch.object(launcher, "preflight", return_value={"scope": "test-double"}), \
                     patch.object(launcher, "artifact", side_effect=lambda path, *a, **kw: executable), \
                     patch.object(launcher, "process_image", return_value=Path(sys.executable) if condition == "mismatch" else executable), \
                     patch.object(launcher, "credential_command", return_value={"outcome": "completed", "result": {"cleanup_verified": True}}), \
                     redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(launcher.run(args), 1)
                summary_path = next((root / "runs").glob("*/summary.json"))
                summary = json.loads(summary_path.read_text())
                self.assertTrue(summary["completed"])
                self.assertEqual(summary["cleanup"], "terminated-owned-child")
                self.assertEqual(summary["outcome"], "timeout" if condition == "timeout" else "refused")
                self.assertEqual(set(summary["gates"].values()), {"not-run"})
                self.assertEqual(summary["native_acceptance"], "not-run")
                self.assertIsNone(sentinel.poll(), "Unrelated process must remain running")
                self.assertTrue((summary_path.parent / "fixtures/grid.json").is_file())
            finally:
                sentinel.terminate()
                sentinel.wait(timeout=5)

    def test_cleanup_failure_still_writes_summary(self):
        for failure in ("second-timeout", "terminate-error"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                image = root / "dbeer-gpui"
                image.write_bytes(b"synthetic-image")
                process = Mock(pid=123456)
                process.poll.return_value = None
                process.wait.side_effect = subprocess.TimeoutExpired("owned-test-child", 0.1)
                if failure == "terminate-error":
                    process.terminate.side_effect = OSError("synthetic cleanup error")
                args = SimpleNamespace(desktop="wayland", command="operator", executable=image,
                                       helper=image, timeout=0.1)
                with patch.object(launcher, "OUTPUT", root / "runs"), \
                     patch.object(launcher, "preflight", return_value={"scope": "test-double"}), \
                     patch.object(launcher, "artifact", return_value=image), \
                     patch.object(launcher, "process_image", return_value=image), \
                     patch.object(launcher.subprocess, "Popen", return_value=process), \
                     patch.object(launcher, "source_identity", return_value={"scope": "test-double"}), \
                     patch.object(launcher, "credential_command", return_value={"outcome": "completed", "result": {"cleanup_verified": True}}), \
                     redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(launcher.run(args), 1)
                summary = json.loads(next((root / "runs").glob("*/summary.json")).read_text())
                self.assertTrue(summary["completed"])
                self.assertEqual(summary["outcome"], "cleanup-failed")
                self.assertEqual(summary["cleanup"], "failed-owned-child-may-still-be-running")
                self.assertEqual(set(summary["gates"].values()), {"not-run"})
                process.terminate.assert_called_once()
                self.assertEqual(process.kill.call_count, 1 if failure == "second-timeout" else 0)

    @unittest.skipIf(os.name == "nt", "Unix ownership mechanics; Windows ACL path requires native desktop")
    def test_private_request_rejects_public_modes_and_fifo(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "fixtures").mkdir(mode=0o700)
            with patch.object(launcher, "OUTPUT", root):
                request = launcher.make_request(root)
                self.assertTrue(launcher.validated_request(request))
                root.chmod(0o777)
                with self.assertRaises(ValueError): launcher.validated_request(request)
                root.chmod(0o700)
                request.chmod(0o666)
                with self.assertRaises(ValueError): launcher.validated_request(request)
                request.unlink()
                os.mkfifo(request, 0o600)
                with self.assertRaises(ValueError): launcher.validated_request(request)

    def test_event_reports_reject_non_json_wrong_pid_and_values(self):
        for event in (b"not-json\n", b'{"kind":"clipboard","pid":8,"facts":{"outcome":"not-run-no-readable-original"}}\n',
                      b'{"kind":"clipboard","pid":7,"facts":{"sql":"must-not-be-ingested"}}\n'):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                launcher.write_json(root / "probe-ui.json", {"version": 1, "pid": 7, "completed": True,
                    "event_count": 1, "grid_rows": 1000, "native_acceptance": "not-run"})
                path = root / "probe-events.jsonl"
                descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(descriptor, "wb") as stream: stream.write(event)
                with self.assertRaises(ValueError): launcher.collect_ui(root, 7)

    @unittest.skipIf(os.name == "nt", "POSIX fake worker; native adapter remains unrun")
    def test_worker_identity_precedes_atomic_permission_and_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "fixtures").mkdir(mode=0o700)
            image = root / "dbeer-gpui"
            image.write_text("#!" + sys.executable + "\n" + textwrap.dedent("""\
                import json, os, pathlib, sys, time
                request = json.loads(pathlib.Path(sys.argv[2]).read_text())
                root = pathlib.Path(request['root'])
                go = root / ('credential-go-' + str(os.getpid()))
                while not go.exists(): time.sleep(0.001)
                assert go.read_text() == request['token']
                (root / 'mutation-after-identity').touch()
                result = {key: False for key in ('completed','created','read_back','replaced','cleanup_attempted','cleanup_verified','collision','failed')}
                result.update(completed=True, created=True, read_back=True, replaced=True, cleanup_attempted=True, cleanup_verified=True)
                name = 'credential-probe.json'
                fd = os.open(root / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as stream:
                    json.dump(dict(version=1,pid=os.getpid(),native_acceptance='not-run',result=result),stream)
                """))
            image.chmod(0o700)
            def identity(process):
                self.assertFalse((root / "mutation-after-identity").exists())
                self.assertFalse((root / ("credential-go-" + str(process.pid))).exists())
                return image
            with patch.object(launcher, "OUTPUT", root), patch.object(launcher, "process_image", side_effect=identity):
                request = launcher.make_request(root)
                launcher.make_context(request, image, "wayland")
                result = launcher.credential_command(image, request, dict(os.environ), timeout=2)
            self.assertEqual(result["outcome"], "completed")
            self.assertTrue(result["pid_image_verified"])
            self.assertTrue((root / "mutation-after-identity").exists())

    def test_deleted_request_cleanup_refuses_without_losing_run_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            image = root / "dbeer-gpui"
            image.write_bytes(b"synthetic-image")
            process = Mock(pid=123456)
            process.poll.return_value = None
            process.wait.side_effect = [subprocess.TimeoutExpired("test-child", 0.1), 0]
            original_command = launcher.credential_command
            def command(executable, request, env, cleanup=False):
                if not cleanup:
                    launcher.write_json(request.parent / "credential-owned.json", {"synthetic-test": True})
                    request.unlink()
                    return {"outcome": "completed", "result": {"cleanup_verified": True}}
                return original_command(executable, request, env, cleanup=True)
            args = SimpleNamespace(desktop="wayland", command="operator", executable=image, helper=image, timeout=0.1)
            with patch.object(launcher, "OUTPUT", root / "runs"), \
                 patch.object(launcher, "preflight", return_value={"scope": "test-double"}), \
                 patch.object(launcher, "source_identity", return_value={"scope": "test-double"}), \
                 patch.object(launcher, "artifact", return_value=image), \
                 patch.object(launcher, "credential_command", side_effect=command), \
                 patch.object(launcher, "process_image", return_value=image), \
                 patch.object(launcher.subprocess, "Popen", return_value=process), \
                 redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(launcher.run(args), 1)
            summary = json.loads(next((root / "runs").glob("*/summary.json")).read_text())
            self.assertTrue(summary["completed"])
            self.assertTrue(summary["credential_recovery_required"])
            self.assertEqual(summary["credential_cleanup"]["outcome"], "refused-or-invalid-report")

    def test_unconfirmed_worker_blocks_additional_mutators(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            image = root / "dbeer-gpui"
            image.write_bytes(b"synthetic-image")
            args = SimpleNamespace(desktop="wayland", command="operator", executable=image, helper=image, timeout=10)
            with patch.object(launcher, "OUTPUT", root / "runs"), \
                 patch.object(launcher, "preflight", return_value={"scope": "test-double"}), \
                 patch.object(launcher, "source_identity", return_value={"scope": "test-double"}), \
                 patch.object(launcher, "artifact", return_value=image), \
                 patch.object(launcher, "credential_command", return_value={"outcome": "cleanup-failed", "process_cleanup": "failed-owned-child-may-still-be-running", "pid": 77}) as command, \
                 patch.object(launcher.subprocess, "Popen") as start, \
                 redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(launcher.run(args), 1)
            self.assertEqual(command.call_count, 1)
            start.assert_not_called()
            summary = json.loads(next((root / "runs").glob("*/summary.json")).read_text())
            self.assertEqual(summary["credential_cleanup"]["outcome"], "blocked-prior-worker-may-be-running")
            self.assertTrue(summary["credential_recovery_required"])

    def test_recovery_preserves_collisions_without_native_ownership_grant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "fixtures").mkdir(mode=0o700)
            image = root / "dbeer-gpui"
            image.write_bytes(b"synthetic-image")
            with patch.object(launcher, "OUTPUT", root):
                request = launcher.make_request(root)
                launcher.make_context(request, image, "wayland")
                # A collision report grants no right to delete, even under a reserved ID.
                launcher.write_json(root / "summary.json", {"credential_probe": {"result": {"collision": True}}})
                args = SimpleNamespace(desktop="wayland", executable=image, request=request)
                with patch.object(launcher, "preflight"), patch.object(launcher, "artifact", return_value=image), \
                     patch.object(launcher, "credential_command") as mutate:
                    with redirect_stdout(io.StringIO()): self.assertEqual(launcher.recover(args), 0)
                mutate.assert_not_called()
                report = json.loads(next(root.glob("recovery-*.json")).read_text())
                self.assertEqual(report["credential_cleanup"]["outcome"], "not-needed-no-ownership-grant")

    def test_recovery_after_hard_failure_requires_grant_and_prior_worker_absence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "fixtures").mkdir(mode=0o700)
            image = root / "dbeer-gpui"
            image.write_bytes(b"synthetic-image")
            with patch.object(launcher, "OUTPUT", root):
                request = launcher.make_request(root)
                context = launcher.make_context(request, image, "wayland")
                identity = {**context, "pid": 77, "mode": "probe", "pid_image_verified": True, "started_utc": launcher.now()}
                launcher.write_json(root / "credential-worker-77.json", identity)
                request_data = launcher.validated_request(request)
                launcher.write_json(root / "credential-owned.json", {"version": 1, "token": request_data["token"], "account": request_data["account"], "pid": 77})
                args = SimpleNamespace(desktop="wayland", executable=image, request=request)
                self.assertFalse((root / "summary.json").exists(), "Model a harness killed before terminal summary")
                with patch.object(launcher, "preflight"), patch.object(launcher, "artifact", return_value=image), \
                     patch.object(launcher, "pid_running", return_value=True), \
                     patch.object(launcher, "credential_command") as mutate:
                    with self.assertRaises(ValueError): launcher.recover(args)
                mutate.assert_not_called()
                # A hard kill can also leave a legacy/truncated terminal record.
                terminal = root / "credential-worker-77-finished.json"
                terminal.write_text('{"completed":')
                terminal.chmod(0o600)
                with patch.object(launcher, "preflight"), patch.object(launcher, "artifact", return_value=image), \
                     patch.object(launcher, "pid_running", return_value=False), \
                     patch.object(launcher, "credential_command", return_value={"outcome": "completed", "result": {"cleanup_verified": True}}) as mutate, \
                     redirect_stdout(io.StringIO()):
                    self.assertEqual(launcher.recover(args), 0)
                mutate.assert_called_once()
                self.assertTrue(next(root.glob("recovery-*.json")).is_file())

    def test_deeply_nested_evidence_is_fixed_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "nested.json"
            path.write_text("[" * 1500 + "]" * 1500)
            path.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "Malformed probe evidence"):
                launcher.strict_json(path)

    def test_evidence_depth_has_exact_array_object_and_mixed_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "bounded.json"
            for kind in ("array", "object", "mixed"):
                for depth in (launcher.EVIDENCE_MAX_DEPTH, launcher.EVIDENCE_MAX_DEPTH + 1):
                    value = 0
                    for index in range(depth):
                        value = {"v": value} if kind == "object" or (kind == "mixed" and index % 2) else [value]
                    path.write_text(json.dumps(value))
                    path.chmod(0o600)
                    with self.subTest(kind=kind, depth=depth):
                        if depth > launcher.EVIDENCE_MAX_DEPTH:
                            with self.assertRaises(ValueError) as refused:
                                launcher.strict_json(path)
                            self.assertEqual(str(refused.exception), "Malformed probe evidence")
                        else:
                            self.assertEqual(launcher.strict_json(path), value)

    def test_quoted_brackets_and_escaped_quotes_do_not_count_as_evidence_depth(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "quoted.json"
            value = {"text": '[{\\\"' * 200}
            for encoding in ("utf-8", "utf-16", "utf-32"):
                path.write_bytes(json.dumps(value).encode(encoding))
                path.chmod(0o600)
                with self.subTest(encoding=encoding):
                    self.assertEqual(launcher.strict_json(path, limit=16384), value)

    def test_cleanup_exit_override_preserves_success_refusal_cancellation_and_pending_error(self):
        for outcome in (None, ValueError("fixed refusal"), KeyboardInterrupt(), RuntimeError("pending error")):
            for cleanup_failed in (False, True):
                with self.subTest(outcome=type(outcome).__name__, cleanup_failed=cleanup_failed), \
                     tempfile.TemporaryDirectory() as directory:
                    root = Path(directory).resolve()
                    image = root / "dbeer-gpui"
                    image.write_bytes(b"synthetic-image")
                    args = SimpleNamespace(desktop="x11", command="preflight", executable=image, helper=image)
                    with patch.object(launcher, "OUTPUT", root / "runs"), \
                         patch.object(launcher, "preflight", side_effect=outcome, return_value={"scope": "test-double"}), \
                         patch.object(launcher, "artifact", return_value=image), \
                         patch.object(launcher, "source_identity", return_value={"scope": "test-double"}), \
                         patch.object(launcher, "stop_owned_child", side_effect=OSError("cleanup failed") if cleanup_failed else None,
                                      return_value="already-exited"), \
                         redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                        if isinstance(outcome, RuntimeError) and not cleanup_failed:
                            with self.assertRaises(RuntimeError):
                                launcher.run(args)
                        else:
                            expected = 1 if cleanup_failed or isinstance(outcome, ValueError) else 130 if isinstance(outcome, KeyboardInterrupt) else 0
                            self.assertEqual(launcher.run(args), expected)
                    summary = json.loads(next((root / "runs").glob("*/summary.json")).read_text())
                    self.assertTrue(summary["completed"])
                    self.assertEqual(summary["cleanup"], "failed-owned-child-may-still-be-running" if cleanup_failed else "already-exited")

    def test_cancellation_preserves_completed_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            args = SimpleNamespace(desktop="x11", command="operator", executable=Path("/unused"),
                                   helper=Path("/unused-helper"), timeout=10)
            with patch.object(launcher, "OUTPUT", root / "runs"), \
                 patch.object(launcher, "preflight", side_effect=KeyboardInterrupt), \
                 redirect_stdout(io.StringIO()):
                self.assertEqual(launcher.run(args), 130)
            summary = json.loads(next((root / "runs").glob("*/summary.json")).read_text())
            self.assertEqual(summary["outcome"], "cancelled")
            self.assertTrue(summary["completed"])
            self.assertEqual(summary["cleanup"], "already-exited")


if __name__ == "__main__":
    unittest.main(verbosity=2)
