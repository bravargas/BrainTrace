[CmdletBinding()]
param(
    [string]$Root=$PSScriptRoot,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')

function Get-BrainTraceComponentSnapshot {
    param($Node)
    $snapshot=[ordered]@{}
    foreach($serviceName in @($Node.Components.Services)){
        $service=Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $snapshot["Service:$serviceName"]=if($null-ne$service){[string]$service.Status}else{'NotFound'}
    }
    if([bool]$Node.Components.ManageIIS){
        $iis=Get-Service -Name W3SVC -ErrorAction SilentlyContinue
        $snapshot['IIS:W3SVC']=if($null-ne$iis){[string]$iis.Status}else{'NotFound'}
    }
    if(@($Node.Components.AppPools).Count){
        $webModule=Get-Module -ListAvailable WebAdministration|Select-Object -First 1
        if($null-ne$webModule){
            Import-Module WebAdministration -ErrorAction Stop
            foreach($pool in @($Node.Components.AppPools)){
                try{$snapshot["AppPool:$pool"]=[string](Get-WebAppPoolState -Name $pool -ErrorAction Stop).Value}catch{$snapshot["AppPool:$pool"]='NotFound'}
            }
        }else{foreach($pool in @($Node.Components.AppPools)){$snapshot["AppPool:$pool"]='WebAdministrationUnavailable'}}
    }
    return [pscustomobject]$snapshot
}

$configPath=Join-Path $Root 'NodeConfig.json'
$workerPath=Join-Path $Root 'Worker.ps1'
if(-not(Test-Path -LiteralPath $configPath)){throw "Installed NodeConfig.json was not found under '$Root'."}
if(-not(Test-Path -LiteralPath $workerPath)){throw "Worker.ps1 was not found under '$Root'."}

$installed=Read-BrainTraceJson $configPath
$config=$installed.EnvironmentConfig
$node=Get-BrainTraceNode $config ([string]$installed.LocalNode)
if($null-eq$node){throw "Installed LocalNode '$($installed.LocalNode)' is invalid."}

$testRoot=Join-Path $env:TEMP ('BrainTrace-SmokeTest-'+[guid]::NewGuid().ToString('N'))
$runId='smoke_'+[datetime]::Now.ToString('yyyyMMdd_HHmmss')
$commandId=[guid]::NewGuid().ToString('N')

try{
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'Commands') -Force|Out-Null
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $testRoot 'NodeConfig.json')
    $command=[ordered]@{
        RunId=$runId;CommandId=$commandId;Environment=$config.Environment;TargetNode=$node.Name;Action='STOP'
        SourceNode=$null;Name=$null;CreatedUtc=[datetime]::UtcNow.ToString('o');ExpiresUtc=[datetime]::UtcNow.AddMinutes(5).ToString('o')
    }
    $temporary=Join-Path (Join-Path $testRoot 'Commands') ($runId+'.tmp')
    $commandPath=Join-Path (Join-Path $testRoot 'Commands') ("$runId`_$commandId.command.json")
    [IO.File]::WriteAllText($temporary,($command|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temporary,$commandPath)

    $before=Get-BrainTraceComponentSnapshot $node
    $workerResult=@(& $workerPath -Root $testRoot -ConfigPath (Join-Path $testRoot 'NodeConfig.json') -DryRun)
    $after=Get-BrainTraceComponentSnapshot $node
    $statusPath=Join-Path (Join-Path $testRoot 'Status') ("$runId`_$commandId.status.json")
    if(-not(Test-Path -LiteralPath $statusPath)){throw 'The Worker did not publish a smoke-test status.'}
    $status=Read-BrainTraceJson $statusPath
    if(-not[bool]$status.Success){throw "Worker smoke test failed: $($status.Message)"}
    $beforeJson=$before|ConvertTo-Json -Compress;$afterJson=$after|ConvertTo-Json -Compress
    if($beforeJson-ne$afterJson){throw "A component state changed during DryRun. Before=$beforeJson After=$afterJson"}
    $archived=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Archive') -File -Filter '*.command.json').Count
    if($archived-ne1){throw "Expected one archived smoke-test command; found $archived."}

    $task=Get-ScheduledTask -TaskName BrainTrace-Worker -ErrorAction SilentlyContinue
    $taskInfo=if($null-ne$task){Get-ScheduledTaskInfo -TaskName BrainTrace-Worker}else{$null}
    [pscustomobject][ordered]@{
        Success=$true;Node=$node.Name;Environment=$config.Environment;DryRunMessage=$status.Message
        ComponentsBefore=$before;ComponentsAfter=$after;ScheduledTask=if($null-ne$task){[string]$task.State}else{'NotInstalled'}
        LastTaskResult=if($null-ne$taskInfo){$taskInfo.LastTaskResult}else{$null};Artifacts=if($KeepArtifacts){$testRoot}else{'Removed'}
    }
}finally{
    if(-not$KeepArtifacts-and(Test-Path -LiteralPath $testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
