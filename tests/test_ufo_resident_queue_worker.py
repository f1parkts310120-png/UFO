import json
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORKER = REPO / "scripts" / "resident-queue" / "ufo-queue-worker.ps1"


def ps_quote(v):
    return "'" + str(v).replace("'", "''") + "'"


def run_worker_ps(body):
    script = "$ErrorActionPreference='Stop'\n. " + ps_quote(WORKER) + " -LibraryOnly\n" + body
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
        cwd=REPO, text=True, capture_output=True,
    )


class _TagsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/tags":
            body = b'{"models":[]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, fmt, *args):
        pass


class TagsServer:
    def __enter__(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _TagsHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        return self
    def __exit__(self, *_):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)


class ResidentQueueWorkerTests(unittest.TestCase):
    def make_runner(self, directory, marker, sleep_ms=100):
        path = Path(directory) / "worker-fake-runner.ps1"
        path.write_text(f'''param([string]$Mode,[string]$RequestFile,[string]$TaskName,[string]$Model,[string]$ResultFile)
Add-Content -Path {ps_quote(marker)} -Value ($TaskName + " START")
Start-Sleep -Milliseconds {int(sleep_ms)}
[ordered]@{{task=$TaskName;model=$Model;exit_code=0}} | ConvertTo-Json | Set-Content $ResultFile -Encoding UTF8
Add-Content -Path {ps_quote(marker)} -Value ($TaskName + " FINISH")
exit 0
''', encoding="utf-8")
        return path

    def submit(self, root, payload, filename):
        inbox = Path(root) / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        p = inbox / filename
        if isinstance(payload, str):
            p.write_text(payload, encoding="utf-8")
        else:
            p.write_text(json.dumps(payload), encoding="utf-8")
        return p

    def test_heartbeat_is_valid_json_and_updates_fields(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "queue"
            p = run_worker_ps(
                f"Initialize-UfoQueueLayout -QueueRoot {ps_quote(root)} | Out-Null; "
                "$s=[datetime]'2026-10-06T10:00:00Z'; "
                f"Write-UfoQueueHeartbeat -QueueRoot {ps_quote(root)} -Started $s -CurrentTaskId 'a' -LastCompletedTaskId $null; "
                f"Write-UfoQueueHeartbeat -QueueRoot {ps_quote(root)} -Started $s -CurrentTaskId $null -LastCompletedTaskId 'a'"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            hb = json.loads((root / "state" / "worker.json").read_text(encoding="utf-8-sig"))
            self.assertGreater(hb["pid"], 0)
            self.assertEqual(hb["current_task_id"], None)
            self.assertEqual(hb["last_completed_task_id"], "a")
            self.assertIn("started", hb)
            self.assertIn("last_heartbeat", hb)

    def test_active_execution_can_refresh_heartbeat_callback(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            root = Path(td)
            task_dir = root / "task"; task_dir.mkdir()
            pulse = root / "pulse.log"
            marker = root / "marker.log"
            runner = self.make_runner(root, marker, sleep_ms=900)
            task = task_dir / "task.json"
            task.write_text(json.dumps({"schema_version":1,"id":"pulse-1","request":"wait","model":"qwen3:4b-instruct-ufo","timeout_seconds":30}), encoding="utf-8")
            p = run_worker_ps(
                f"$raw=Read-UfoQueueTaskFile -Path {ps_quote(task)}; "
                "$t=Test-UfoQueueTaskPayload -Payload $raw -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels @('qwen3:4b-instruct-ufo','qwen3:8b-ufo20'); "
                f"$pulse={{ Add-Content -Path {ps_quote(pulse)} -Value 'pulse' }}; "
                f"Invoke-UfoQueuedTask -TaskDirectory {ps_quote(task_dir)} -Task $t -RunnerPath {ps_quote(runner)} -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2 -HeartbeatScript $pulse -HeartbeatPollMilliseconds 150 | Out-Null"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertGreaterEqual(len(pulse.read_text().splitlines()), 2)

    def test_two_tasks_run_in_creation_order_without_overlap(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            root = Path(td) / "queue"
            marker = Path(td) / "order.log"
            runner = self.make_runner(td, marker, sleep_ms=250)
            first = {"schema_version":1,"id":"one","request":"first","model":"qwen3:4b-instruct-ufo","timeout_seconds":30}
            second = {"schema_version":1,"id":"two","request":"second","model":"qwen3:4b-instruct-ufo","timeout_seconds":30}
            self.submit(root, first, "a.json"); time.sleep(0.12); self.submit(root, second, "b.json")
            p = run_worker_ps(
                f"Invoke-UfoQueueWorkerLoop -QueueRoot {ps_quote(root)} -RunnerPath {ps_quote(runner)} -DefaultModel 'qwen3:4b-instruct-ufo' -PollSeconds 1 -Once -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual(marker.read_text().splitlines(), ["one START", "one FINISH", "two START", "two FINISH"])
            self.assertTrue((root / "done" / "one" / "queue-result.json").exists())
            self.assertTrue((root / "done" / "two" / "queue-result.json").exists())

    def test_invalid_payloads_move_failed_without_runner(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            root = Path(td) / "queue"
            marker = Path(td) / "runner.log"
            runner = self.make_runner(td, marker)
            self.submit(root, '{"schema_version":1,', "broken.json")
            self.submit(root, {"schema_version":1,"id":"bad-model","request":"x","model":"evil-model","timeout_seconds":30}, "bad-model.json")
            p = run_worker_ps(
                f"Invoke-UfoQueueWorkerLoop -QueueRoot {ps_quote(root)} -RunnerPath {ps_quote(runner)} -DefaultModel 'qwen3:4b-instruct-ufo' -PollSeconds 1 -Once -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual(list((root / "inbox").glob("*.json")), [])
            results = [json.loads(x.read_text(encoding="utf-8-sig")) for x in (root / "failed").glob("*/queue-result.json")]
            self.assertEqual(len(results), 2)
            errors = " ".join(r.get("error", "") for r in results)
            self.assertIn("invalid_json", errors)
            self.assertIn("unapproved_model", errors)

    def test_partial_json_is_rejected_deterministically(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            root = Path(td) / "queue"
            marker = Path(td) / "runner.log"
            runner = self.make_runner(td, marker)
            self.submit(root, '{"schema_version":1,"id":"partial"', "partial.json")
            p = run_worker_ps(
                f"Invoke-UfoQueueWorkerLoop -QueueRoot {ps_quote(root)} -RunnerPath {ps_quote(runner)} -DefaultModel 'qwen3:4b-instruct-ufo' -PollSeconds 1 -Once -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertFalse(marker.exists())
            results = list((root / "failed").glob("*/queue-result.json"))
            self.assertEqual(len(results), 1)
            self.assertIn("invalid_json", json.loads(results[0].read_text(encoding="utf-8-sig"))["error"])

    def test_worker_startup_recovers_stale_running_without_replay(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            root = Path(td) / "queue"
            stale = root / "running" / "stale-1"; stale.mkdir(parents=True)
            (stale / "task.json").write_text(json.dumps({"schema_version":1,"id":"stale-1","request":"do not replay"}), encoding="utf-8")
            marker = Path(td) / "runner.log"
            runner = self.make_runner(td, marker)
            p = run_worker_ps(
                f"Invoke-UfoQueueWorkerLoop -QueueRoot {ps_quote(root)} -RunnerPath {ps_quote(runner)} -DefaultModel 'qwen3:4b-instruct-ufo' -PollSeconds 1 -Once -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2"
            )
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertFalse(marker.exists())
            result = json.loads((root / "failed" / "stale-1" / "queue-result.json").read_text(encoding="utf-8-sig"))
            self.assertEqual(result["error"], "interrupted_before_completion")


if __name__ == "__main__":
    unittest.main()
