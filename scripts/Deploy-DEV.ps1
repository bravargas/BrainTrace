[CmdletBinding()]
param([switch]$CreateScheduledTasks)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $repositoryRoot 'src') 'BrainTrace.Common.ps1')

$config=Get-BrainTraceEnvironmentConfig DEV $repositoryRoot
$computer=[string]$env:COMPUTERNAME
$targets=@($config.Nodes|Where-Object{$_.DeploymentManager-ieq$computer})
if($targets.Count-eq0){throw "Run this launcher only on a configured tier manager: TP1, App1, or Web1. Current computer: $computer."}
$tier=@($targets|ForEach-Object{if($null-ne$_.PSObject.Properties['Alias']){$_.Alias}else{$_.Name}})-join', '

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Open Windows PowerShell as Administrator, then run this launcher again.'
}

$deployment=Join-Path $PSScriptRoot 'Deploy-BrainTrace.ps1'
Write-Host "`nBrainTrace DEV deployment from $computer"
Write-Host "Targets: $tier`n"
& $deployment -Environment DEV -Manager $computer -CreateScheduledTasks:$CreateScheduledTasks -WhatIf

$operation=if($CreateScheduledTasks){'install files and Scheduled Tasks'}else{'update files without changing Scheduled Tasks'}
$answer=Read-Host "Type Y to $operation for $tier, or press ENTER to cancel"
if($answer-ine'Y'){
    Write-Host 'Deployment cancelled. No files or Scheduled Tasks were changed.'
    return
}

& $deployment -Environment DEV -Manager $computer -CreateScheduledTasks:$CreateScheduledTasks
Write-Host "`nDeployment completed for $tier."
