Set-StrictMode -Version Latest

function Get-UfoQueueCanonicalPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-UfoQueuePathUnderRoot {
    param(
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $root = (Get-UfoQueueCanonicalPath -Path $QueueRoot).TrimEnd([char]'\',[char]'/')
    $candidate = Get-UfoQueueCanonicalPath -Path $Path
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($candidate, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path_outside_queue_root"
    }
    return $candidate
}

function Test-UfoQueueIntegerValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Initialize-UfoQueueLayout {
    param([Parameter(Mandatory=$true)][string]$QueueRoot)
    $root = Get-UfoQueueCanonicalPath -Path $QueueRoot
    $layout = [ordered]@{ root = $root }
    foreach ($name in @('inbox','running','done','failed','logs','state')) {
        $path = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $root $name)
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
        $layout[$name] = $path
    }
    return $layout
}

function Read-UfoQueueTaskFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { throw "task_file_missing" }
    try {
        $raw = [System.IO.File]::ReadAllText((Get-UfoQueueCanonicalPath -Path $Path), [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "empty_json" }
        $payload = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "invalid_json: $($_.Exception.Message)"
    }
    if ($null -eq $payload -or $payload -is [System.Array]) { throw "invalid_json_object" }
    return $payload
}

function Test-UfoQueueTaskPayload {
    param(
        [Parameter(Mandatory=$true)]$Payload,
        [Parameter(Mandatory=$true)][string]$DefaultModel,
        [Parameter(Mandatory=$true)][string[]]$AllowedModels
    )
    $names = @($Payload.PSObject.Properties.Name)
    if ($names -notcontains 'schema_version' -or -not (Test-UfoQueueIntegerValue $Payload.schema_version) -or [int64]$Payload.schema_version -ne 1) {
        throw "invalid_schema_version"
    }
    if ($names -notcontains 'id' -or $Payload.id -isnot [string] -or $Payload.id -notmatch '^[A-Za-z0-9._-]{1,80}$') {
        throw "invalid_task_id"
    }
    if ($names -notcontains 'request' -or $Payload.request -isnot [string] -or [string]::IsNullOrWhiteSpace($Payload.request) -or $Payload.request.Length -gt 12000) {
        throw "invalid_request"
    }

    $model = $DefaultModel
    if ($names -contains 'model') { $model = $Payload.model }
    if ($model -isnot [string] -or -not ($AllowedModels -ccontains $model)) { throw "unapproved_model" }

    $timeout = 600
    if ($names -contains 'timeout_seconds') {
        if (-not (Test-UfoQueueIntegerValue $Payload.timeout_seconds)) { throw "invalid_timeout" }
        $timeout = [int]$Payload.timeout_seconds
    }
    if ($timeout -lt 30 -or $timeout -gt 1800) { throw "invalid_timeout" }

    return [pscustomobject][ordered]@{
        schema_version = 1
        id = [string]$Payload.id
        request = [string]$Payload.request
        model = [string]$model
        timeout_seconds = [int]$timeout
    }
}

function Get-UfoQueueTaskPaths {
    param(
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][string]$TaskId
    )
    if ($TaskId -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "invalid_task_id" }
    $root = Get-UfoQueueCanonicalPath -Path $QueueRoot
    $taskDirectory = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path (Join-Path $root 'running') $TaskId)
    return [pscustomobject][ordered]@{
        task_directory = $taskDirectory
        task_json = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $taskDirectory 'task.json')
        request_txt = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $taskDirectory 'request.txt')
        runner_result_json = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $taskDirectory 'runner-result.json')
        queue_result_json = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $taskDirectory 'queue-result.json')
        worker_log = Assert-UfoQueuePathUnderRoot -QueueRoot $root -Path (Join-Path $taskDirectory 'worker.log')
    }
}

function Test-UfoQueueDuplicateId {
    param(
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][string]$TaskId
    )
    if ($TaskId -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "invalid_task_id" }
    $root = Get-UfoQueueCanonicalPath -Path $QueueRoot
    foreach ($state in @('running','done','failed')) {
        $stateDir = Join-Path $root $state
        if (-not (Test-Path -LiteralPath $stateDir)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $stateDir -Filter 'task.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            try {
                $payload = Read-UfoQueueTaskFile -Path $file.FullName
                if ($payload.PSObject.Properties.Name -contains 'id' -and [string]$payload.id -ceq $TaskId) { return $true }
            } catch {
                continue
            }
        }
    }
    return $false
}

function Claim-UfoQueueTask {
    param(
        [Parameter(Mandatory=$true)][string]$InboxPath,
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)]$Task
    )
    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    if ($Task.id -isnot [string] -or $Task.id -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "invalid_task_id" }
    $source = Assert-UfoQueuePathUnderRoot -QueueRoot $layout.root -Path $InboxPath
    $inboxPrefix = $layout.inbox.TrimEnd([char]'\',[char]'/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $source.StartsWith($inboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "source_not_in_inbox" }
    if (-not [System.IO.File]::Exists($source)) { throw "task_file_missing" }

    $paths = Get-UfoQueueTaskPaths -QueueRoot $layout.root -TaskId $Task.id
    if ([System.IO.Directory]::Exists($paths.task_directory) -or [System.IO.File]::Exists($paths.task_json)) { throw "task_already_claimed" }
    [System.IO.Directory]::CreateDirectory($paths.task_directory) | Out-Null
    try {
        [System.IO.File]::Move($source, $paths.task_json)
    } catch {
        if ([System.IO.Directory]::Exists($paths.task_directory) -and -not [System.IO.File]::Exists($paths.task_json)) {
            try { [System.IO.Directory]::Delete($paths.task_directory, $false) } catch {}
        }
        throw
    }
    return $paths
}

function Write-UfoQueueResult {
    param(
        [Parameter(Mandatory=$true)][string]$TaskDirectory,
        [Parameter(Mandatory=$true)]$Result
    )
    $dir = Get-UfoQueueCanonicalPath -Path $TaskDirectory
    if (-not [System.IO.Directory]::Exists($dir)) { throw "task_directory_missing" }
    $target = Join-Path $dir 'queue-result.json'
    $token = [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString() + '.' + [guid]::NewGuid().ToString('N')
    $temp = Join-Path $dir ('.queue-result.' + $token + '.tmp')
    $backup = Join-Path $dir ('.queue-result.' + $token + '.bak')
    $json = $Result | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
    try {
        if ([System.IO.File]::Exists($target)) {
            [System.IO.File]::Replace($temp, $target, $backup)
        } else {
            [System.IO.File]::Move($temp, $target)
        }
    } finally {
        if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
        if ([System.IO.File]::Exists($backup)) { [System.IO.File]::Delete($backup) }
    }
}

function Complete-UfoQueueTask {
    param(
        [Parameter(Mandatory=$true)][string]$TaskDirectory,
        [Parameter(Mandatory=$true)][string]$QueueRoot,
        [Parameter(Mandatory=$true)][ValidateSet('done','failed')][string]$Status
    )
    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    $source = Assert-UfoQueuePathUnderRoot -QueueRoot $layout.root -Path $TaskDirectory
    $runningPrefix = $layout.running.TrimEnd([char]'\',[char]'/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $source.StartsWith($runningPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "task_not_in_running" }
    if (-not [System.IO.Directory]::Exists($source)) { throw "task_directory_missing" }
    $name = [System.IO.Path]::GetFileName($source.TrimEnd([char]'\',[char]'/'))
    if ($name -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw "invalid_task_id" }
    $terminalRoot = if ($Status -ceq 'done') { $layout.done } else { $layout.failed }
    $destination = Assert-UfoQueuePathUnderRoot -QueueRoot $layout.root -Path (Join-Path $terminalRoot $name)
    if ([System.IO.Directory]::Exists($destination) -or [System.IO.File]::Exists($destination)) { throw "terminal_task_exists" }
    [System.IO.Directory]::Move($source, $destination)
    return $destination
}

function Recover-UfoQueueRunningTasks {
    param([Parameter(Mandatory=$true)][string]$QueueRoot)
    $layout = Initialize-UfoQueueLayout -QueueRoot $QueueRoot
    $events = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $layout.running -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $taskId = $dir.Name
        $taskJson = Join-Path $dir.FullName 'task.json'
        try {
            if (Test-Path -LiteralPath $taskJson) {
                $payload = Read-UfoQueueTaskFile -Path $taskJson
                if ($payload.PSObject.Properties.Name -contains 'id' -and $payload.id -is [string] -and $payload.id -match '^[A-Za-z0-9._-]{1,80}$') {
                    $taskId = [string]$payload.id
                }
            }
        } catch {}
        if ($taskId -notmatch '^[A-Za-z0-9._-]{1,80}$') { $taskId = 'interrupted-' + [guid]::NewGuid().ToString('N') }

        $terminalStatus = $null
        $resultPath = Join-Path $dir.FullName 'queue-result.json'
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $proofRaw = [System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8)
                $proof = $proofRaw | ConvertFrom-Json -ErrorAction Stop
                $hasStatus = $proof.PSObject.Properties.Name -contains 'status'
                $hasId = $proof.PSObject.Properties.Name -contains 'id'
                if ($hasStatus -and $hasId -and ([string]$proof.id -ceq $taskId) -and @('done','failed') -ccontains [string]$proof.status) {
                    $terminalStatus = [string]$proof.status
                }
            } catch {
                $terminalStatus = $null
            }
        }

        if ($null -eq $terminalStatus) {
            $failure = [ordered]@{
                id = $taskId
                status = 'failed'
                exit_code = $null
                finished = (Get-Date).ToString('o')
                duration_seconds = 0
                error = 'interrupted_before_completion'
            }
            Write-UfoQueueResult -TaskDirectory $dir.FullName -Result $failure
            $terminalStatus = 'failed'
        }

        $destination = Complete-UfoQueueTask -TaskDirectory $dir.FullName -QueueRoot $layout.root -Status $terminalStatus
        $events += [pscustomobject][ordered]@{ id = $taskId; status = $terminalStatus; destination = $destination }
    }
    return $events
}
