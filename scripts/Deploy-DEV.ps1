[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $repositoryRoot 'src') 'BrainTrace.Common.ps1')

$config=Get-BrainTraceEnvironmentConfig DEV $repositoryRoot
$computer=[string]$env:COMPUTERNAME
if($computer-ieq$config.Aggregator){
    $roles=@('APP','WEB')
    $tier='App1, App2, Web1, and Web2'
}elseif($computer-ieq$config.Controller){
    $roles=@('TP')
    $tier='TP1 and TP2'
}else{
    throw "Run this launcher only on App1 ($($config.Aggregator)) or TP1 ($($config.Controller)). Current computer: $computer."
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Open Windows PowerShell as Administrator, then run this launcher again.'
}

$deployment=Join-Path $PSScriptRoot 'Deploy-BrainTrace.ps1'
Write-Host "`nBrainTrace DEV deployment from $computer"
Write-Host "Targets: $tier`n"
& $deployment -Environment DEV -Role $roles -WhatIf

$answer=Read-Host "Type Y to install/update $tier, or press ENTER to cancel"
if($answer-ine'Y'){
    Write-Host 'Deployment cancelled. No files or Scheduled Tasks were changed.'
    return
}

& $deployment -Environment DEV -Role $roles
Write-Host "`nDeployment completed for $tier."
