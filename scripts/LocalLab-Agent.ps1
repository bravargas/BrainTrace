[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Worker','Monitor')][string]$Kind,
    [Parameter(Mandatory=$true)][string]$Node,
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$StopFile,
    [Parameter(Mandatory=$true)][string]$StatusRoot,
    [ValidateRange(100,5000)][int]$IntervalMilliseconds=500
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$target=Join-Path $Root $(if($Kind-eq'Worker'){'Worker.ps1'}else{'Operations-Monitor.ps1'})
if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "LocalLab $Kind script not found: $target"}
if(-not(Test-Path -LiteralPath $StatusRoot)){New-Item -ItemType Directory -Path $StatusRoot -Force|Out-Null}
$statusPath=Join-Path $StatusRoot ($Node+'-'+$Kind+'.json')
$encoding=New-Object Text.UTF8Encoding($false)
$cycles=0

while(-not(Test-Path -LiteralPath $StopFile)){
    $started=[datetime]::UtcNow
    & $target -Root $Root -ConfigPath (Join-Path $Root 'NodeConfig.json') 6>&1|Out-Null
    $cycles++
    $status=[ordered]@{
        Node=$Node;Agent=$Kind;ProcessId=$PID;Cycles=$cycles;LastStartedUtc=$started.ToString('o')
        LastCompletedUtc=[datetime]::UtcNow.ToString('o');State='Running'
    }
    [IO.File]::WriteAllText($statusPath,($status|ConvertTo-Json),$encoding)
    Start-Sleep -Milliseconds $IntervalMilliseconds
}

