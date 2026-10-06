import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "scripts" / "resident-queue" / "UfoQueue.Core.ps1"
ALLOWED = "@('qwen3:4b-instruct-ufo','qwen3:8b-ufo20')"


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_ps(body):
    script = "$ErrorActionPreference='Stop'\n. " + ps_quote(CORE) + "\n" + body
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
        cwd=REPO,
        text=True,
        capture_output=True,
    )


class ResidentQueueCoreTests(unittest.TestCase):
    def write_json(self, root, payload, name="task.json"):
        path = Path(root) / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def normalize(self, payload):
        with tempfile.TemporaryDirectory() as td:
            task = self.write_json(td, payload)
            p = run_ps(
                f"$p=Read-UfoQueueTaskFile -Path {ps_quote(task)}; "
                f"$n=Test-UfoQueueTaskPayload -Payload $p -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels {ALLOWED}; "
                "$n | ConvertTo-Json -Compress"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            return json.loads(p.stdout.strip().splitlines()[-1])

    def assert_rejected(self, payload):
        with tempfile.TemporaryDirectory() as td:
            task = self.write_json(td, payload)
            p = run_ps(
                f"$p=Read-UfoQueueTaskFile -Path {ps_quote(task)}; "
                f"Test-UfoQueueTaskPayload -Payload $p -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels {ALLOWED} | Out-Null"
            )
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_valid_payload_applies_defaults(self):
        payload = {"schema_version": 1, "id": "20261006-001", "request": "Type exact text."}
        got = self.normalize(payload)
        self.assertEqual(got, {
            "schema_version": 1,
            "id": "20261006-001",
            "request": "Type exact text.",
            "model": "qwen3:4b-instruct-ufo",
            "timeout_seconds": 600,
        })

    def test_malformed_json_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            task = Path(td) / "task.json"
            task.write_text('{"schema_version":1,', encoding="utf-8")
            p = run_ps(f"Read-UfoQueueTaskFile -Path {ps_quote(task)} | Out-Null")
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_schema_rejections(self):
        base = {"schema_version": 1, "id": "ok-1", "request": "hello"}
        cases = [
            {**base, "schema_version": 2},
            {**base, "schema_version": "1"},
            {**base, "request": ""},
            {**base, "request": "x" * 12001},
            {**base, "id": "../bad"},
            {**base, "id": "x" * 81},
            {**base, "model": "not-approved"},
            {**base, "timeout_seconds": 29},
            {**base, "timeout_seconds": 1801},
            {**base, "timeout_seconds": 30.5},
            {**base, "timeout_seconds": "30"},
        ]
        for payload in cases:
            with self.subTest(payload={k: ("<long>" if k == "request" and len(str(v)) > 100 else v) for k, v in payload.items()}):
                self.assert_rejected(payload)

    def test_payload_cannot_override_runtime_paths(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "queue"
            payload = {
                "schema_version": 1,
                "id": "safe.task_1",
                "request": "hello",
                "runner_path": "C:\\evil.ps1",
                "working_directory": "C:\\",
                "command": "calc.exe",
                "arguments": "-bad",
                "environment": {"X": "Y"},
            }
            task = self.write_json(td, payload)
            p = run_ps(
                f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null; "
                f"$p=Read-UfoQueueTaskFile -Path {ps_quote(task)}; "
                f"$n=Test-UfoQueueTaskPayload -Payload $p -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels {ALLOWED}; "
                f"$paths=Get-UfoQueueTaskPaths -QueueRoot {ps_quote(root)} -TaskId $n.id; "
                "[pscustomobject]@{normalized=$n;paths=$paths} | ConvertTo-Json -Depth 5 -Compress"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            got = json.loads(p.stdout.strip().splitlines()[-1])
            self.assertEqual(set(got["normalized"]), {"schema_version", "id", "request", "model", "timeout_seconds"})
            root_abs = str(root.resolve()).lower()
            for key, value in got["paths"].items():
                if isinstance(value, str):
                    self.assertTrue(value.lower().startswith(root_abs), (key, value, root_abs))

    def test_duplicate_id_is_detected_by_payload_not_filename(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "queue"
            p = run_ps(f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null")
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            fixture_dir = root / "done" / "totally-different-directory-name"
            fixture_dir.mkdir(parents=True)
            self.write_json(fixture_dir, {"schema_version": 1, "id": "duplicate-42", "request": "old"})
            p = run_ps(
                f"$v=Test-UfoQueueDuplicateId -QueueRoot {ps_quote(root)} -TaskId 'duplicate-42'; "
                "$v | ConvertTo-Json -Compress"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual(p.stdout.strip().splitlines()[-1].lower(), "true")


if __name__ == "__main__":
    unittest.main()
