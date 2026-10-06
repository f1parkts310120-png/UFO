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
        cwd=REPO, text=True, capture_output=True,
    )


class ResidentQueueTransitionTests(unittest.TestCase):
    def test_claim_moves_inbox_to_single_running_workspace(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "queue"
            inbox = root / "inbox"
            inbox.mkdir(parents=True)
            original = {"schema_version": 1, "id": "claim-1", "request": "exact request", "extra": "preserve"}
            incoming = inbox / "random-filename.json"
            incoming.write_text(json.dumps(original), encoding="utf-8")
            p = run_ps(
                f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null; "
                f"$raw=Read-UfoQueueTaskFile -Path {ps_quote(incoming)}; "
                f"$task=Test-UfoQueueTaskPayload -Payload $raw -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels {ALLOWED}; "
                f"$claimed=Claim-UfoQueueTask -InboxPath {ps_quote(incoming)} -QueueRoot {ps_quote(root)} -Task $task; "
                "$claimed | ConvertTo-Json -Depth 5 -Compress"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertFalse(incoming.exists())
            task_json = root / "running" / "claim-1" / "task.json"
            self.assertTrue(task_json.exists())
            self.assertEqual(json.loads(task_json.read_text(encoding="utf-8-sig")), original)
            copies = list(root.glob("*/claim-1/task.json"))
            self.assertEqual(copies, [task_json])

    def test_complete_moves_workspace_and_preserves_artifacts(self):
        for status in ("done", "failed"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as td:
                root = Path(td) / "queue"
                running = root / "running" / f"terminal-{status}"
                running.mkdir(parents=True)
                artifacts = {
                    "task.json": '{"schema_version":1,"id":"x","request":"r"}',
                    "request.txt": "request",
                    "runner-result.json": '{"exit_code":0}',
                    "queue-result.json": json.dumps({"id": "x", "status": status}),
                    "worker.log": "log",
                }
                for name, content in artifacts.items():
                    (running / name).write_text(content, encoding="utf-8")
                p = run_ps(
                    f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null; "
                    f"$dest=Complete-UfoQueueTask -TaskDirectory {ps_quote(running)} -QueueRoot {ps_quote(root)} -Status '{status}'; "
                    "$dest | ConvertTo-Json -Compress"
                )
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                dest = root / status / running.name
                self.assertTrue(dest.is_dir())
                self.assertFalse(running.exists())
                self.assertEqual(set(artifacts), {x.name for x in dest.iterdir()})

    def test_write_result_replaces_atomically_and_leaves_no_temp(self):
        with tempfile.TemporaryDirectory() as td:
            task_dir = Path(td) / "task"
            task_dir.mkdir()
            p = run_ps(
                f"$r=@{{id='atomic-1';status='done';exit_code=0}}; "
                f"Write-UfoQueueResult -TaskDirectory {ps_quote(task_dir)} -Result $r"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            got = json.loads((task_dir / "queue-result.json").read_text(encoding="utf-8-sig"))
            self.assertEqual(got["status"], "done")
            self.assertEqual(list(task_dir.glob("*.tmp*")), [])

    def _recover_case(self, proof, expected_state, expected_error=None):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "queue"
            task_dir = root / "running" / "recover-1"
            task_dir.mkdir(parents=True)
            (task_dir / "task.json").write_text(json.dumps({"schema_version": 1, "id": "recover-1", "request": "do not replay"}), encoding="utf-8")
            if proof == "malformed":
                (task_dir / "queue-result.json").write_text("{bad", encoding="utf-8")
            elif proof is not None:
                (task_dir / "queue-result.json").write_text(json.dumps(proof), encoding="utf-8")
            p = run_ps(
                f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null; "
                f"$events=@(Recover-UfoQueueRunningTasks -QueueRoot {ps_quote(root)}); "
                "$events | ConvertTo-Json -Depth 5 -Compress"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            dest = root / expected_state / "recover-1"
            self.assertTrue(dest.is_dir())
            self.assertFalse(task_dir.exists())
            result = json.loads((dest / "queue-result.json").read_text(encoding="utf-8-sig"))
            self.assertEqual(result["status"], expected_state)
            if expected_error:
                self.assertEqual(result["error"], expected_error)

    def test_recovery_without_final_result_fails_interrupted(self):
        self._recover_case(None, "failed", "interrupted_before_completion")

    def test_recovery_honors_valid_done_terminal_proof(self):
        self._recover_case({"id": "recover-1", "status": "done", "exit_code": 0}, "done")

    def test_recovery_honors_valid_failed_terminal_proof(self):
        self._recover_case({"id": "recover-1", "status": "failed", "exit_code": 1}, "failed")

    def test_recovery_malformed_result_fails_interrupted(self):
        self._recover_case("malformed", "failed", "interrupted_before_completion")


if __name__ == "__main__":
    unittest.main()
