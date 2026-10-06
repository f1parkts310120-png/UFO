# UFO Resident Queue — Operations

The resident queue runs locally after Windows logon and accepts trusted local task JSON files.

## Production paths

- Queue root: `D:\AI-Factory\ufo-pilot\queue`
- Inbox: `D:\AI-Factory\ufo-pilot\queue\inbox`
- Running: `D:\AI-Factory\ufo-pilot\queue\running`
- Done: `D:\AI-Factory\ufo-pilot\queue\done`
- Failed: `D:\AI-Factory\ufo-pilot\queue\failed`
- Worker state: `D:\AI-Factory\ufo-pilot\queue\state\worker.json`
- Worker log: `D:\AI-Factory\ufo-pilot\queue\logs\resident-worker.log`
- Deployed worker: `D:\AI-Factory\ufo-pilot\autostart\ufo-queue-worker.ps1`
- Scheduled task: `UFO-Resident-Queue-Worker`

## Minimal task

```json
{
  "schema_version": 1,
  "id": "example-001",
  "request": "Open the already running Notepad and type the requested text.",
  "model": "qwen3:4b-instruct-ufo",
  "timeout_seconds": 600
}
```

`schema_version`, `id`, and `request` are required. Allowed models are `qwen3:4b-instruct-ufo` and `qwen3:8b-ufo20`. The default model is `qwen3:4b-instruct-ufo`; the default timeout is 600 seconds.

Producers should write to a temporary sibling file first and then rename/move it into `inbox` so the worker never sees a partially written payload.

## Status and results

Read `state\worker.json` to see the resident PID, heartbeat, current task ID, and last completed task ID. The heartbeat advances while idle and while a task is running.

Each terminal task directory contains the original `task.json`, exact `request.txt`, `queue-result.json`, task-specific `worker.log`, and `runner-result.json` when the UFO runner produced one.

A task is successful only when it reaches `done`. Rejected, interrupted, timed-out, or runner-failed tasks are retained under `failed` with an `error` in `queue-result.json`.

## Automatic recovery

The scheduled task has a logon trigger plus a one-minute health trigger. `MultipleInstances=IgnoreNew` prevents parallel workers while the current worker is alive. If the resident worker disappears, the next health trigger starts a new instance; startup recovery marks any stale `running` task as `interrupted_before_completion` instead of replaying desktop actions.

The health trigger is registered with a long repetition duration and is refreshed whenever the installer is run.

## Rollback

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\AI-Factory\ufo-pilot\autostart\uninstall-ufo-queue-worker.ps1
```

Rollback stops and unregisters only `UFO-Resident-Queue-Worker`. It does not delete queue history, the Ollama watchdog, the UFO checkout, or the manual `ufo_interactive_runner.ps1`.

## Trust boundary

Only trusted local components should write tasks into `inbox`. Queue JSON never supplies executable paths, shell commands, PowerShell fragments, environment overrides, working directories, or arbitrary runner arguments. Existing UFO shell-security restrictions remain in force.
