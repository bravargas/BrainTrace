[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('Diagnose','Test','Prepare','Collect')][string]$Command,
    [Parameter(Mandatory=$true)][string]$Environment,
    [string]$Name,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')
$configurationRoot=if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'config') -PathType Container){$PSScriptRoot}else{Split-Path -Parent $PSScriptRoot}

function New-BrainTraceCommand {
    param($Config,[string]$RunId,[string]$Target,[string]$Action,[string]$SourceNode,[string]$Name)
    [pscustomobject][ordered]@{
        RunId=$RunId;CommandId=[guid]::NewGuid().ToString('N');Environment=$Config.Environment;TargetNode=$Target;Action=$Action
        SourceNode=if($SourceNode){$SourceNode}else{$null};Name=if($Name){$Name}else{$null}
        CreatedUtc=[datetime]::UtcNow.ToString('o');ExpiresUtc=[datetime]::UtcNow.AddSeconds([int]$Config.TimeoutSeconds).ToString('o')
    }
}

function Get-BrainTraceDeliveryRoot {
    param($Config,$Node)
    if($Node.CommandAccess-eq'Direct'){return [string]$Node.CommandRoot}
    return [string](Get-BrainTraceNode $Config $Node.CommandVia).CommandRoot
}

function Send-BrainTraceCommand {
    param($Config,$Message)
    $target=Get-BrainTraceNode $Config $Message.TargetNode;$root=Get-BrainTraceDeliveryRoot $Config $target
    $path=Join-Path (Join-Path $root 'Commands') ("$($Message.RunId)_$($Message.CommandId)_$($Message.TargetNode).command.json")
    Write-BrainTraceJsonAtomic $Message $path
    [pscustomobject]@{Message=$Message;Root=$root}
}

function Wait-BrainTraceControllerStatus {
    param($Config,$Pending)
    $path=Join-Path (Join-Path $Pending.Root 'Status') ("$($Pending.Message.RunId)_$($Pending.Message.CommandId).status.json")
    $deadline=[datetime]$Pending.Message.ExpiresUtc
    $started=[datetime]::UtcNow
    $subject=if($Pending.Message.Action-eq'CHECK_COLLECTION'){"$($Pending.Message.TargetNode) reading $($Pending.Message.SourceNode)"}else{"$($Pending.Message.TargetNode) $($Pending.Message.Action)"}
    Write-Host ("Waiting for {0} "-f$subject) -NoNewline
    while([datetime]::UtcNow-lt$deadline.ToUniversalTime()){
        if(Test-Path -LiteralPath $path){
            $status=Read-BrainTraceJson $path
            $elapsed=[math]::Round(([datetime]::UtcNow-$started).TotalSeconds)
            $label=if($status.Success){'OK'}else{'FAILED'}
            Write-Host (" {0} ({1}s)"-f$label,$elapsed)
            return $status
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds ([int]$Config.PollSeconds)
    }
    Write-Host ' TIMEOUT'
    [pscustomobject]@{RunId=$Pending.Message.RunId;Node=$Pending.Message.TargetNode;Action=$Pending.Message.Action;Success=$false;Message='Timed out waiting for Worker status.';TimestampUtc=[datetime]::UtcNow.ToString('o')}
}

function Invoke-BrainTraceNodeAction {
    param($Config,[string]$RunId,[string]$Action)
    $pending=@();foreach($node in @($Config.Nodes)){$pending+=Send-BrainTraceCommand $Config (New-BrainTraceCommand $Config $RunId $node.Name $Action $null $null)}
    $results=@();foreach($item in $pending){$results+=Wait-BrainTraceControllerStatus $Config $item};return $results
}

function Show-BrainTraceResults {
    param([string]$Heading,[object[]]$Results)
    Write-Host '';Write-Host $Heading
    foreach($result in $Results){$label=if($result.Success){'OK'}else{'FAILED'};Write-Host ('{0,-24} {1,-7} {2}'-f $result.Node,$label,$result.Message)}
}

function Show-BrainTracePrepareDryRun {
    param($Config,[string]$RunId)
    Write-Host 'BrainTrace Prepare - DRY RUN';Write-Host "Environment: $($Config.Environment)";Write-Host "Run: $RunId";Write-Host "Controller: $($Config.Controller)";Write-Host "Aggregator: $($Config.Aggregator)";Write-Host ''
    foreach($node in @($Config.Nodes)){
        Write-Host $node.Name;Write-Host "  Role: $(@($node.Roles)-join', ')"
        foreach($pool in @($node.Components.AppPools)){Write-Host "  AppPool: $pool"}
        foreach($service in @($node.Components.Services)){Write-Host "  Service: $service"}
        if([bool]$node.Components.ManageIIS){Write-Host '  IIS: Yes'}
        foreach($log in @($node.Logs)){Write-Host "  Log: $($log.LocalPath)"}
        if($node.CommandAccess-eq'Via'){Write-Host "  Commands: via $($node.CommandVia)"}else{Write-Host '  Commands: direct'}
        Write-Host "  Collector: $($node.CollectBy)";Write-Host ''
    }
    Write-Host "STOP order: $(@($Config.StopOrder)-join' -> ')";Write-Host 'CLEAN: only after every STOP succeeds; local paths above come from trusted Worker configuration.'
    Write-Host "START order: $(@($Config.StartOrder)-join' -> ')";Write-Host 'No command files or system changes were made.'
}

function Get-BrainTraceCollectionRows {
    param($Config,[string]$RunId)
    $rows=@();foreach($sourceNode in @($Config.Nodes)){
        $executor=Get-BrainTraceNode $Config $sourceNode.CollectBy;$multiple=@($sourceNode.Logs).Count-gt1
        foreach($log in @($sourceNode.Logs)){
            $source=if($executor.Name-ieq$sourceNode.Name){$log.LocalPath}else{$log.UNCPath}
            $base=if($executor.Name-ieq$Config.Aggregator){$Config.StagingRoot}else{$Config.StagingRootUNC}
            $destination=Join-Path (Join-Path $base $RunId) $sourceNode.Name;if($multiple){$destination=Join-Path $destination $log.Id}
            $rows+=[pscustomobject]@{SourceNode=$sourceNode.Name;LogId=$log.Id;Executor=$executor.Name;Source=$source;Destination=$destination}
        }
    };return $rows
}

function Show-BrainTraceCollectDryRun {
    param($Config,[string]$RunId,[string]$Name)
    Write-Host 'BrainTrace Collect - DRY RUN';Write-Host "Environment: $($Config.Environment)";Write-Host "Run: $RunId";Write-Host "Name: $Name";Write-Host "Aggregator: $($Config.Aggregator)";Write-Host ''
    foreach($row in @(Get-BrainTraceCollectionRows $Config $RunId)){
        Write-Host "Executor: $($row.Executor)";Write-Host "  Source node: $($row.SourceNode)";Write-Host "  Read: $($row.Source)";Write-Host "  Write: $($row.Destination)";Write-Host ''
    }
    $zip=Join-Path $Config.StagingRoot ((ConvertTo-BrainTraceSafeName $Name)+'_'+$RunId+'.zip');Write-Host "ZIP on $($Config.Aggregator): $zip"
    if($null-eq$Config.BundleDestination){Write-Host 'Final ZIP destination: not configured'}else{Write-Host "Final ZIP destination: $($Config.BundleDestination.Path)"}
    Write-Host 'No command files, copies, or ZIP files were created.'
}

function Invoke-BrainTraceEnvironmentTest {
    param($Config,[string]$RunId)
    Write-Host "BrainTrace Test`nEnvironment: $($Config.Environment)`nRun: $RunId"
    $ping=@(Invoke-BrainTraceNodeAction $Config $RunId PING)
    Show-BrainTraceResults PING $ping
    if(@($ping|Where-Object{-not$_.Success}).Count){throw 'Worker or relay connectivity test failed.'}

    $pending=@()
    foreach($sourceNode in @($Config.Nodes)){
        $message=New-BrainTraceCommand $Config $RunId $sourceNode.CollectBy CHECK_COLLECTION $sourceNode.Name $null
        $pending+=Send-BrainTraceCommand $Config $message
    }
    $checks=@();foreach($item in $pending){$checks+=Wait-BrainTraceControllerStatus $Config $item}
    Show-BrainTraceResults COLLECTION_ACCESS $checks
    if(@($checks|Where-Object{-not$_.Success}).Count){throw 'One or more directional collection access checks failed.'}
    Write-Host "`nAll Workers, relay routes, source reads, and staging paths passed."
}

function Get-BrainTraceDiagnosticJson {
    param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{
        $content=if([IO.Path]::GetExtension($Path)-ieq'.jsonl'){Get-Content -LiteralPath $Path -Tail 1 -Encoding UTF8}else{Get-Content -LiteralPath $Path -Raw -Encoding UTF8}
        return $content|ConvertFrom-Json -ErrorAction Stop
    }catch{return $null}
}

function Get-BrainTraceTaskDiagnostic {
    param($Node,$ReportedTask)
    if($Node.Name-ieq$env:COMPUTERNAME){
        try{
            $task=Get-ScheduledTask -TaskName BrainTrace-Worker -ErrorAction Stop
            $info=Get-ScheduledTaskInfo -TaskName BrainTrace-Worker -ErrorAction Stop
            return [pscustomobject]@{State=[string]$task.State;LastResult=[string]$info.LastTaskResult;Detail="Last: $($info.LastRunTime); Next: $($info.NextRunTime)"}
        }catch{return [pscustomobject]@{State='MISSING';LastResult='-';Detail=$_.Exception.Message}}
    }
    if($null-eq$ReportedTask){return [pscustomobject]@{State='NO REPORT';LastResult='-';Detail='Remote Scheduler access is intentionally not attempted; no file heartbeat is available.'}}
    $state=[string](Get-BrainTraceProperty $ReportedTask TaskState 'UNKNOWN')
    $lastResult=Get-BrainTraceProperty $ReportedTask TaskLastResult $null
    $nextRun=Get-BrainTraceProperty $ReportedTask TaskNextRunUtc $null
    return [pscustomobject]@{State=$state;LastResult=if($null-eq$lastResult){'-'}else{[string]$lastResult};Detail=if($null-eq$nextRun){'Reported locally by Worker heartbeat.'}else{"Next: $nextRun"}}
}

function Invoke-BrainTraceEnvironmentDiagnosis {
    param($Config)
    Write-Host "BrainTrace Diagnose`nEnvironment: $($Config.Environment)`nController: $($Config.Controller)`n"
    Write-Host 'Read-only inspection: no command files are published and no Scheduled Tasks are changed.'
    $rows=@();$details=@()
    foreach($node in @($Config.Nodes)){
        $alias=if($null-ne$node.PSObject.Properties['Alias']){[string]$node.Alias}else{[string]$node.Name}
        $root=[string]$node.CommandRoot;$files='NO ACCESS';$heartbeat='-';$queue='-';$fatal='-';$reportedTask=$null
        try{
            if($node.CommandAccess-eq'Via'){
                $relay=Get-BrainTraceNode $Config ([string]$node.CommandVia)
                $mirrorPath=Join-Path (Join-Path (Join-Path ([string]$relay.CommandRoot) 'Status') 'Relays') ($node.Name+'.json')
                $mirror=Get-BrainTraceDiagnosticJson $mirrorPath
                if($null-eq$mirror){
                    $files='NO MIRROR';$details+="$alias relay mirror: no diagnostic snapshot from $($node.CommandVia)."
                }else{
                    $mirrorAge=[math]::Round(([datetime]::UtcNow-([datetime]$mirror.TimestampUtc).ToUniversalTime()).TotalMinutes,1)
                    $files=[string]$mirror.Files;$queue=if($null-ne$mirror.Queued){[string]$mirror.Queued}else{'-'}
                    if($null-ne$mirror.WorkerHeartbeatUtc){
                        $heartbeat=[string]([math]::Round(([datetime]::UtcNow-([datetime]$mirror.WorkerHeartbeatUtc).ToUniversalTime()).TotalMinutes,1))+' min'
                        $reportedTask=[pscustomobject]@{TaskState=(Get-BrainTraceProperty $mirror TaskState 'UNKNOWN');TaskLastResult=(Get-BrainTraceProperty $mirror TaskLastResult $null);TaskNextRunUtc=(Get-BrainTraceProperty $mirror TaskNextRunUtc $null)}
                    }else{$heartbeat='none'}
                    if(-not[string]::IsNullOrWhiteSpace([string]$mirror.Fatal)){$fatal='YES';$details+="$alias fatal: $([string]$mirror.Fatal)"}else{$fatal='none'}
                    if(-not[bool]$mirror.Reachable){$details+="$alias relay mirror ($mirrorAge min old): $([string]$mirror.Error)"}
                    elseif($mirrorAge-gt2){$details+="$alias relay mirror is stale: $mirrorAge minutes old."}
                }
            }elseif(Test-Path -LiteralPath $root -PathType Container){
                $required=@('Worker.ps1','BrainTrace.Common.ps1','NodeConfig.json')
                $missing=@($required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf)})
                $files=if($missing.Count){'MISSING'}else{'OK'}
                if($missing.Count){$details+="$alias files missing: $($missing-join', ')"}
                $commandPath=Join-Path $root 'Commands'
                $queue=if(Test-Path -LiteralPath $commandPath){[string]@(Get-ChildItem -LiteralPath $commandPath -File -Filter '*.command.json').Count}else{'folder missing'}
                $heartbeatRecord=Get-BrainTraceDiagnosticJson (Join-Path (Join-Path $root 'Status') 'Worker-Heartbeat.json')
                if($null-ne$heartbeatRecord){
                    $age=[math]::Round(([datetime]::UtcNow-([datetime]$heartbeatRecord.TimestampUtc).ToUniversalTime()).TotalMinutes,1)
                    $heartbeat="$age min"
                    $reportedTask=$heartbeatRecord
                }else{$heartbeat='none'}
                $fatalRecord=Get-BrainTraceDiagnosticJson (Join-Path (Join-Path $root 'Logs') 'Worker-Fatal.jsonl')
                if($null-ne$fatalRecord){$fatal='YES';$details+="$alias fatal: $([string]$fatalRecord.Error)"}else{$fatal='none'}
            }
        }catch{$details+="$alias filesystem: $($_.Exception.Message)"}
        $task=Get-BrainTraceTaskDiagnostic $node $reportedTask
        if($task.State-in@('MISSING','NO REPORT','NOT FOUND')){$details+="$alias task: $($task.Detail)"}
        $rows+=[pscustomobject][ordered]@{Node=$alias;Computer=$node.Name;Files=$files;Task=$task.State;LastResult=$task.LastResult;Heartbeat=$heartbeat;Queued=$queue;Fatal=$fatal}
    }
    Write-Host '';$rows|Format-Table -AutoSize
    if($details.Count){Write-Host 'DETAILS';$details|ForEach-Object{Write-Host "- $_"}}
    Write-Host "`nHeartbeat older than two minutes indicates that the one-minute Worker task may not be running."
}

function Invoke-BrainTraceDirectCopy {
    param($Row,[string]$LogPath)
    if(-not(Test-Path -LiteralPath $Row.Destination)){New-Item -ItemType Directory -Path $Row.Destination -Force|Out-Null}
    & robocopy.exe $Row.Source $Row.Destination /E /R:1 /W:1 /NP /TEE ("/LOG+:$LogPath")|Out-Null
    $result=Get-BrainTraceRobocopyResult $LASTEXITCODE
    [pscustomobject]@{Node=$Row.SourceNode;Action='COLLECT';Success=$result.Success;Message="Executor $($Row.Executor): $($Row.Source) -> $($Row.Destination), exit $($result.ExitCode)"}
}

$config=Get-BrainTraceEnvironmentConfig $Environment $configurationRoot
$runId=[datetime]::Now.ToString('yyyyMMdd_HHmmss')
if($Command-eq'Diagnose'){
    Invoke-BrainTraceEnvironmentDiagnosis $config
}elseif($Command-eq'Test'){
    if($DryRun){Write-Host "BrainTrace Test - DRY RUN`nWould PING $(@($config.Nodes).Count) Workers and check $(@($config.Nodes).Count) configured collection sources.`nNo command files were published.";return}
    Invoke-BrainTraceEnvironmentTest $config $runId
}elseif($Command-eq'Prepare'){
    if($DryRun){Show-BrainTracePrepareDryRun $config $runId;return}
    Write-Host "BrainTrace Prepare`nEnvironment: $($config.Environment)`nRun: $runId"
    $policy=Invoke-BrainTracePreparePolicy { param($action) Invoke-BrainTraceNodeAction $config $runId $action }
    Show-BrainTraceResults STOP @($policy.Stop)
    if(-not$policy.CleanExecuted){
        Write-Host "`nCLEAN NOT EXECUTED.`nAttempting START on all nodes..."
        Show-BrainTraceResults START @($policy.Start)
        throw 'Prepare failed during STOP. Review Worker results.'
    }
    Show-BrainTraceResults CLEAN @($policy.Clean);Show-BrainTraceResults START @($policy.Start)
    if(-not$policy.Success){throw 'Prepare completed with failures. Review Worker results.'}
    Write-Host "`nEnvironment ready."
}else{
    if([string]::IsNullOrWhiteSpace($Name)){throw 'Collect requires -Name.'};$safeName=ConvertTo-BrainTraceSafeName $Name
    if($DryRun){Show-BrainTraceCollectDryRun $config $runId $safeName;return}
    Write-Host "BrainTrace Collect`nEnvironment: $($config.Environment)`nRun: $runId"
    $rows=@(Get-BrainTraceCollectionRows $config $runId);$results=@();$controllerLog=Join-Path $config.WorkerRoot ('Logs\'+$runId+'.log')
    foreach($group in @($rows|Group-Object Executor)){
        if($group.Name-ieq$config.Controller){foreach($row in $group.Group){$results+=Invoke-BrainTraceDirectCopy $row $controllerLog}}
        else{
            foreach($source in @($group.Group|Select-Object -ExpandProperty SourceNode -Unique)){
                $message=New-BrainTraceCommand $config $runId $group.Name COLLECT $source $null
                $results+=Wait-BrainTraceControllerStatus $config (Send-BrainTraceCommand $config $message)
            }
        }
    }
    Show-BrainTraceResults COLLECT $results
    if(@($results|Where-Object{-not$_.Success}).Count){throw 'Collection failed; ZIP was not requested.'}
    $bundle=New-BrainTraceCommand $config $runId $config.Aggregator BUNDLE $null $safeName
    $bundleResult=Wait-BrainTraceControllerStatus $config (Send-BrainTraceCommand $config $bundle)
    Show-BrainTraceResults BUNDLE @($bundleResult);if(-not$bundleResult.Success){throw 'Bundle creation failed.'}
}
