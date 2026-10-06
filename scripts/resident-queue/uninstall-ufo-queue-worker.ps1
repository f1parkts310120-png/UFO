param(
    [string]$TaskName = 'UFO-Resident-Queue-Worker'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -InputObject $task -Confirm:$false
}

Write-Output "uninstalled:$TaskName"
