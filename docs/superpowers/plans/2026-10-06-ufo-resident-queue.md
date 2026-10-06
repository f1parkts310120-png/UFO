# UFO Resident Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a hidden, reboot-resilient local filesystem queue that validates trusted local UFO tasks, executes them one at a time through the existing `ufo_interactive_runner.ps1`, and records durable `done`/`failed` results.

**Architecture:** Keep one resident PowerShell worker and one focused queue-core library as the only new runtime subsystem. Canonical sources live in the UFO repository under `scripts/resident-queue`; the installer deploys fixed copies to `D:\AI-Factory\ufo-pilot\autostart`, where Task Scheduler launches the worker hidden. The worker never interprets shell commands from task JSON and delegates actual UFO execution to the existing runner.

**Tech Stack:** Windows PowerShell 5.1, Task Scheduler, NTFS same-volume moves, JSON files, Python `unittest` as the deterministic cross-process harness, existing UFO runner and Ollama HTTP API.

**Spec:** `docs/superpowers/specs/2026-10-06-ufo-resident-queue-design.md`

## Global Constraints

- Queue root is fixed at `D:\AI-Factory\ufo-pilot\queue` in production.
- Queue state directories are `inbox`, `running`, `done`, `failed`, `logs`, and `state`.
- Poll interval is exactly 2 seconds in production.
- Heartbeat interval is at most 15 seconds.
- `schema_version` must be integer `1`.
- `id` length is 1–80 and matches only letters, digits, dash, underscore, and dot.
- `request` is non-empty UTF-8 text with a maximum of 12,000 characters.
- `timeout_seconds` is an integer from 30 through 1800 inclusive; default is 600.
- Initial allowed models are exactly `qwen3:4b-instruct-ufo` and `qwen3:8b-ufo20`; default is `qwen3:4b-instruct-ufo`.
- Task JSON must never control executable paths, PowerShell fragments, environment overrides, working directories, or runner arguments.
- Exactly one queue task executes at a time; the existing runner mutex remains the second safety layer.
- Worker waits up to 60 seconds for the existing Ollama watchdog before failing `ollama_unavailable`.
- Stale `running` tasks are never replayed automatically; they fail with `interrupted_before_completion` unless a valid terminal queue result already proves completion.
- Existing manual `D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1` behavior must remain unchanged.
- Existing UFO shell-security restrictions must remain unchanged.

## Review Focus

- Producer writes a JSON file slowly or incompletely: worker must reject malformed JSON deterministically and must never execute UFO from partial content.
- A second file reuses an existing task ID under a different filename: duplicate-ID detection must search terminal and running states by payload ID, not only by filename.
- Worker dies after runner completion but before terminal move: recovery must honor an already-valid `queue-result.json` terminal proof and must not replay GUI work.
- Runner exits `0` but `runner-result.json` is missing or malformed: queue still records normalized worker metadata without inventing runner data.
- Worker timeout leaves descendants alive: timeout handling must terminate the entire process tree created for that task before moving it to `failed`.

---

### Task 1: Queue Core, Layout, and Schema Validation

**Files:**
- Create: `scripts/resident-queue/UfoQueue.Core.ps1`
- Create: `tests/test_ufo_resident_queue_core.py`

**Interfaces:**
- Consumes: no earlier task interfaces.
- Produces:
  - `Initialize-UfoQueueLayout -QueueRoot <string> -> [hashtable]` containing absolute paths for `inbox`, `running`, `done`, `failed`, `logs`, `state`.
  - `Read-UfoQueueTaskFile -Path <string> -> [pscustomobject]` or terminating validation error.
  - `Test-UfoQueueTaskPayload -Payload <pscustomobject> -DefaultModel <string> -AllowedModels <string[]> -> [pscustomobject]` normalized task with fields `schema_version`, `id`, `request`, `model`, `timeout_seconds`.
  - `Get-UfoQueueTaskPaths -QueueRoot <string> -TaskId <string> -> [pscustomobject]` with paths derived only from sanitized `TaskId`.
  - `Test-UfoQueueDuplicateId -QueueRoot <string> -TaskId <string> -> [bool]` checking `running`, `done`, and `failed` payload IDs.

- [ ] **Step 1: Write failing tests for valid normalization**

Add `test_valid_payload_applies_defaults` asserting schema `1`, model `qwen3:4b-instruct-ufo`, timeout `600`, and unchanged request/ID.

- [ ] **Step 2: Write failing tests for all schema rejection rules**

Add tests asserting rejection of malformed JSON, wrong schema version, empty request, request length `12001`, ID outside `[A-Za-z0-9._-]`, ID length `81`, unapproved model, timeout `29`, timeout `1801`, and non-integer timeout.

- [ ] **Step 3: Write the path-injection regression test**

Add `test_payload_cannot_override_runtime_paths` with fields such as `runner_path`, `working_directory`, `command`, `arguments`, and `environment`; assert normalized output contains none of them and all derived paths remain under the provided test queue root.

- [ ] **Step 4: Write duplicate-ID tests**

Create terminal/running fixtures whose filenames differ from their payload `id`; assert `Test-UfoQueueDuplicateId` detects the duplicate by payload ID.

- [ ] **Step 5: Run Task 1 tests and verify RED**

Run:

```powershell
cd D:\AI-Factory\ufo-pilot\UFO
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_core -v
```

Expected: FAIL because `UfoQueue.Core.ps1` and exported functions do not exist.

- [ ] **Step 6: Implement the minimal queue-core functions**

Implement only the interfaces above. Use `ConvertFrom-Json`, anchored regex `^[A-Za-z0-9._-]{1,80}$`, exact model membership, explicit integer/bounds checks, `Join-Path`, and canonical absolute-path containment checks.

- [ ] **Step 7: Run Task 1 tests and verify GREEN**

Run the same unittest command. Expected: all Task 1 tests PASS.

- [ ] **Step 8: Commit Task 1**

```powershell
git add scripts/resident-queue/UfoQueue.Core.ps1 tests/test_ufo_resident_queue_core.py
git commit -m "feat: add UFO queue validation core"
```

---

### Task 2: Atomic Queue Transitions and Crash Recovery

**Files:**
- Modify: `scripts/resident-queue/UfoQueue.Core.ps1`
- Create: `tests/test_ufo_resident_queue_transitions.py`

**Interfaces:**
- Consumes: Task 1 normalized task and queue-layout functions.
- Produces:
  - `Claim-UfoQueueTask -InboxPath <string> -QueueRoot <string> -Task <pscustomobject> -> [pscustomobject]` that same-volume moves the source into `running\<id>\task.json` and materializes task workspace paths.
  - `Write-UfoQueueResult -TaskDirectory <string> -Result <hashtable> -> <void>` via temp-file + atomic replace/move.
  - `Complete-UfoQueueTask -TaskDirectory <string> -QueueRoot <string> -Status <done|failed> -> <string>` returning the terminal directory.
  - `Recover-UfoQueueRunningTasks -QueueRoot <string> -> [object[]]` returning recovery events.

- [ ] **Step 1: Write failing claim/atomicity tests**

Assert a successful claim removes the inbox file, creates exactly one running task directory, preserves the original payload as `task.json`, and never leaves the same task in both states.

- [ ] **Step 2: Write failing completion tests**

Assert `exit_code=0` maps to `done`; nonzero and validation failure map to `failed`; terminal move preserves `task.json`, `request.txt`, `runner-result.json` when present, `queue-result.json`, and `worker.log`.

- [ ] **Step 3: Write failing stale-running recovery tests**

Cover:
- no final result -> `failed` with `error=interrupted_before_completion`;
- existing valid `queue-result.json` with `status=done` -> move to `done` without invoking runner;
- existing valid `queue-result.json` with `status=failed` -> move to `failed`;
- malformed terminal result -> treat as interrupted, never replay.

- [ ] **Step 4: Run Task 2 tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_transitions -v
```

Expected: FAIL with missing transition/recovery functions.

- [ ] **Step 5: Implement same-volume state transitions and recovery**

Use `Move-Item` only within the fixed queue root. Write `queue-result.json` through a sibling temporary file before rename. Never call the runner from recovery.

- [ ] **Step 6: Run Task 1 + Task 2 tests and verify GREEN**

Run:

```powershell
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_core tests.test_ufo_resident_queue_transitions -v
```

Expected: all tests PASS.

- [ ] **Step 7: Commit Task 2**

```powershell
git add scripts/resident-queue/UfoQueue.Core.ps1 tests/test_ufo_resident_queue_transitions.py
git commit -m "feat: add UFO queue state transitions"
```

---

### Task 3: Runner Invocation, Ollama Gate, Timeout, and Process-Tree Cleanup

**Files:**
- Create: `scripts/resident-queue/ufo-queue-worker.ps1`
- Create: `tests/test_ufo_resident_queue_execution.py`

**Interfaces:**
- Consumes: Task 1/2 core functions; existing `D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1` in production.
- Produces:
  - worker parameters `-QueueRoot`, `-RunnerPath`, `-DefaultModel`, `-PollSeconds`, `-Once`; production scheduled task supplies none except the fixed deployed script path.
  - `Wait-UfoOllamaReady -BaseUrl <string> -TimeoutSeconds 60 -> [bool]`.
  - `Invoke-UfoQueuedTask -TaskDirectory <string> -Task <pscustomobject> -RunnerPath <string> -> [hashtable]` normalized result with `id`, `status`, `model`, `exit_code`, `started`, `finished`, `duration_seconds`, optional `error`.

- [ ] **Step 1: Write a fake-runner success test**

Use a temporary PowerShell runner that writes a valid runner result and exits `0`. Assert exact request text is materialized to `request.txt`, fixed validated model is passed, normalized status is `done`, and no payload field changes the executable path.

- [ ] **Step 2: Write runner-result robustness tests**

Cover runner exit `0` with missing `runner-result.json` and malformed runner result. Assert `queue-result.json` remains valid and does not invent raw-runner fields.

- [ ] **Step 3: Write the timeout/process-tree test**

Fake runner starts a child process and sleeps beyond a short injected test timeout. Assert the worker marks failure with a timeout error and both parent and child PIDs are gone before terminal transition.

- [ ] **Step 4: Write Ollama-unavailable test**

Point the test worker at a closed localhost port with an injected short probe window; assert failure `ollama_unavailable` and assert the runner was never started.

- [ ] **Step 5: Run Task 3 tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_execution -v
```

Expected: FAIL because the worker execution functions do not exist.

- [ ] **Step 6: Implement hidden runner execution and bounded timeout**

Use `Start-Process powershell.exe -WindowStyle Hidden -PassThru` with fixed runner path and validated arguments only. On timeout, terminate the process tree with Windows tree-aware termination and verify the root PID is gone before writing failure state.

- [ ] **Step 7: Implement Ollama readiness gate**

Probe only `http://127.0.0.1:11434/api/tags` in production; wait up to 60 seconds. Do not start or restart Ollama here.

- [ ] **Step 8: Run Tasks 1–3 tests and verify GREEN**

Run the three unittest modules together. Expected: all PASS.

- [ ] **Step 9: Commit Task 3**

```powershell
git add scripts/resident-queue/ufo-queue-worker.ps1 tests/test_ufo_resident_queue_execution.py
git commit -m "feat: execute queued UFO tasks safely"
```

---

### Task 4: Resident Poll Loop, Heartbeat, Serialization, and Operational Logging

**Files:**
- Modify: `scripts/resident-queue/ufo-queue-worker.ps1`
- Modify: `scripts/resident-queue/UfoQueue.Core.ps1`
- Create: `tests/test_ufo_resident_queue_worker.py`

**Interfaces:**
- Consumes: Task 3 `Invoke-UfoQueuedTask`.
- Produces:
  - `Write-UfoQueueHeartbeat -QueueRoot <string> -Started <datetime> -CurrentTaskId <string|null> -LastCompletedTaskId <string|null> -> <void>` writing `state\worker.json`.
  - resident loop polling every 2 seconds in production, creation-time ordering, exactly one active task.
  - timestamped `queue\logs\resident-worker.log` and task-local `worker.log`.

- [ ] **Step 1: Write heartbeat tests**

Assert `worker.json` contains PID, `started`, `last_heartbeat`, `current_task_id`, and `last_completed_task_id`; repeated writes remain valid JSON.

- [ ] **Step 2: Write serialization/order tests**

Submit two fixture tasks with distinct creation times and fake runners that record start/finish markers. Assert task 2 never starts before task 1 reaches terminal state and ordering follows creation time.

- [ ] **Step 3: Write invalid-payload no-runner test**

Drop malformed JSON and an unapproved-model payload into `inbox`; assert each moves to `failed` and fake-runner invocation count remains zero.

- [ ] **Step 4: Write partial/incomplete JSON producer test**

Create malformed/incomplete JSON as a completed inbox file and assert deterministic rejection with a validation error; no UFO invocation occurs.

- [ ] **Step 5: Run Task 4 tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_worker -v
```

Expected: FAIL with missing heartbeat/resident-loop behavior.

- [ ] **Step 6: Implement resident loop and heartbeat**

On startup call recovery before polling. During idle and active states refresh heartbeat at least every 15 seconds. Catch per-task failures so one bad task does not kill the worker; catch unexpected top-level failure, log it, then exit nonzero so Task Scheduler can restart it.

- [ ] **Step 7: Run Tasks 1–4 tests and verify GREEN**

Run all four resident-queue unittest modules. Expected: all PASS.

- [ ] **Step 8: Commit Task 4**

```powershell
git add scripts/resident-queue/UfoQueue.Core.ps1 scripts/resident-queue/ufo-queue-worker.ps1 tests/test_ufo_resident_queue_worker.py
git commit -m "feat: add resident UFO queue loop"
```

---

### Task 5: Idempotent Deployment, Scheduled Task, and Rollback

**Files:**
- Create: `scripts/resident-queue/install-ufo-queue-worker.ps1`
- Create: `scripts/resident-queue/uninstall-ufo-queue-worker.ps1`
- Create: `tests/test_ufo_resident_queue_install.py`

**Interfaces:**
- Consumes: committed worker/core sources from Tasks 1–4.
- Produces production deployment files:
  - `D:\AI-Factory\ufo-pilot\autostart\UfoQueue.Core.ps1`
  - `D:\AI-Factory\ufo-pilot\autostart\ufo-queue-worker.ps1`
  - `D:\AI-Factory\ufo-pilot\autostart\install-ufo-queue-worker.ps1`
  - `D:\AI-Factory\ufo-pilot\autostart\uninstall-ufo-queue-worker.ps1`
  - Scheduled task `UFO-Resident-Queue-Worker`.

- [ ] **Step 1: Write installation-shape tests**

Assert install script uses user-logon trigger, hidden settings, single instance, restart-on-failure, current user session, and action flags `-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass` with fixed deployed worker path.

- [ ] **Step 2: Write idempotence and rollback tests**

Run install twice in a safe test task name/root; assert one scheduled task instance and intact queue history. Run uninstall; assert only that task is removed and history directories remain.

- [ ] **Step 3: Run Task 5 tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_install -v
```

Expected: FAIL because deployment scripts do not exist.

- [ ] **Step 4: Implement install script**

Copy canonical source files to the fixed autostart directory, create queue directories idempotently, register the hidden scheduled task, and start it. Do not modify `UFO-Local-AI-Watchdog` or `ufo_interactive_runner.ps1`.

- [ ] **Step 5: Implement uninstall script**

Stop and unregister only `UFO-Resident-Queue-Worker`. Leave queue history, watchdog, UFO checkout, Ollama, and manual runner untouched.

- [ ] **Step 6: Run Task 5 tests and verify GREEN**

Run the installation test module. Expected: all PASS.

- [ ] **Step 7: Commit Task 5**

```powershell
git add scripts/resident-queue/install-ufo-queue-worker.ps1 scripts/resident-queue/uninstall-ufo-queue-worker.ps1 tests/test_ufo_resident_queue_install.py
git commit -m "feat: install resident UFO queue worker"
```

---

### Task 6: Production Gates, Regression Verification, and Operator Notes

**Files:**
- Create: `docs/resident-queue-operations.md`
- Modify only if a gate exposes a defect: files owned by Tasks 1–5, with a new regression test before each fix.

**Interfaces:**
- Consumes: complete resident queue subsystem.
- Produces: enabled production scheduled task only after all gates pass; concise operator instructions for submit/status/rollback.

- [ ] **Step 1: Run the full deterministic resident-queue suite**

Run:

```powershell
cd D:\AI-Factory\ufo-pilot\UFO
.\.venv\Scripts\python.exe -m unittest tests.test_ufo_resident_queue_core tests.test_ufo_resident_queue_transitions tests.test_ufo_resident_queue_execution tests.test_ufo_resident_queue_worker tests.test_ufo_resident_queue_install -v
```

Expected: zero failures/errors.

- [ ] **Step 2: Re-run the existing relevant UFO regression suite**

Include the existing security, direct-tool routing/status, Ollama reasoning, control-resolution, legacy-response, text-input verification, and UI ValuePattern tests already validated on this machine. Expected: zero failures/errors.

- [ ] **Step 3: Install production worker and verify hidden resident state**

Run the committed installer. Verify Task Scheduler reports `UFO-Resident-Queue-Worker` running and hidden, `queue\state\worker.json` heartbeat advances, no visible PowerShell window appears, and `ollama app.exe` remains absent.

- [ ] **Step 4: Run queue success gate with Notepad**

Open a disposable Notepad document, submit schema-v1 JSON to `inbox`, and assert `inbox -> running -> done`, queue exit code `0`, exact visible text, exact `request.txt`, valid `runner-result.json` when produced, and valid `queue-result.json`.

- [ ] **Step 5: Run invalid payload gate**

Submit an unapproved model and assert direct `failed` transition, explicit validation error, and no UFO process start for that task.

- [ ] **Step 6: Run serialization gate**

Submit two safe tasks and confirm via timestamps/logs that task 2 starts only after task 1 terminal state.

- [ ] **Step 7: Run restart gate while idle**

Terminate only the resident worker process and verify Task Scheduler restarts it and heartbeat resumes without manual intervention.

- [ ] **Step 8: Run crash-recovery gate**

Create/simulate a stale running task, restart the worker, and verify terminal failure `interrupted_before_completion` with no runner invocation/replay.

- [ ] **Step 9: Re-run the validated GUI ValuePattern live gate**

Confirm exact Notepad text via UI Automation and successful UFO evaluation while the resident system is installed.

- [ ] **Step 10: Write operator notes**

Document only: production queue path, minimal schema example, how to inspect `state\worker.json`, where results/logs live, how to uninstall, and the rule that producers write only trusted local tasks.

- [ ] **Step 11: Final verification before leaving worker enabled**

Verify all of the following simultaneously: scheduled worker running+hidden, advancing heartbeat, Ollama API healthy, `ollama app.exe` absent, no task stuck in `running`, deterministic suite green, relevant UFO regression suite green, live Notepad gate green.

- [ ] **Step 12: Commit Task 6**

```powershell
git add docs/resident-queue-operations.md
git commit -m "docs: add resident UFO queue operations"
```
