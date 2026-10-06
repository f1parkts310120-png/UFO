param(
    [string]$QueueRoot = 'D:\AI-Factory\ufo-pilot\queue',
    [string]$RunnerPath = 'D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1',
    [string]$DefaultModel = 'qwen3:4b-instruct-ufo',
    [int]$PollSeconds = 2,
    [switch]$Once,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'UfoQueue.Core.ps1')

function Wait-UfoOllamaReady {
    param(
        [Parameter(Mandatory=$true)][string]$BaseUrl,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds
    )
    if ($TimeoutSeconds -lt 0) { throw 'invalid_ollama_timeout' }
    $uri = $BaseUrl.TrimEnd('/') + '/api/tags'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 2 -ErrorAction Stop
            return $true
        } catch {}
        if ([DateTime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 250
    } while ($true)
}

function Quote-UfoProcessArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    return '"' + $Value.Replace('"','\"') + '"'
}

function Stop-UfoProcessTree {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $taskkill /PID $ProcessId /T /F 2>$null | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $alive = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $alive) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'process_tree_termination_failed'
}

function New-UfoQueueExecutionResult {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][string]$Status,
        $ExitCode,
        [Parameter(Mandatory=$true)][datetime]$Started,
        [Parameter(Mandatory=$true)][datetime]$Finished,
        [string]$ErrorText
    )
    $duration = [math]::Max(0, [math]::Round(($Finished - $Started).TotalSeconds, 3))
    $result = [ordered]@{
        id = [string]$Task.id
        status = $Status
        model = [string]$Task.model
        exit_code = $ExitCode
        started = $Started.ToString('o')
        finished = $Finished.ToString('o')
        duration_seconds = $duration
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorText)) { $result.error = $ErrorText }
    return [pscustomobject]$result
}

function Invoke-UfoQueuedTask {
    param(
        [Parameter(Mandatory=$true)][string]$TaskDirectory,
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][string]$RunnerPath,
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
        [int]$OllamaReadyTimeoutSeconds = 60,
        [int]$ExecutionTimeoutSeconds = 0,
        [scriptblock]$HeartbeatScript,
        [int]$HeartbeatPollMilliseconds = 5000
    )
    $taskDir = [System.IO.Path]::GetFullPath($TaskDirectory)
    if (-not [System.IO.Directory]::Exists($taskDir)) { throw 'task_directory_missing' }
    $runner = [System.IO.Path]::GetFullPath($RunnerPath)
    if (-not [System.IO.File]::Exists($runner)) { throw 'runner_missing' }

    $requestPath = Join-Path $taskDir 'request.txt'
    $runnerResultPath = Join-Path $taskDir 'runner-result.json'
    [System.IO.File]::WriteAllText($requestPath, [string]$Task.request, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($runnerResultPath)) { [System.IO.File]::Delete($runnerResultPath) }

    $started = Get-Date
    if (-not (Wait-UfoOllamaReady -BaseUrl $OllamaBaseUrl -TimeoutSeconds $OllamaReadyTimeoutSeconds)) {
        $finished = Get-Date
        return New-UfoQueueExecutionResult -Task $Task -Status 'failed' -ExitCode $null -Started $started -Finished $finished -ErrorText 'ollama_unavailable'
    }

    $timeoutSeconds = if ($ExecutionTimeoutSeconds -gt 0) { $ExecutionTimeoutSeconds } else { [int]$Task.timeout_seconds }
    if ($timeoutSeconds -le 0) { throw 'invalid_execution_timeout' }
    if ($HeartbeatPollMilliseconds -lt 50) { throw 'invalid_heartbeat_poll_interval' }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentLine = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-UfoProcessArgument $runner),
        '-Mode', 'Task',
        '-Model', (Quote-UfoProcessArgument ([string]$Task.model)),
        '-TaskName', (Quote-UfoProcessArgument ([string]$Task.id)),
        '-ResultFile', (Quote-UfoProcessArgument $runnerResultPath),
        '-RequestFile', (Quote-UfoProcessArgument $requestPath)
    ) -join ' '

    $proc = Start-Process -FilePath $powershell -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    $completed = $false
    do {
        $remainingMs = [int][math]::Max(0, [math]::Min([int64]::MaxValue, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        if ($remainingMs -le 0) { break }
        $sliceMs = [int][math]::Min($HeartbeatPollMilliseconds, $remainingMs)
        if ($proc.WaitForExit($sliceMs)) { $completed = $true; break }
        if ($null -ne $HeartbeatScript) { & $HeartbeatScript }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $completed -and -not $proc.HasExited) {
        Stop-UfoProcessTree -ProcessId $proc.Id
        $finished = Get-Date
        return New-UfoQueueExecutionResult -Task $Task -Status 'failed' -ExitCode 124 -Started $started -Finished $finished -ErrorText 'timeout'
    }

    $proc.WaitForExit()
    $exitCode = [int]$proc.ExitCode
    $finished = Get-Date
    if ($exitCode -eq 0) {
        return New-UfoQueueExecutionResult -Task $Task -Status 'done' -ExitCode $exitCode -Started $started -Finished $finished
    }
    return New-UfoQueueExecutionResult -Task $Task -Status 'failed' -ExitCode $exitCode -Started $started -Finished $finished -ErrorText ('runner_exit_' + $exitCode)
}

function Write-UfoWorkerLog {
    param(
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$TaskDirectory
    )
    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    $line = (Get-Date).ToString('o') + ' ' + $Message
    Add-Content -LiteralPath (Join-Path $layout.logs 'resident-worker.log') -Value $line -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($TaskDirectory) -and [System.IO.Directory]::Exists($TaskDirectory)) {
        Add-Content -LiteralPath (Join-Path $TaskDirectory 'worker.log') -Value $line -Encoding UTF8
    }
}

function New-UfoRejectedTaskDirectoryName {
    param([string]$Hint)
    $safe = if ([string]::IsNullOrWhiteSpace($Hint)) { 'task' } else { [regex]::Replace($Hint, '[^A-Za-z0-9._-]', '_') }
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0,40) }
    return 'rejected-' + $safe + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
}

function Reject-UfoInboxTask {
    param(
        [Parameter(Mandatory=$true)][string]$InboxPath,
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        $Payload,
        [Parameter(Mandatory=$true)][string]$ErrorText
    )
    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    $source = Assert-UfoQueuePathUnderRoot -QueueRoot $layout.root -Path $InboxPath
    $hint = [System.IO.Path]::GetFileNameWithoutExtension($source)
    $resultId = $hint
    $model = $null
    if ($null -ne $Payload) {
        if ($Payload.PSObject.Properties.Name -contains 'id' -and $Payload.id -is [string] -and $Payload.id -match '^[A-Za-z0-9._-]{1,80}$') {
            $resultId = [string]$Payload.id
            $hint = $resultId
        }
        if ($Payload.PSObject.Properties.Name -contains 'model' -and $Payload.model -is [string]) { $model = [string]$Payload.model }
    }
    $destName = New-UfoRejectedTaskDirectoryName -Hint $hint
    $dest = Join-Path $layout.failed $destName
    [System.IO.Directory]::CreateDirectory($dest) | Out-Null
    [System.IO.File]::Move($source, (Join-Path $dest 'task.json'))
    $now = Get-Date
    $result = [ordered]@{
        id = $resultId
        status = 'failed'
        model = $model
        exit_code = $null
        started = $now.ToString('o')
        finished = $now.ToString('o')
        duration_seconds = 0
        error = $ErrorText
    }
    Write-UfoQueueResult -TaskDirectory $dest -Result $result
    Write-UfoWorkerLog -QueueRoot $layout.root -TaskDirectory $dest -Message ('validation rejected: ' + $ErrorText)
    return $dest
}

function Get-UfoNextInboxFile {
    param([Parameter(Mandatory=$true)][string]$InboxDirectory)
    return Get-ChildItem -LiteralPath $InboxDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object CreationTimeUtc, Name |
        Select-Object -First 1
}

function Invoke-UfoQueueWorkerLoop {
    param(
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][string]$RunnerPath,
        [string]$DefaultModel = 'qwen3:4b-instruct-ufo',
        [int]$PollSeconds = 2,
        [switch]$Once,
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
        [int]$OllamaReadyTimeoutSeconds = 60
    )
    if ($PollSeconds -lt 0) { throw 'invalid_poll_interval' }
    $allowedModels = @('qwen3:4b-instruct-ufo','qwen3:8b-ufo20')
    if (-not ($allowedModels -ccontains $DefaultModel)) { throw 'unapproved_default_model' }

    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    $workerStarted = Get-Date
    $lastCompleted = $null
    Write-UfoWorkerLog -QueueRoot $layout.root -Message 'worker started'
    foreach ($event in @(Recover-UfoQueueRunningTasks -QueueRoot $layout.root)) {
        Write-UfoWorkerLog -QueueRoot $layout.root -Message ('recovered ' + $event.id + ' -> ' + $event.status)
        $lastCompleted = [string]$event.id
    }
    Clear-UfoQueueCurrentState -QueueRoot $layout.root
    Write-UfoQueueHeartbeat -QueueRoot $layout.root -Started $workerStarted -CurrentTaskId $null -LastCompletedTaskId $lastCompleted

    while ($true) {
        $candidate = Get-UfoNextInboxFile -InboxDirectory $layout.inbox
        if ($null -eq $candidate) {
            Write-UfoQueueHeartbeat -QueueRoot $layout.root -Started $workerStarted -CurrentTaskId $null -LastCompletedTaskId $lastCompleted
            if ($Once) { break }
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $raw = $null
        $task = $null
        $claimedDirectory = $null
        try {
            $raw = Read-UfoQueueTaskFile -Path $candidate.FullName
            $task = Test-UfoQueueTaskPayload -Payload $raw -DefaultModel $DefaultModel -AllowedModels $allowedModels
            if (Test-UfoQueueDuplicateId -QueueRoot $layout.root -TaskId $task.id) { throw 'duplicate_task_id' }

            $claimed = Claim-UfoQueueTask -InboxPath $candidate.FullName -QueueRoot $layout.root -Task $task
            $claimedDirectory = $claimed.task_directory
            $taskStarted = Get-Date
            Write-UfoQueueCurrentState -QueueRoot $layout.root -TaskId $task.id -Started $taskStarted
            Write-UfoWorkerLog -QueueRoot $layout.root -TaskDirectory $claimedDirectory -Message ('task claimed: ' + $task.id)
            Write-UfoQueueHeartbeat -QueueRoot $layout.root -Started $workerStarted -CurrentTaskId $task.id -LastCompletedTaskId $lastCompleted

            $heartbeatRoot = $layout.root
            $heartbeatStarted = $workerStarted
            $heartbeatTask = [string]$task.id
            $heartbeatLast = $lastCompleted
            $heartbeat = {
                Write-UfoQueueHeartbeat -QueueRoot $heartbeatRoot -Started $heartbeatStarted -CurrentTaskId $heartbeatTask -LastCompletedTaskId $heartbeatLast
            }.GetNewClosure()

            $result = Invoke-UfoQueuedTask -TaskDirectory $claimedDirectory -Task $task -RunnerPath $RunnerPath -OllamaBaseUrl $OllamaBaseUrl -OllamaReadyTimeoutSeconds $OllamaReadyTimeoutSeconds -HeartbeatScript $heartbeat -HeartbeatPollMilliseconds 5000
            Write-UfoQueueResult -TaskDirectory $claimedDirectory -Result $result
            Write-UfoWorkerLog -QueueRoot $layout.root -TaskDirectory $claimedDirectory -Message ('runner completed: ' + $result.status)
            $null = Complete-UfoQueueTask -TaskDirectory $claimedDirectory -QueueRoot $layout.root -Status $result.status
            $lastCompleted = [string]$task.id
            $claimedDirectory = $null
            Write-UfoWorkerLog -QueueRoot $layout.root -Message ('task terminal: ' + $task.id + ' -> ' + $result.status)
        } catch {
            $errorText = $_.Exception.Message
            if ($null -ne $claimedDirectory -and [System.IO.Directory]::Exists($claimedDirectory)) {
                $now = Get-Date
                $failureId = if ($null -ne $task) { [string]$task.id } else { [System.IO.Path]::GetFileName($claimedDirectory) }
                $failureModel = if ($null -ne $task) { [string]$task.model } else { $null }
                $failure = [ordered]@{
                    id = $failureId
                    status = 'failed'
                    model = $failureModel
                    exit_code = $null
                    started = $now.ToString('o')
                    finished = $now.ToString('o')
                    duration_seconds = 0
                    error = ('worker_exception:' + $errorText)
                }
                Write-UfoQueueResult -TaskDirectory $claimedDirectory -Result $failure
                Write-UfoWorkerLog -QueueRoot $layout.root -TaskDirectory $claimedDirectory -Message $failure.error
                $null = Complete-UfoQueueTask -TaskDirectory $claimedDirectory -QueueRoot $layout.root -Status 'failed'
                $lastCompleted = $failureId
                $claimedDirectory = $null
            } elseif ([System.IO.File]::Exists($candidate.FullName)) {
                $null = Reject-UfoInboxTask -InboxPath $candidate.FullName -QueueRoot $layout.root -Payload $raw -ErrorText $errorText
            } else {
                Write-UfoWorkerLog -QueueRoot $layout.root -Message ('orphan worker exception: ' + $errorText)
            }
        } finally {
            Clear-UfoQueueCurrentState -QueueRoot $layout.root
            Write-UfoQueueHeartbeat -QueueRoot $layout.root -Started $workerStarted -CurrentTaskId $null -LastCompletedTaskId $lastCompleted
        }
    }

    Write-UfoWorkerLog -QueueRoot $layout.root -Message 'worker stopped'
}

if (-not $LibraryOnly) {
    try {
        Invoke-UfoQueueWorkerLoop -QueueRoot $QueueRoot -RunnerPath $RunnerPath -DefaultModel $DefaultModel -PollSeconds $PollSeconds -Once:$Once
        exit 0
    } catch {
        try { Write-UfoWorkerLog -QueueRoot $QueueRoot -Message ('fatal worker exception: ' + $_.Exception.Message) } catch {}
        exit 1
    }
}
