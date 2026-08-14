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
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$sourceRoot=Join-Path $repositoryRoot 'src'
. (Join-Path $sourceRoot 'BrainTrace.Common.ps1')
$config=Get-BrainTraceEnvironmentConfig $Environment $repositoryRoot
$nodeConfig=Get-BrainTraceNode $config $Node
if($null-eq$nodeConfig){throw "Node '$Node' is not in environment '$($config.Environment)'."}

if($PSCmdlet.ShouldProcess($Destination,"Install BrainTrace Worker for $Node")){
    foreach($folder in @($Destination,(Join-Path $Destination 'Commands'),(Join-Path $Destination 'Status'),(Join-Path $Destination 'Archive'),(Join-Path $Destination 'Logs'))){
        if(-not(Test-Path -LiteralPath $folder)){New-Item -ItemType Directory -Path $folder -Force|Out-Null}
    }
    $runtimeFiles=[ordered]@{
        'Worker.ps1'=(Join-Path $sourceRoot 'Worker.ps1')
        'BrainTrace.Common.ps1'=(Join-Path $sourceRoot 'BrainTrace.Common.ps1')
        'Test-Worker.ps1'=(Join-Path $PSScriptRoot 'Test-Worker.ps1')
    }
    foreach($fileName in $runtimeFiles.Keys){
        $sourcePath=[IO.Path]::GetFullPath($runtimeFiles[$fileName])
        $destinationPath=[IO.Path]::GetFullPath((Join-Path $Destination $fileName))
        if(-not$sourcePath.Equals($destinationPath,[StringComparison]::OrdinalIgnoreCase)){
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
    }
    if($nodeConfig.Name-ieq$config.Controller){
        $controllerFiles=[ordered]@{
            'BrainTrace.ps1'=(Join-Path $sourceRoot 'BrainTrace.ps1')
            'Diagnose-DEV.cmd'=(Join-Path $repositoryRoot 'Diagnose-DEV.cmd')
        }
        foreach($fileName in $controllerFiles.Keys){
            $controllerSource=$controllerFiles[$fileName]
            $controllerDestination=Join-Path $Destination $fileName
            if(-not([IO.Path]::GetFullPath($controllerSource).Equals([IO.Path]::GetFullPath($controllerDestination),[StringComparison]::OrdinalIgnoreCase))){
                Copy-Item -LiteralPath $controllerSource -Destination $controllerDestination -Force
            }
        }
        $configDestination=Join-Path $Destination 'config'
        if(-not(Test-Path -LiteralPath $configDestination)){New-Item -ItemType Directory -Path $configDestination -Force|Out-Null}
        $environmentSource=if(Test-Path -LiteralPath $Environment -PathType Leaf){(Resolve-Path $Environment).Path}else{Join-Path (Join-Path $repositoryRoot 'config') ($Environment+'.json')}
        $environmentDestination=Join-Path $configDestination ($config.Environment+'.json')
        if(-not([IO.Path]::GetFullPath($environmentSource).Equals([IO.Path]::GetFullPath($environmentDestination),[StringComparison]::OrdinalIgnoreCase))){
            Copy-Item -LiteralPath $environmentSource -Destination $environmentDestination -Force
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
