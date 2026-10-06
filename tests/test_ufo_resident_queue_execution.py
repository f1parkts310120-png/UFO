import json
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORKER = REPO / "scripts" / "resident-queue" / "ufo-queue-worker.ps1"


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


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
            self.send_response(404)
            self.end_headers()

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
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def process_exists(pid):
    p = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", f"if(Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue){{exit 0}}else{{exit 1}}"],
        capture_output=True,
    )
    return p.returncode == 0


class ResidentQueueExecutionTests(unittest.TestCase):
    def make_runner(self, directory, behavior="success"):
        runner = Path(directory) / f"fake-{behavior}-runner.ps1"
        common = r'''param(
    [string]$Mode,
    [string]$RequestFile,
    [string]$TaskName,
    [string]$Model,
    [string]$ResultFile
)
$taskDir = Split-Path -Parent $RequestFile
$request = [IO.File]::ReadAllText($RequestFile)
[ordered]@{ task=$TaskName; model=$Model; request=$request; runner=$PSCommandPath } | ConvertTo-Json | Set-Content (Join-Path $taskDir 'invocation.json') -Encoding UTF8
'''
        if behavior == "success":
            tail = r'''[ordered]@{ task=$TaskName; model=$Model; exit_code=0 } | ConvertTo-Json | Set-Content $ResultFile -Encoding UTF8
exit 0
'''
        elif behavior == "missing-result":
            tail = "exit 0\n"
        elif behavior == "malformed-result":
            tail = "Set-Content $ResultFile '{bad' -Encoding UTF8\nexit 0\n"
        elif behavior == "timeout-tree":
            tail = r'''$child = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60'
Set-Content (Join-Path $taskDir 'parent.pid') $PID
Set-Content (Join-Path $taskDir 'child.pid') $child.Id
Start-Sleep -Seconds 60
exit 0
'''
        else:
            raise ValueError(behavior)
        runner.write_text(common + tail, encoding="utf-8")
        return runner

    def invoke(self, task_dir, runner, base_url, payload=None, ready_timeout=2):
        task_dir = Path(task_dir)
        task_dir.mkdir(parents=True, exist_ok=True)
        payload = payload or {"schema_version": 1, "id": "exec-1", "request": "exact request", "model": "qwen3:4b-instruct-ufo", "timeout_seconds": 30}
        task_json = task_dir / "task.json"
        task_json.write_text(json.dumps(payload), encoding="utf-8")
        body = (
            f"$raw=Read-UfoQueueTaskFile -Path {ps_quote(task_json)}; "
            "$task=Test-UfoQueueTaskPayload -Payload $raw -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels @('qwen3:4b-instruct-ufo','qwen3:8b-ufo20'); "
            f"$r=Invoke-UfoQueuedTask -TaskDirectory {ps_quote(task_dir)} -Task $task -RunnerPath {ps_quote(runner)} -OllamaBaseUrl {ps_quote(base_url)} -OllamaReadyTimeoutSeconds {int(ready_timeout)}; "
            "$r | ConvertTo-Json -Depth 8 -Compress"
        )
        p = run_worker_ps(body)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return json.loads(p.stdout.strip().splitlines()[-1])

    def test_fake_runner_success_uses_exact_request_model_and_fixed_runner(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            task_dir = Path(td) / "running" / "exec-1"
            runner = self.make_runner(td, "success")
            payload = {
                "schema_version": 1,
                "id": "exec-1",
                "request": "ação exata Ω",
                "model": "qwen3:8b-ufo20",
                "timeout_seconds": 30,
                "runner_path": "C:\\evil.ps1",
                "command": "calc.exe",
            }
            result = self.invoke(task_dir, runner, server.url, payload)
            self.assertEqual(result["status"], "done")
            self.assertEqual(result["exit_code"], 0)
            self.assertEqual((task_dir / "request.txt").read_text(encoding="utf-8-sig"), payload["request"])
            invocation = json.loads((task_dir / "invocation.json").read_text(encoding="utf-8-sig"))
            self.assertEqual(invocation["model"], "qwen3:8b-ufo20")
            self.assertEqual(invocation["request"], payload["request"])
            self.assertEqual(Path(invocation["runner"]).resolve(), runner.resolve())

    def test_exit_zero_missing_or_malformed_runner_result_still_normalizes(self):
        for behavior in ("missing-result", "malformed-result"):
            with self.subTest(behavior=behavior), tempfile.TemporaryDirectory() as td, TagsServer() as server:
                task_dir = Path(td) / "task"
                runner = self.make_runner(td, behavior)
                result = self.invoke(task_dir, runner, server.url)
                self.assertEqual(result["status"], "done")
                self.assertEqual(result["exit_code"], 0)
                normalized_input = task_dir / "normalized-input.json"
                normalized_input.write_text(json.dumps(result), encoding="utf-8")
                p = run_worker_ps(
                    f"$r=Get-Content -Raw -Encoding UTF8 {ps_quote(normalized_input)} | ConvertFrom-Json; "
                    f"Write-UfoQueueResult -TaskDirectory {ps_quote(task_dir)} -Result $r"
                )
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                normalized = json.loads((task_dir / "queue-result.json").read_text(encoding="utf-8-sig"))
                self.assertEqual(normalized["status"], "done")
                self.assertNotIn("raw_runner", normalized)

    def test_timeout_kills_parent_and_child_process_tree_before_return(self):
        with tempfile.TemporaryDirectory() as td, TagsServer() as server:
            task_dir = Path(td) / "task"
            runner = self.make_runner(td, "timeout-tree")
            payload = {"schema_version": 1, "id": "timeout-1", "request": "sleep", "model": "qwen3:4b-instruct-ufo", "timeout_seconds": 30}
            task_dir.mkdir(parents=True)
            task_json = task_dir / "task.json"
            task_json.write_text(json.dumps(payload), encoding="utf-8")
            body = (
                f"$raw=Read-UfoQueueTaskFile -Path {ps_quote(task_json)}; "
                "$task=Test-UfoQueueTaskPayload -Payload $raw -DefaultModel 'qwen3:4b-instruct-ufo' -AllowedModels @('qwen3:4b-instruct-ufo','qwen3:8b-ufo20'); "
                f"$r=Invoke-UfoQueuedTask -TaskDirectory {ps_quote(task_dir)} -Task $task -RunnerPath {ps_quote(runner)} -OllamaBaseUrl {ps_quote(server.url)} -OllamaReadyTimeoutSeconds 2 -ExecutionTimeoutSeconds 1; "
                "$r | ConvertTo-Json -Depth 8 -Compress"
            )
            p = run_worker_ps(body)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            result = json.loads(p.stdout.strip().splitlines()[-1])
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "timeout")
            parent = int((task_dir / "parent.pid").read_text().strip())
            child = int((task_dir / "child.pid").read_text().strip())
            self.assertFalse(process_exists(parent), parent)
            self.assertFalse(process_exists(child), child)

    def test_ollama_unavailable_never_starts_runner(self):
        with tempfile.TemporaryDirectory() as td:
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            sock.close()
            task_dir = Path(td) / "task"
            runner = self.make_runner(td, "success")
            result = self.invoke(task_dir, runner, f"http://127.0.0.1:{port}", ready_timeout=1)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "ollama_unavailable")
            self.assertFalse((task_dir / "invocation.json").exists())


if __name__ == "__main__":
    unittest.main()
