[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,Position=0)][ValidateSet('Prepare','Collect')][string]$Command,
    [Parameter(Mandatory=$true)][string]$Environment,
    [string]$Name,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')

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
    while([datetime]::UtcNow-lt$deadline.ToUniversalTime()){if(Test-Path -LiteralPath $path){return Read-BrainTraceJson $path};Start-Sleep -Seconds ([int]$Config.PollSeconds)}
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

function Invoke-BrainTraceDirectCopy {
    param($Row,[string]$LogPath)
    if(-not(Test-Path -LiteralPath $Row.Destination)){New-Item -ItemType Directory -Path $Row.Destination -Force|Out-Null}
    & robocopy.exe $Row.Source $Row.Destination /E /R:1 /W:1 /NP /TEE ("/LOG+:$LogPath")|Out-Null
    $result=Get-BrainTraceRobocopyResult $LASTEXITCODE
    [pscustomobject]@{Node=$Row.SourceNode;Action='COLLECT';Success=$result.Success;Message="Executor $($Row.Executor): $($Row.Source) -> $($Row.Destination), exit $($result.ExitCode)"}
}

$config=Get-BrainTraceEnvironmentConfig $Environment $PSScriptRoot
$runId=[datetime]::Now.ToString('yyyyMMdd_HHmmss')
if($Command-eq'Prepare'){
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
