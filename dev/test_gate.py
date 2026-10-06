#!/usr/bin/env python3
"""Regression controls for native warnings, result integrity and consumer selection."""

from pathlib import Path
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import check_downstream

from check_native import command
from check_results import load, tests
from consumer_dependencies import prepare, retain
from isolated_process import run


class GateTests(unittest.TestCase):
    def test_nonempty_success_and_refused_test_summaries(self):
        self.assertEqual(tests("\x1b[32m.\n211 passed, no failures\x1b[39m\n"), 211)
        for text in [
            "",
            "No tests found!",
            "0 passed, no failures",
            "211 passed, 1 failures",
            "211 passed, 0 failures, 1 skipped",
            "211 passed, no failures\n211 passed, no failures",
        ]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                tests(text)

    def test_native_warning_rejection_and_positive_control(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-native-control-"
        ) as directory:
            root = Path(directory)
            (root / "src").mkdir()
            output = root / "output"
            output.mkdir()
            source = root / "src/control.erl"
            source.write_text(
                "-module(control).\n-export([value/0]).\nvalue() -> ok.\n"
            )
            accepted = subprocess.run(
                command(root, output), capture_output=True, text=True, check=False
            )
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            self.assertTrue((output / "control.beam").exists())
            (output / "control.beam").unlink()
            source.write_text(
                "-module(control).\n-export([value/0]).\nvalue() -> Unused = 1, ok.\n"
            )
            rejected = subprocess.run(
                command(root, output), capture_output=True, text=True, check=False
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(
                "variable 'Unused' is unused", rejected.stdout + rejected.stderr
            )
            self.assertFalse((output / "control.beam").exists())

    def test_missing_native_sources_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                command(Path(directory), Path(directory))

    def test_load_results_reject_empty_duplicate_invalid_connection_and_bytes(self):
        rows = [
            {
                "scenario": protocol,
                "requests": count,
                "connections": 1 if protocol.startswith("h2") else 4,
            }
            for protocol in ["h1-concurrent", "h2-concurrent"]
            for count in [1, 10, 100, 1000]
        ]
        rows += [
            {"scenario": "large-stream", "requests": 1, "bytes": 33554432},
            {"scenario": "large-slow-reader", "requests": 1, "bytes": 33554432},
            {
                "scenario": "h2-slow-stream-plus-batch",
                "requests": 1000,
                "connections": 1,
            },
        ]
        serialize = lambda values: "\n".join(json.dumps(row) for row in values)
        load(serialize(rows))
        broken = [
            [],
            rows[:-1],
            [rows[0]] * 11,
            [
                {**row, "connections": 2} if row["scenario"] == "h2-concurrent" else row
                for row in rows
            ],
            [
                {**row, "bytes": 1} if row["scenario"].startswith("large") else row
                for row in rows
            ],
        ]
        for values in broken:
            with self.subTest(values=values), self.assertRaises(ValueError):
                load(serialize(values))
        with self.assertRaises(ValueError):
            load("not JSON")

    def test_shell_gate_stops_on_failure_and_retains_its_diagnostic(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-driver-control-"
        ) as directory:
            root = Path(directory)
            (root / "dev").mkdir()
            shutil.copyfile(Path(__file__).with_name("gate"), root / "dev/gate")
            binary = root / "bin"
            binary.mkdir()
            for name, body in [
                ("erl", "print('OTP control')"),
                (
                    "gleam",
                    "import sys\nprint('controlled build diagnostic')\nraise SystemExit(7 if sys.argv[1] == 'build' else 0)",
                ),
            ]:
                executable = binary / name
                executable.write_text(f"#!{sys.executable}\n{body}\n")
                executable.chmod(0o755)
            result = subprocess.run(
                [shutil.which("sh"), "dev/gate", "fast"],
                cwd=root,
                env={
                    **os.environ,
                    "HTTP_GUN_ISOLATED_GATE": "1",
                    "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
            logs = root / "build/evidence/logs"
            self.assertIn(
                "controlled build diagnostic", (logs / "build.log").read_text()
            )
            self.assertFalse((logs / "package-tests.log").exists())

    def test_isolated_timeout_stops_descendants_and_preserves_exit_codes(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-timeout-control-"
        ) as directory:
            root = Path(directory)
            for code in [0, 7]:
                self.assertEqual(
                    run(
                        [sys.executable, "-c", f"raise SystemExit({code})"],
                        cwd=root,
                        env=dict(os.environ),
                        timeout=5,
                    ),
                    code,
                )
            pid_file = root / "child.pid"
            child = (
                "import os, signal, time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                "time.sleep(60)"
            )
            parent = (
                "import subprocess, time; "
                f"subprocess.Popen([{sys.executable!r}, '-c', {child!r}]); "
                "time.sleep(60)"
            )
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    run(
                        [sys.executable, "-c", parent],
                        cwd=root,
                        env=dict(os.environ),
                        timeout=2,
                        grace=0.2,
                    )
                self.assertTrue(
                    pid_file.exists(), "Descendant must start before timeout"
                )
                pid = int(pid_file.read_text())
                state = subprocess.run(
                    ["ps", "-p", str(pid), "-o", "stat="],
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.strip()
                self.assertTrue(
                    not state or state.startswith("Z"),
                    f"Descendant {pid} is still running: {state}",
                )
            finally:
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_new_run_cannot_export_an_old_nghttpd_receipt_on_failure(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-evidence-control-"
        ) as directory:
            root = Path(directory)
            (root / "dev").mkdir()
            shutil.copyfile(Path(__file__).with_name("gate"), root / "dev/gate")
            old = root / "build/evidence/nghttpd/receipt.json"
            old.parent.mkdir(parents=True)
            old.write_text('{"result": "old success"}')
            binary = root / "bin"
            binary.mkdir()
            nix = binary / "nix"
            nix.write_text(
                f"#!{sys.executable}\nprint('controlled tooling failure')\nraise SystemExit(9)\n"
            )
            nix.chmod(0o755)
            result = subprocess.run(
                [shutil.which("sh"), "dev/gate", "full"],
                cwd=root,
                env={
                    **os.environ,
                    "HTTP_GUN_ISOLATED_GATE": "0",
                    "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
            self.assertFalse(old.exists())
            self.assertIn(
                "controlled tooling failure",
                (root / "build/evidence/logs/tooling.log").read_text(),
            )

    def test_matrix_retains_each_current_run_after_gate_evidence_cleanup(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-matrix-control-"
        ) as directory:
            root = Path(directory)
            (root / "dev").mkdir()
            shutil.copyfile(Path(__file__).with_name("matrix"), root / "dev/matrix")
            binary = root / "bin"
            binary.mkdir()
            nix = binary / "nix"
            nix.write_text(
                f"#!{sys.executable}\n"
                + """import os, shutil, sys
from pathlib import Path
runtime = sys.argv[2].rsplit('#', 1)[1]
evidence = Path('build/evidence')
if evidence.exists():
    shutil.rmtree(evidence)
evidence.mkdir(parents=True)
for name in ['load.jsonl', 'recording.jsonl', 'batch.jsonl', 'summary.json']:
    (evidence / name).write_text(runtime)
for name in ['manifests', 'nghttpd', 'logs']:
    (evidence / name).mkdir()
    (evidence / name / 'receipt').write_text(runtime)
print('current gate ' + runtime)
raise SystemExit(7 if runtime == os.environ.get('MATRIX_FAIL_RUNTIME') else 0)
"""
            )
            nix.chmod(0o755)
            for failed, expected in [
                ("", ["default", "otp28", "otp27"]),
                ("otp28", ["default", "otp28"]),
            ]:
                result = subprocess.run(
                    [shutil.which("sh"), "dev/matrix"],
                    cwd=root,
                    env={
                        **os.environ,
                        "MATRIX_FAIL_RUNTIME": failed,
                        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                    },
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode, 7 if failed else 0, result.stdout + result.stderr
                )
                evidence = root / "build/evidence/matrix"
                self.assertEqual(
                    sorted(path.name for path in evidence.iterdir()), sorted(expected)
                )
                for runtime in expected:
                    self.assertEqual(
                        (evidence / runtime / "nghttpd/receipt").read_text(), runtime
                    )
                    self.assertIn(
                        "current gate " + runtime,
                        (evidence / runtime / "gate.log").read_text(),
                    )

    def test_downstream_provenance_never_reads_credential_names(self):
        with tempfile.TemporaryDirectory(prefix="http-gun-input-control-") as directory:
            root = Path(directory)
            excluded = [
                ".env",
                ".env.local",
                "nested/.ENV.prod",
                ".aws/credentials",
                ".ssh/id_ed25519",
                "credentials.json",
                "secrets.toml",
            ]
            allowed = ["src/main.gleam", ".envrc", "test/fixtures/loopback-test.key"]
            for relative in excluded + allowed:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("control fixture")
            read = []
            original = Path.read_bytes

            def guarded(path):
                relative = str(path.relative_to(root))
                self.assertNotIn(relative, excluded, "Credential path was opened")
                read.append(relative)
                return original(path)

            def git(_root, *args):
                if args[0] == "ls-files":
                    return "\0".join(excluded + allowed).encode()
                return b"control-revision" if args[0] == "rev-parse" else b""

            with (
                mock.patch.object(check_downstream, "git", git),
                mock.patch.object(Path, "read_bytes", guarded),
            ):
                receipt = check_downstream.inputs(root)
            self.assertEqual(sorted(read), sorted(allowed))
            self.assertEqual(sorted(receipt["files"]), sorted(allowed))

    def test_downstream_runner_retains_new_selected_output(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-downstream-output-"
        ) as directory:
            root = Path(directory)
            downstream = root / "llm_wire"
            (downstream / "dev").mkdir(parents=True)
            old = downstream / "docs/evidence/http-gun/local-http.json"
            old.parent.mkdir(parents=True)
            old.write_text('{"old": true}')
            script = downstream / "dev/local-http.py"
            script.write_text("""import json, os
from pathlib import Path
output = Path(os.environ['LLM_WIRE_HTTP_OUTPUT'])
output.mkdir(parents=True, exist_ok=False)
(output / 'local-http.json').write_text(json.dumps({'current': True}))
""")
            output = root / "output"
            output.mkdir()
            receipt = {"commands": []}
            check_downstream.local_http(downstream, output, receipt)
            self.assertEqual(
                json.loads((output / "local-http/local-http.json").read_text()),
                {"current": True},
            )
            self.assertEqual(json.loads(old.read_text()), {"old": True})
            self.assertEqual(receipt["commands"][0]["exit"], 0)
            script.write_text("print('no current receipt')\n")
            refused = root / "missing-output"
            refused.mkdir()
            with self.assertRaises(ValueError):
                check_downstream.local_http(downstream, refused, {"commands": []})

    def test_consumer_selection_rejects_stale_native_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "consumer"
            consumer.mkdir()
            selected = """packages = [
{name = "gun", version = "2.6.1"},
{name = "cowlib", version = "2.20.1"},
{name = "gleam_stdlib", version = "1.0.5"}]
"""
            (root / "manifest.toml").write_text(selected)
            (consumer / "gleam.toml").write_text('name = "consumer"\n[dependencies]\n')
            prepare(consumer, root)
            import tomllib

            constraints = tomllib.loads((consumer / "gleam.toml").read_text())[
                "dependencies"
            ]
            self.assertEqual(constraints["gun"], "== 2.6.1")
            self.assertEqual(constraints["cowlib"], "== 2.20.1")
            (consumer / "manifest.toml").write_text(selected.replace("2.6.1", "2.6.0"))
            with self.assertRaises(ValueError):
                retain(consumer, root, "control")
            (consumer / "manifest.toml").write_text(selected)
            retain(consumer, root, "control")
            self.assertTrue((root / "build/evidence/manifests/control.toml").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
