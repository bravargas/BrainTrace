function New-BTRunId { '{0}-{1}' -f (Get-BTUtcNow).ToString('yyyyMMddTHHmmssZ'),[guid]::NewGuid().ToString().ToLowerInvariant() }

function New-BTRunWorkspace {
    param([string]$WorkspaceRoot,[string]$EnvironmentId,[string]$RunId)
    $root=Join-Path (Join-Path (Get-BTCanonicalPath $WorkspaceRoot) $EnvironmentId) $RunId
    foreach($folder in @('inventory','state','phases','commands','status','logs','staging','bundle')){New-Item -ItemType Directory -Path (Join-Path $root $folder)-Force|Out-Null}
    return $root
}

function Enter-BTEnvironmentLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$EnvironmentId,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][string]$LockPath,[Parameter(Mandatory=$true)][string]$ControllerNode,[Parameter(Mandatory=$true)][string]$CurrentNode)
    Assert-BT ($ControllerNode -ieq $CurrentNode) "Workflow must run on authoritative ControllerNode '$ControllerNode'." 'BrainTrace.Lock.NotAuthoritative'
    $safeName=($EnvironmentId -replace '[^A-Za-z0-9_.-]','_')
    $created=$false;$mutex=New-Object Threading.Mutex($true,"Local\BrainTrace-$safeName",[ref]$created)
    if(-not$created){$mutex.Dispose();throw (New-BTErrorRecord "Environment '$EnvironmentId' is already locked." 'BrainTrace.Lock.Active' ([Management.Automation.ErrorCategory]::ResourceBusy))}
    $lockDirectory=Split-Path -Parent $LockPath;if(-not(Test-Path -LiteralPath $lockDirectory)){New-Item -ItemType Directory -Path $lockDirectory -Force|Out-Null}
    $stale=$null
    if(Test-Path -LiteralPath $LockPath){$stale="$LockPath.stale.$((Get-BTUtcNow).ToString('yyyyMMddHHmmss')).json";[IO.File]::Move($LockPath,$stale)}
    $record=[pscustomobject]@{EnvironmentId=$EnvironmentId;RunId=$RunId;ControllerNode=$ControllerNode;ProcessId=$PID;AcquiredUtc=(Get-BTUtcNow).ToString('o')}
    Write-BTJsonAtomic $record $LockPath|Out-Null
    [pscustomobject]@{Mutex=$mutex;Path=$LockPath;StaleRecovered=$stale;RunId=$RunId}
}

function Exit-BTEnvironmentLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Lock)
    if(Test-Path -LiteralPath $Lock.Path){[IO.File]::Delete($Lock.Path)}
    try{$Lock.Mutex.ReleaseMutex()}catch{}finally{$Lock.Mutex.Dispose()}
}

function Get-BTControllerInputs {
    param([string]$EnvironmentPath,[string]$NodeConfigDirectory)
    $environment=Import-BTJsonFile $EnvironmentPath;[void](Test-BTEnvironmentConfiguration $environment)
    $configs=@{};$inventories=@{};$nodeRoots=@{}
    foreach($node in @($environment.Nodes)){
        $path=Join-Path $NodeConfigDirectory ($node.Name+'.json');$config=Import-BTJsonFile $path;[void](Test-BTNodeConfiguration $config)
        Assert-BT ($config.EnvironmentId -ieq $environment.EnvironmentId) "Node '$($node.Name)' EnvironmentId mismatch."
        Assert-BT ($config.Node.Name -ieq $node.Name) "Node config identity mismatch for '$($node.Name)'."
        $inventory=Get-BTNodeInventory $config
        Assert-BT ($inventory.ConfigHash -eq $node.ExpectedConfigHash) "ExpectedConfigHash mismatch for '$($node.Name)'." 'BrainTrace.ConfigHash.Mismatch'
        Assert-BT ($inventory.ConfigRevision -eq $node.ExpectedConfigRevision) "ConfigRevision mismatch for '$($node.Name)'."
        Assert-BT ((@($inventory.Roles|Sort-Object)-join '|') -eq (@($node.Roles|ForEach-Object{$_.ToUpperInvariant()}|Sort-Object)-join '|')) "Role inventory mismatch for '$($node.Name)'."
        $configs[$node.Name]=$config;$inventories[$node.Name]=$inventory;$nodeRoots[$node.Name]=$config.Node.WorkerRoot
    }
    $collectionPlan=Get-BTCollectionPlan $environment $inventories
    [pscustomobject]@{Environment=$environment;Configs=$configs;Inventories=$inventories;NodeRoots=$nodeRoots;CollectionPlan=$collectionPlan}
}

function New-BTRunPlan {
    param($Inputs,[string]$RunId,[string]$Workflow)
    $nodes=foreach($node in @($Inputs.Environment.Nodes)){
        $inventory=$Inputs.Inventories[$node.Name]
        $selectedRoute=@($Inputs.Environment.CommandRoutes|Where-Object Target -EQ $node.Name)[0]
        [pscustomobject][ordered]@{Name=$node.Name;Roles=$inventory.Roles;ConfigRevision=$inventory.ConfigRevision;ConfigHash=$inventory.ConfigHash;Components=$inventory.Components;LogSources=$inventory.LogSources;CommandRoute=@($selectedRoute.Hops)}
    }
    [pscustomobject][ordered]@{SchemaVersion=1;EnvironmentId=$Inputs.Environment.EnvironmentId;RunId=$RunId;Workflow=$Workflow;CreatedUtc=(Get-BTUtcNow).ToString('o');ControllerNode=$Inputs.Environment.ControllerNode;AggregatorNode=$Inputs.Environment.AggregatorNode;Nodes=$nodes;CollectionRoutes=$Inputs.CollectionPlan;BundleDestination=$Inputs.Environment.Collection.BundleDestination;Timeouts=$Inputs.Environment.TimeoutsSeconds}
}

function New-BTRoutedCommand {
    param($Environment,$Node,$RunId,$Action,$Phase,[hashtable]$Parameters=@{})
    $route=@($Environment.CommandRoutes|Where-Object Target -EQ $Node.Name)[0]
    $routeHops=@($route.Hops)
    New-BTCommand -EnvironmentId $Environment.EnvironmentId -RunId $RunId -SourceNode $Environment.ControllerNode -TargetNode $Node.Name -Action $Action -ConfigRevision $Node.ExpectedConfigRevision -ExpectedNodeConfigHash $Node.ExpectedConfigHash -PhaseName $(if($null-ne$Phase){$Phase.Name}else{''}) -PhaseEpoch $(if($null-ne$Phase){$Phase.Epoch}else{0}) -PhaseToken $(if($null-ne$Phase){$Phase.Token}else{''}) -Parameters $Parameters -Route ([pscustomobject]@{Hops=$routeHops;NextHopIndex=if($routeHops.Count-gt 1){1}else{0}})
}

function Invoke-BTDispatch {
    param($Command,$Inputs,[string]$SimulationRoot,[string]$RunWorkspace)
    Write-BTJsonAtomic $Command (Join-Path (Join-Path $RunWorkspace 'commands') ($Command.CommandId+'.json'))|Out-Null
    $relay=Invoke-BTRelaySimulation $Command $Inputs.Environment $Inputs.NodeRoots
    if($relay.Result-ne'SUCCESS'){return [pscustomobject]@{Result='FAILED';Command=$Command;Message=$relay.Message}}
    $nodeConfigPath=Join-Path (Split-Path -Parent (Split-Path -Parent $Inputs.Configs[$Command.TargetNode].Node.WorkerRoot)) 'not-used'
    # The authoritative config object is persisted in the scenario NodeConfigs directory; find it from the environment inputs.
    $tempConfig=Join-Path $RunWorkspace ("$($Command.TargetNode).worker-config.json")
    if(Test-Path -LiteralPath $tempConfig){[IO.File]::Delete($tempConfig)};Write-BTJsonAtomic $Inputs.Configs[$Command.TargetNode] $tempConfig|Out-Null
    $workerResults=@(Invoke-BTWorker -NodeRoot $Inputs.NodeRoots[$Command.TargetNode] -NodeConfigPath $tempConfig -SimulationRoot $SimulationRoot)
    $match=@($workerResults|Where-Object CommandId -EQ $Command.CommandId|Select-Object -Last 1)
    if($match.Count-eq0){return [pscustomobject]@{Result='TIMEOUT';Command=$Command;Message='No Worker result'}}
    $result=$match[0]
    if($relay.StatusReturn-eq'FAILED'){
        return [pscustomobject]@{Result='STATUS_LOST';CommandId=$Command.CommandId;Command=$Command;Message='Terminal status could not return over the configured route.';WorkerResult=$result}
    }
    if($null-ne$result.PSObject.Properties['Status']){Write-BTJsonAtomic $result.Status (Join-Path (Join-Path $RunWorkspace 'status') ($Command.CommandId+'.json'))|Out-Null}
    return $result
}

function Invoke-BTPhaseSet {
    param([string]$Action,$Phase,$Inputs,[string]$RunId,[string]$SimulationRoot,[string]$RunWorkspace)
    $results=@()
    foreach($node in @($Inputs.Environment.Nodes)){
        $command=New-BTRoutedCommand $Inputs.Environment $node $RunId $Action $Phase
        $results+=Invoke-BTDispatch $command $Inputs $SimulationRoot $RunWorkspace
    }
    return $results
}

function Invoke-BTInventoryPreflight {
    param($Inputs,[string]$RunId,[string]$SimulationRoot,[string]$RunWorkspace)
    foreach($node in @($Inputs.Environment.Nodes)){
        $command=New-BTRoutedCommand $Inputs.Environment $node $RunId 'INVENTORY' $null
        $result=Invoke-BTDispatch $command $Inputs $SimulationRoot $RunWorkspace
        Assert-BT ($result.Result-eq'SUCCESS') "INVENTORY failed for '$($node.Name)'."
        $inventory=$result.Status.Details.Inventory
        Assert-BT ($inventory.ConfigHash-eq$node.ExpectedConfigHash) "ExpectedConfigHash mismatch in INVENTORY for '$($node.Name)'." 'BrainTrace.ConfigHash.Mismatch'
        Assert-BT ((@($inventory.Roles|Sort-Object)-join'|')-eq(@($node.Roles|ForEach-Object{$_.ToUpperInvariant()}|Sort-Object)-join'|')) "Role inventory mismatch for '$($node.Name)'."
        $Inputs.Inventories[$node.Name]=$inventory
        Write-BTJsonAtomic $inventory (Join-Path (Join-Path $RunWorkspace 'inventory') ($node.Name+'.json'))|Out-Null
    }
    $Inputs.CollectionPlan=Get-BTCollectionPlan $Inputs.Environment $Inputs.Inventories
}

function Assert-BTBarrierSuccess {
    param([object[]]$Results,[string]$Name)
    $failed=@($Results|Where-Object Result -NotIn @('SUCCESS','DUPLICATE'))
    if($failed.Count){throw (New-BTErrorRecord "$Name barrier failed on $($failed.Count) command(s)." "BrainTrace.Barrier.$Name")}
}

function Get-BTDryRunReport {
    param($Inputs,$Plan,[string]$Workflow)
    [pscustomobject][ordered]@{
        Result='DRYRUN';Workflow=$Workflow;Environment=$Plan.EnvironmentId;RunId=$Plan.RunId;ControllerNode=$Plan.ControllerNode
        PhysicalNodes=@($Plan.Nodes|ForEach-Object{[pscustomobject]@{Name=$_.Name;Roles=$_.Roles;ConfigHash=$_.ConfigHash}})
        StopPlan=@($Plan.Nodes|ForEach-Object{$node=$_;@($_.Components|Sort-Object StopOrder|ForEach-Object{[pscustomobject]@{Node=$node.Name;Order=$_.StopOrder;Type=$_.Type;Resource=$_.ResourceName}})})
        StartPlan=@($Plan.Nodes|ForEach-Object{$node=$_;@($_.Components|Sort-Object StartOrder|ForEach-Object{[pscustomobject]@{Node=$node.Name;Order=$_.StartOrder;Type=$_.Type;Resource=$_.ResourceName}})})
        LogSources=@($Plan.Nodes|ForEach-Object{$node=$_;@($_.LogSources|ForEach-Object{[pscustomobject]@{Node=$node.Name;Id=$_.Id;CanonicalPath=$_.CanonicalPath;Cleanup=$_.CleanupEnabled;Collect=$_.CollectEnabled}})})
        CommandRoutes=@($Inputs.Environment.CommandRoutes);CollectionRoutes=@($Plan.CollectionRoutes);Aggregator=$Plan.AggregatorNode;BundleDestination=$Plan.BundleDestination;Timeouts=$Plan.Timeouts;Warnings=@('Phase 2 simulation/DryRun only; no Windows system adapter is installed.')
    }
}

function Invoke-BTPrepare {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$EnvironmentPath,[Parameter(Mandatory=$true)][string]$NodeConfigDirectory,[Parameter(Mandatory=$true)][string]$WorkspaceRoot,[Parameter(Mandatory=$true)][string]$ControllerNode,[switch]$DryRun,[Parameter(Mandatory=$true)][string]$SimulationRoot)
    $inputs=Get-BTControllerInputs $EnvironmentPath $NodeConfigDirectory
    Assert-BT ($ControllerNode -ieq $inputs.Environment.ControllerNode) 'Non-authoritative Controller rejected.' 'BrainTrace.Lock.NotAuthoritative'
    $runId=New-BTRunId;$workspace=New-BTRunWorkspace $WorkspaceRoot $inputs.Environment.EnvironmentId $runId
    $run=[pscustomobject]@{EnvironmentId=$inputs.Environment.EnvironmentId;RunId=$runId;Workflow='Prepare';State=if($DryRun){'DRYRUN'}else{'VALIDATING'};StartedUtc=(Get-BTUtcNow).ToString('o')};Write-BTJsonAtomic $run (Join-Path $workspace 'run.json')|Out-Null
    Write-BTLog (Join-Path $workspace 'logs\controller.jsonl') 'RunCreated' @{EnvironmentId=$inputs.Environment.EnvironmentId;RunId=$runId;Workflow='Prepare';DryRun=[bool]$DryRun}
    if($DryRun){$plan=New-BTRunPlan $inputs $runId 'Prepare';Write-BTJsonAtomic $plan (Join-Path $workspace 'plan.json')|Out-Null;foreach($inventoryName in $inputs.Inventories.Keys){Write-BTJsonAtomic $inputs.Inventories[$inventoryName] (Join-Path (Join-Path $workspace 'inventory') ($inventoryName+'.json'))|Out-Null};return Get-BTDryRunReport $inputs $plan 'Prepare'}
    $lockPath=Join-Path (Join-Path $WorkspaceRoot 'Locks') ($inputs.Environment.EnvironmentId+'.lock.json');$lock=$null
    try{
        $lock=Enter-BTEnvironmentLock $inputs.Environment.EnvironmentId $runId $lockPath $inputs.Environment.ControllerNode $ControllerNode
        Invoke-BTInventoryPreflight $inputs $runId $SimulationRoot $workspace
        $plan=New-BTRunPlan $inputs $runId 'Prepare';Write-BTJsonAtomic $plan (Join-Path $workspace 'plan.json')|Out-Null
        foreach($node in @($inputs.Environment.Nodes)){
            $command=New-BTRoutedCommand $inputs.Environment $node $runId 'STATE' $null
            $stateResult=Invoke-BTDispatch $command $inputs $SimulationRoot $workspace
            Assert-BT ($stateResult.Result-eq'SUCCESS') "STATE failed for '$($node.Name)'."
            Write-BTJsonAtomic $stateResult.Status.Details (Join-Path (Join-Path $workspace 'state') ($node.Name+'.json'))|Out-Null
        }
        $epoch=1;$stopPhase=[pscustomobject]@{Name='STOP';Epoch=$epoch;Token=[guid]::NewGuid().ToString()}
        Assert-BTBarrierSuccess (Invoke-BTPhaseSet 'PHASE_OPEN' $stopPhase $inputs $runId $SimulationRoot $workspace) 'STOP_OPEN'
        $stopResults=Invoke-BTPhaseSet 'STOP' $stopPhase $inputs $runId $SimulationRoot $workspace
        Write-BTLog (Join-Path $workspace 'logs\controller.jsonl') 'BarrierEvaluated' @{EnvironmentId=$inputs.Environment.EnvironmentId;RunId=$runId;Phase='STOP';Result=if(@($stopResults|Where-Object Result -NotIn @('SUCCESS','DUPLICATE')).Count){'FAILED'}else{'SUCCESS'}}
        $stopFailed=@($stopResults|Where-Object Result -NotIn @('SUCCESS','DUPLICATE'))
        $closeStop=Invoke-BTPhaseSet 'PHASE_CLOSE' $stopPhase $inputs $runId $SimulationRoot $workspace
        $closeFailed=@($closeStop|Where-Object Result -NotIn @('SUCCESS','DUPLICATE'))
        if($closeFailed.Count){return [pscustomobject]@{Result='RECOVERY_REQUIRED';RunId=$runId;Workspace=$workspace;Phase='STOP';Reason='Phase close acknowledgement missing'}}
        if($stopFailed.Count){
            $rollback=[pscustomobject]@{Name='ROLLBACK_START';Epoch=2;Token=[guid]::NewGuid().ToString()}
            Assert-BTBarrierSuccess (Invoke-BTPhaseSet 'PHASE_OPEN' $rollback $inputs $runId $SimulationRoot $workspace) 'ROLLBACK_OPEN'
            $rollbackResults=Invoke-BTPhaseSet 'START' $rollback $inputs $runId $SimulationRoot $workspace
            [void](Invoke-BTPhaseSet 'PHASE_CLOSE' $rollback $inputs $runId $SimulationRoot $workspace)
            return [pscustomobject]@{Result=if(@($rollbackResults|Where-Object Result -NotIn @('SUCCESS','DUPLICATE')).Count){'RECOVERY_REQUIRED'}else{'FAILED_ROLLED_BACK'};RunId=$runId;Workspace=$workspace;StopResults=$stopResults;Reconciliation=$closeStop;Rollback=$rollbackResults}
        }
        $cleanPhase=[pscustomobject]@{Name='CLEAN';Epoch=2;Token=[guid]::NewGuid().ToString()}
        Assert-BTBarrierSuccess (Invoke-BTPhaseSet 'PHASE_OPEN' $cleanPhase $inputs $runId $SimulationRoot $workspace) 'CLEAN_OPEN'
        $cleanResults=Invoke-BTPhaseSet 'CLEAN' $cleanPhase $inputs $runId $SimulationRoot $workspace
        $closeClean=Invoke-BTPhaseSet 'PHASE_CLOSE' $cleanPhase $inputs $runId $SimulationRoot $workspace
        $cleanFailure=@($cleanResults|Where-Object Result -NotIn @('SUCCESS','DUPLICATE')).Count -or @($closeClean|Where-Object{$_.Result-notin@('SUCCESS','DUPLICATE')-or($_.Status.Details.Disposition-eq'INDETERMINATE')}).Count
        $startPhase=[pscustomobject]@{Name=if($cleanFailure){'RECOVERY_START'}else{'START'};Epoch=3;Token=[guid]::NewGuid().ToString()}
        Assert-BTBarrierSuccess (Invoke-BTPhaseSet 'PHASE_OPEN' $startPhase $inputs $runId $SimulationRoot $workspace) 'START_OPEN'
        $startResults=Invoke-BTPhaseSet 'START' $startPhase $inputs $runId $SimulationRoot $workspace
        $closeStart=Invoke-BTPhaseSet 'PHASE_CLOSE' $startPhase $inputs $runId $SimulationRoot $workspace
        $failed=@($startResults+$closeStart|Where-Object Result -NotIn @('SUCCESS','DUPLICATE'))
        $result=if($failed.Count){'RECOVERY_REQUIRED'}elseif($cleanFailure){'FAILED_IRREVERSIBLE'}else{'SUCCESS'}
        [pscustomobject]@{Result=$result;RunId=$runId;Workspace=$workspace;Plan=$plan;Stop=$stopResults;Clean=$cleanResults;Start=$startResults}
    }finally{if($null-ne$lock){Exit-BTEnvironmentLock $lock}}
}

function Invoke-BTCollect {
    [CmdletBinding()]
    param([string]$EnvironmentPath,[string]$NodeConfigDirectory,[string]$WorkspaceRoot,[string]$ControllerNode,[string]$Name,[switch]$DryRun,[string]$SimulationRoot)
    $inputs=Get-BTControllerInputs $EnvironmentPath $NodeConfigDirectory
    Assert-BT ($ControllerNode -ieq $inputs.Environment.ControllerNode) 'Non-authoritative Controller rejected.' 'BrainTrace.Lock.NotAuthoritative'
    $runId=New-BTRunId;$workspace=New-BTRunWorkspace $WorkspaceRoot $inputs.Environment.EnvironmentId $runId
    if($DryRun){$plan=New-BTRunPlan $inputs $runId 'Collect';Write-BTJsonAtomic $plan (Join-Path $workspace 'plan.json')|Out-Null;return Get-BTDryRunReport $inputs $plan 'Collect'}
    $lock=$null
    try{
        $lock=Enter-BTEnvironmentLock $inputs.Environment.EnvironmentId $runId (Join-Path (Join-Path $WorkspaceRoot 'Locks') ($inputs.Environment.EnvironmentId+'.lock.json')) $inputs.Environment.ControllerNode $ControllerNode
        Invoke-BTInventoryPreflight $inputs $runId $SimulationRoot $workspace;$plan=New-BTRunPlan $inputs $runId 'Collect';Write-BTJsonAtomic $plan (Join-Path $workspace 'plan.json')|Out-Null
        $phase=[pscustomobject]@{Name='COLLECT';Epoch=1;Token=[guid]::NewGuid().ToString()};Assert-BTBarrierSuccess (Invoke-BTPhaseSet 'PHASE_OPEN' $phase $inputs $runId $SimulationRoot $workspace) 'COLLECT_OPEN'
        $results=@();foreach($route in $inputs.CollectionPlan){foreach($step in @($route.Steps|Sort-Object Order)){$node=@($inputs.Environment.Nodes|Where-Object Name -EQ $step.ExecutorNode)[0];$command=New-BTRoutedCommand $inputs.Environment $node $runId 'COLLECT' $phase @{CollectionRouteId=$route.Id;StepOrder=[int]$step.Order};$results+=Invoke-BTDispatch $command $inputs $SimulationRoot $workspace}}
        $close=Invoke-BTPhaseSet 'PHASE_CLOSE' $phase $inputs $runId $SimulationRoot $workspace
        $bundleName="$Name`_$((Get-BTUtcNow).ToString('yyyyMMddTHHmmssZ'))";$provider=New-BTSimulationCompressionProvider $SimulationRoot;$archive=Join-Path (Join-Path $workspace 'bundle') ($bundleName+'.zip');$compression=[pscustomobject]@{Preflight=& $provider.Preflight (Join-Path $workspace 'staging') $archive;Create=& $provider.Create (Join-Path $workspace 'staging') $archive;Validate=& $provider.Validate $archive}
        [pscustomobject]@{Result=if(@($results+$close|Where-Object Result -NotIn @('SUCCESS','DUPLICATE')).Count){'FAILED'}else{'SUCCESS'};RunId=$runId;Workspace=$workspace;Name=$Name;CollectionResults=$results;Compression=$compression;BundlePlan=[pscustomobject]@{Root=$bundleName;Provenance='nodes/<SourceNode>/<LogSourceId>';Aggregator=$inputs.Environment.AggregatorNode}}
    }finally{if($null-ne$lock){Exit-BTEnvironmentLock $lock}}
}
