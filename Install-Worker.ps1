[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][string]$Environment,
    [Parameter(Mandatory=$true)][string]$Node,
    [string]$Destination='D:\FiservSoftware\PowerShell\BrainTrace',
    [switch]$CreateScheduledTask,
    [ValidateRange(1,1440)][int]$IntervalMinutes=1,
    [string]$TaskUser='SYSTEM'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')
$config=Get-BrainTraceEnvironmentConfig $Environment $PSScriptRoot
$nodeConfig=Get-BrainTraceNode $config $Node
if($null-eq$nodeConfig){throw "Node '$Node' is not in environment '$($config.Environment)'."}

if($PSCmdlet.ShouldProcess($Destination,"Install BrainTrace Worker for $Node")){
    foreach($folder in @($Destination,(Join-Path $Destination 'Commands'),(Join-Path $Destination 'Status'),(Join-Path $Destination 'Archive'),(Join-Path $Destination 'Logs'))){
        if(-not(Test-Path -LiteralPath $folder)){New-Item -ItemType Directory -Path $folder -Force|Out-Null}
    }
    foreach($fileName in @('Worker.ps1','BrainTrace.Common.ps1','Test-Worker.ps1')){
        $sourcePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $fileName))
        $destinationPath=[IO.Path]::GetFullPath((Join-Path $Destination $fileName))
        if(-not$sourcePath.Equals($destinationPath,[StringComparison]::OrdinalIgnoreCase)){
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
    }
    Write-BrainTraceJsonAtomic ([ordered]@{LocalNode=$nodeConfig.Name;EnvironmentConfig=$config}) (Join-Path $Destination 'NodeConfig.json')
}

if($CreateScheduledTask){
    if($PSCmdlet.ShouldProcess('BrainTrace-Worker','Register scheduled task')){
        $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $Destination 'Worker.ps1')+'"')
        # Task Scheduler rejects TimeSpan.MaxValue when serialized into task XML.
        # Ten years is deliberately finite, valid, and operationally sufficient for the MVP.
        $trigger=New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal=New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'BrainTrace-Worker' -Action $action -Trigger $trigger -Principal $principal -Description "BrainTrace Worker for $($config.Environment)/$Node" -Force|Out-Null
    }
}

[pscustomobject]@{Environment=$config.Environment;Node=$nodeConfig.Name;Destination=$Destination;ScheduledTask=[bool]$CreateScheduledTask}
