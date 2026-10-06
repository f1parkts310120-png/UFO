param(
    [string]$TaskName = 'UFO-Resident-Queue-Worker',
    [string]$QueueRoot = 'D:\AI-Factory\ufo-pilot\queue',
    [string]$AutostartRoot = 'D:\AI-Factory\ufo-pilot\autostart',
    [string]$RunnerPath = 'D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1',
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$productionQueueRoot = 'D:\AI-Factory\ufo-pilot\queue'
$productionRunnerPath = 'D:\AI-Factory\ufo-pilot\ufo_interactive_runner.ps1'
$sourceRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$deployRoot = [System.IO.Path]::GetFullPath($AutostartRoot)
[System.IO.Directory]::CreateDirectory($deployRoot) | Out-Null

foreach ($name in @('inbox','running','done','failed','logs','state')) {
    [System.IO.Directory]::CreateDirectory((Join-Path ([System.IO.Path]::GetFullPath($QueueRoot)) $name)) | Out-Null
}

foreach ($file in @('UfoQueue.Core.ps1','ufo-queue-worker.ps1','install-ufo-queue-worker.ps1','uninstall-ufo-queue-worker.ps1')) {
    $source = Join-Path $sourceRoot $file
    $destination = Join-Path $deployRoot $file
    if (-not [System.IO.File]::Exists($source)) { throw "deployment_source_missing:$file" }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($source), [System.IO.Path]::GetFullPath($destination), [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

$workerPath = Join-Path $deployRoot 'ufo-queue-worker.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $workerPath + '"'
if (-not [string]::Equals([System.IO.Path]::GetFullPath($QueueRoot), [System.IO.Path]::GetFullPath($productionQueueRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
    $arguments += ' -QueueRoot "' + [System.IO.Path]::GetFullPath($QueueRoot) + '"'
}
if (-not [string]::Equals([System.IO.Path]::GetFullPath($RunnerPath), [System.IO.Path]::GetFullPath($productionRunnerPath), [System.StringComparison]::OrdinalIgnoreCase)) {
    $arguments += ' -RunnerPath "' + [System.IO.Path]::GetFullPath($RunnerPath) + '"'
}

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
}

Write-Output "installed:$TaskName"
