import json
import os
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INSTALL = REPO / "scripts" / "resident-queue" / "install-ufo-queue-worker.ps1"
UNINSTALL = REPO / "scripts" / "resident-queue" / "uninstall-ufo-queue-worker.ps1"


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def run_ps(command):
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
        cwd=REPO, text=True, capture_output=True,
    )


def run_install(task_name, queue_root, autostart_root):
    return subprocess.run(
        [
            "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(INSTALL),
            "-TaskName", task_name,
            "-QueueRoot", str(queue_root),
            "-AutostartRoot", str(autostart_root),
            "-NoStart",
        ],
        cwd=REPO, text=True, capture_output=True,
    )


def cleanup_task(task_name):
    run_ps(
        f"$t=Get-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue; "
        "if($t){Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue; "
        "Unregister-ScheduledTask -InputObject $t -Confirm:$false}"
    )


class ResidentQueueInstallTests(unittest.TestCase):
    def test_install_registers_hidden_single_current_user_logon_task(self):
        task_name = "UFO-Queue-Test-" + uuid.uuid4().hex[:10]
        try:
            with tempfile.TemporaryDirectory() as td:
                root = Path(td) / "queue"
                auto = Path(td) / "autostart"
                p = run_install(task_name, root, auto)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                inspect = run_ps(
                    f"$t=Get-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction Stop; "
                    "$a=$t.Actions|Select-Object -First 1; $tr=$t.Triggers|Select-Object -First 1; "
                    "[pscustomobject]@{hidden=$t.Settings.Hidden;multiple=[string]$t.Settings.MultipleInstances;"
                    "restart_count=$t.Settings.RestartCount;execute=$a.Execute;arguments=$a.Arguments;"
                    "trigger_type=$tr.CimClass.CimClassName;logon_type=[string]$t.Principal.LogonType;user_id=$t.Principal.UserId} "
                    "| ConvertTo-Json -Compress"
                )
                self.assertEqual(inspect.returncode, 0, inspect.stdout + inspect.stderr)
                shape = json.loads(inspect.stdout.strip().splitlines()[-1])
                self.assertTrue(shape["hidden"])
                self.assertIn("IgnoreNew", shape["multiple"])
                self.assertGreaterEqual(int(shape["restart_count"]), 1)
                self.assertTrue(shape["execute"].lower().endswith("powershell.exe"))
                for flag in ("-NoProfile", "-NonInteractive", "-WindowStyle Hidden", "-ExecutionPolicy Bypass", "-File"):
                    self.assertIn(flag, shape["arguments"])
                self.assertIn(str(auto / "ufo-queue-worker.ps1"), shape["arguments"])
                self.assertIn("LogonTrigger", shape["trigger_type"])
                self.assertTrue(shape["user_id"].lower().endswith(os.environ["USERNAME"].lower()))
                self.assertTrue(any(x in shape["logon_type"].lower() for x in ("interactive", "3")), shape["logon_type"])
                for filename in ("UfoQueue.Core.ps1", "ufo-queue-worker.ps1", "install-ufo-queue-worker.ps1", "uninstall-ufo-queue-worker.ps1"):
                    self.assertTrue((auto / filename).exists(), filename)
                for dirname in ("inbox", "running", "done", "failed", "logs", "state"):
                    self.assertTrue((root / dirname).is_dir(), dirname)
        finally:
            cleanup_task(task_name)

    def test_install_is_idempotent_and_uninstall_preserves_history(self):
        task_name = "UFO-Queue-Test-" + uuid.uuid4().hex[:10]
        try:
            with tempfile.TemporaryDirectory() as td:
                root = Path(td) / "queue"
                auto = Path(td) / "autostart"
                history = root / "done" / "history-1"
                history.mkdir(parents=True)
                (history / "queue-result.json").write_text('{"id":"history-1","status":"done"}', encoding="utf-8")
                first = run_install(task_name, root, auto)
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                second = run_install(task_name, root, auto)
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                count = run_ps(f"@(Get-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue).Count")
                self.assertEqual(count.returncode, 0, count.stdout + count.stderr)
                self.assertEqual(int(count.stdout.strip().splitlines()[-1]), 1)
                self.assertTrue((history / "queue-result.json").exists())
                uninstall = subprocess.run(
                    ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(UNINSTALL), "-TaskName", task_name],
                    cwd=REPO, text=True, capture_output=True,
                )
                self.assertEqual(uninstall.returncode, 0, uninstall.stdout + uninstall.stderr)
                count_after = run_ps(f"@(Get-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue).Count")
                self.assertEqual(int(count_after.stdout.strip().splitlines()[-1]), 0)
                self.assertTrue((history / "queue-result.json").exists())
        finally:
            cleanup_task(task_name)


if __name__ == "__main__":
    unittest.main()
