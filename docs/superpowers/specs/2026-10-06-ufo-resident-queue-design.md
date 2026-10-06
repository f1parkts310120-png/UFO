# UFO Resident Queue — Design Specification

## Purpose

Turn the validated local UFO pilot into a resident Windows capability that is ready after login, receives local tasks without opening PowerShell/Ollama windows, executes one task at a time through the existing UFO runner, and leaves an auditable result for every task.

The system must reuse the existing UFO installation, Ollama watchdog, and `ufo_interactive_runner.ps1`. It must not introduce a second agent runtime or a network-facing service in this phase.

## Success criteria

After Windows login:

1. Ollama is available through `http://127.0.0.1:11434` without `ollama app.exe` opening.
2. A hidden resident queue worker starts automatically.
3. A valid task dropped into the queue is detected and executed without a visible terminal.
4. Only one UFO interactive task runs at a time.
5. Each task ends in exactly one terminal state: `done` or `failed`.
6. The task result and execution metadata remain available after reboot.
7. Invalid queue payloads are rejected before invoking UFO.
8. The queue cannot request arbitrary shell execution directly.
9. The existing manual `ufo_interactive_runner.ps1` remains usable.

## Non-goals

This phase will not add:

- an HTTP API;
- remote access from other machines;
- a browser dashboard;
- multi-agent parallel desktop control;
- arbitrary command execution through the queue;
- automatic task generation from email, chat, browser activity, or external services;
- a replacement for the existing AI Factory resident supervisor.

Those can be layered on later after the local queue proves stable.

## Existing components to reuse

### Ollama watchdog

Existing scheduled task:

`UFO-Local-AI-Watchdog`

Existing script:

`D:\AI-Factory\ufo-pilot\autostart\ufo-local-watchdog.ps1`

Its responsibility remains limited to keeping the local Ollama API healthy and avoiding `ollama app.exe`.

### UFO runner

Existing runner:

`D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1`

It already provides:

- model selection;
- request file input;
- result file output;
- a named mutex that serializes UFO interactive execution;
- UTF-8 setup;
- execution through the validated UFO checkout.

The resident queue worker must call this runner instead of duplicating its logic.

## Architecture

The resident subsystem has one new runtime component: `ufo-queue-worker.ps1`.

Data flow:

`Windows logon -> hidden scheduled task -> queue worker -> inbox task -> validation -> running -> ufo_interactive_runner.ps1 -> done/failed`

The worker is a thin orchestration layer. It does not interpret the desktop task itself and does not call Ollama directly.

## Queue layout

Root:

`D:\AI-Factory\ufo-pilot\queue`

Directories:

- `inbox\` — newly submitted tasks;
- `running\` — task claimed by the worker;
- `done\` — successful tasks and results;
- `failed\` — rejected or failed tasks and results;
- `logs\` — worker operational log;
- `state\` — worker health and current-task state.

A task is represented by one JSON file. Moving the file between directories is the state transition mechanism. The worker must use same-volume atomic moves so a task cannot exist in two queue states at once.

## Task schema

Version 1 payload:

```json
{
  "schema_version": 1,
  "id": "20261006-001",
  "request": "Open the already running Notepad and type the requested text.",
  "model": "qwen3:4b-instruct-ufo",
  "timeout_seconds": 600
}
```

Required fields:

- `schema_version`: integer, exactly `1`;
- `id`: string, 1–80 characters, limited to letters, digits, dash, underscore and dot;
- `request`: non-empty UTF-8 string, maximum 12,000 characters.

Optional fields:

- `model`: if omitted, use the worker default;
- `timeout_seconds`: integer between 30 and 1800 seconds.

Allowed models are configured locally in the worker and are not free-form. Initial allow-list:

- `qwen3:4b-instruct-ufo`;
- `qwen3:8b-ufo20`.

The queue payload contains no executable path, shell command, PowerShell fragment, environment override, working directory, or runner arguments.

## Claiming and execution semantics

The worker polls `inbox` every two seconds.

For each candidate task, ordered by file creation time:

1. Read and parse JSON.
2. Validate filename, schema, ID, request length, model, and timeout.
3. Reject duplicate task IDs already present in `running`, `done`, or `failed`.
4. Atomically move the task from `inbox` to `running`.
5. Write `state\current.json` with the claimed task ID and start time.
6. Materialize a request text file and result JSON path under the task's working directory.
7. Start `ufo_interactive_runner.ps1 -Mode Task` hidden, passing only validated values.
8. Wait for completion up to the validated timeout.
9. If the timeout expires, terminate only the process tree created for that queue task and mark the task failed.
10. Capture exit code, runner result JSON, start time, finish time, duration, model, and error text if any.
11. Move the task directory to `done` only when the runner exits `0`; otherwise move it to `failed`.
12. Clear `state\current.json` and continue.

The worker itself processes exactly one queue task at a time. The runner mutex remains a second safety layer, not the primary queue scheduler.

## Task result structure

Each terminal task directory contains:

- `task.json` — original immutable request payload;
- `request.txt` — exact request passed to UFO;
- `runner-result.json` — raw result produced by the existing runner when available;
- `queue-result.json` — worker-level normalized result;
- `worker.log` — task-specific orchestration events.

`queue-result.json` contains at least:

```json
{
  "id": "20261006-001",
  "status": "done",
  "model": "qwen3:4b-instruct-ufo",
  "exit_code": 0,
  "started": "2026-10-06T14:00:00-03:00",
  "finished": "2026-10-06T14:01:12-03:00",
  "duration_seconds": 72
}
```

For failures it also contains a short `error` string.

## Resident worker lifecycle

The queue worker runs from a dedicated scheduled task named:

`UFO-Resident-Queue-Worker`

Properties:

- triggers: user logon plus a one-minute health trigger;
- health-trigger repetition duration: 3650 days, refreshed whenever the installer is run;
- hidden: true;
- run only in the current user session;
- `RestartOnFailure` remains configured, but the validated recovery mechanism on this host is the one-minute health trigger because forced termination and a nonzero action exit did not cause Task Scheduler to relaunch the already-started action;
- single scheduled-task instance with `MultipleInstances=IgnoreNew`, so health triggers are ignored while the resident worker is healthy;
- action: Windows PowerShell with `-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass`;
- script path fixed to the local `ufo-pilot\autostart` directory.

The worker writes a heartbeat to:

`queue\state\worker.json`

at least every 15 seconds, including PID, start time, last heartbeat, current task ID or `null`, and last completed task ID.

## Reboot and crash recovery

On startup, before consuming `inbox`, the worker inspects `running`.

A task left in `running` after worker/process termination is not silently retried. It is moved to `failed` with error `interrupted_before_completion` unless a valid final queue result already proves it completed.

This avoids repeating GUI actions after a reboot, where duplicate side effects could be harmful.

A future explicit retry feature can copy a failed task back into `inbox` with a new task ID.

## Security boundaries

The resident queue is local-file based and intentionally narrow.

The worker must enforce:

- queue root fixed under `D:\AI-Factory\ufo-pilot\queue`;
- no path supplied by task JSON is ever trusted;
- no shell command supplied by task JSON is ever evaluated;
- model values restricted to a local allow-list;
- task IDs sanitized before use in paths;
- result and working paths derived exclusively from sanitized task IDs;
- request size limit;
- one task at a time;
- bounded timeout;
- existing UFO shell-security restrictions remain unchanged.

The queue does not make the system safe for untrusted external users. Only trusted local components should be allowed to write tasks into `inbox` in this phase.

## Observability

Worker log:

`queue\logs\resident-worker.log`

Each important event is timestamped:

- worker start/stop;
- task discovered;
- validation rejected;
- task claimed;
- runner started;
- runner completed;
- timeout;
- task moved to done/failed;
- recovery of interrupted task;
- unexpected worker exception.

State files must be machine-readable JSON so the existing AI Factory Control Center can consume them later without changing this queue protocol.

## Failure handling

### Ollama unavailable

The queue worker does not start or restart Ollama itself. Before invoking UFO it probes the local Ollama API. If unavailable, it waits up to 60 seconds for the existing Ollama watchdog to recover it. If still unavailable, the queue task fails with `ollama_unavailable`.

### UFO runner busy

Normally impossible because the worker is serial. If another manually launched UFO task owns the runner mutex, the existing runner may wait up to its current mutex timeout and return its defined busy exit code. The queue records that as failure rather than bypassing the mutex.

### Invalid task

Invalid JSON/schema/model/ID/request is moved directly from `inbox` to `failed`; UFO is never started.

### Worker exception

The scheduled task restarts the worker. Recovery logic handles any task left in `running` as interrupted.

## Installation and rollback

Installation script:

`D:\AI-Factory\ufo-pilot\autostart\install-ufo-queue-worker.ps1`

It creates the queue directories and the hidden scheduled task idempotently.

Rollback script:

`D:\AI-Factory\ufo-pilot\autostart\uninstall-ufo-queue-worker.ps1`

It stops and unregisters only `UFO-Resident-Queue-Worker`. It does not remove task history, the UFO checkout, the Ollama watchdog, or the manual runner.

## Testing strategy

Implementation must be test-driven.

### Unit-level PowerShell tests or deterministic test harness

Cover:

- valid schema accepted;
- malformed JSON rejected;
- invalid task ID rejected;
- oversized request rejected;
- unapproved model rejected;
- duplicate task ID rejected;
- timeout bounds enforced;
- terminal directory choice follows runner exit code;
- stale `running` task becomes `failed` on recovery;
- no task field can alter executable/script paths.

### Integration gates

1. **Queue success gate:** submit a safe Notepad task and confirm it moves `inbox -> running -> done` with exit code `0` and exact visible text.
2. **Invalid payload gate:** submit a task containing an unapproved model and confirm it moves directly to `failed` without starting UFO.
3. **Serialization gate:** submit two safe tasks and confirm the second does not enter execution until the first reaches a terminal state.
4. **Restart gate:** terminate the resident worker while idle, confirm the one-minute health trigger starts a new worker instance and heartbeat resumes without manual intervention.
5. **Crash recovery gate:** simulate a stale task in `running` and confirm it is marked `interrupted_before_completion`, not replayed.
6. **Visibility gate:** confirm the worker and runner execute with no visible PowerShell window and `ollama app.exe` remains absent.
7. **Regression gate:** rerun the existing relevant UFO test suite and the previously validated GUI ValuePattern gate.

## Rollout order

1. Implement queue parsing/validation and filesystem state transitions without executing UFO.
2. Add runner invocation and timeout handling.
3. Add heartbeat and crash recovery.
4. Add install/uninstall scripts and scheduled task.
5. Run unit/deterministic tests.
6. Run safe live Notepad integration gates.
7. Leave the resident worker enabled only after all gates pass.

## Future-compatible interface

The filesystem queue is the stable local contract for this phase. A future Control Center button, local HTTP adapter, voice layer, or ChatGPT-connected component may submit tasks by writing validated JSON into `inbox`.

Those future adapters must remain producers of the same queue contract rather than calling UFO directly. This keeps serialization, auditing, recovery, and safety in one place.
