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
        [int]$ExecutionTimeoutSeconds = 0
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
    $completed = $proc.WaitForExit([int]([math]::Min([int64]::MaxValue, [int64]$timeoutSeconds * 1000)))
    if (-not $completed) {
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

# Task 4 adds the resident poll loop. Task 3 intentionally exposes only library behavior.
