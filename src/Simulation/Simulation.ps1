function New-BTSimulationNodeConfig {
    param([string]$EnvironmentId, [string]$Name, [string[]]$Roles, [string]$ScenarioRoot, [switch]$SharedFullLogs)
    $components = @()
    if ($Roles -contains 'APP') { $components += [pscustomobject]@{ Id='MobilitiService'; Type='WindowsService'; ResourceName='Mobiliti'; StopOrder=200; StartOrder=200; RequiredEndState='Running' } }
    if ($Roles -contains 'APP' -or $Roles -contains 'WEB') { $components += [pscustomobject]@{ Id='IIS'; Type='IIS'; ResourceName='IIS'; StopOrder=300; StartOrder=100; RequiredEndState='Running' } }
    if ($Roles -contains 'TP') { $components += [pscustomobject]@{ Id='StandardBankingServicePool'; Type='IISAppPool'; ResourceName='StandardBankingService'; StopOrder=100; StartOrder=300; RequiredEndState='Running' } }
    $logRoot = Join-Path $ScenarioRoot (Join-Path 'ApplicationLogs' $Name)
    $sources = @()
    if ($SharedFullLogs -and $Roles.Count -gt 1) {
        $sources += [pscustomobject]@{ Id='SharedLogs'; Path=(Join-Path $logRoot 'SharedLogs'); Workloads=$Roles; CleanupEnabled=$true; CollectEnabled=$true; SafetyMarker='.braintrace-log-root' }
    } else {
        if ($Roles -contains 'APP' -or $Roles -contains 'WEB') { $sources += [pscustomobject]@{ Id='MobilitiLogs'; Path=(Join-Path $logRoot 'MobilitiLogs'); Workloads=@($Roles | Where-Object { $_ -in @('APP','WEB') }); CleanupEnabled=$true; CollectEnabled=$true; SafetyMarker='.braintrace-log-root' } }
        if ($Roles -contains 'TP') { $sources += [pscustomobject]@{ Id='SBILogs'; Path=(Join-Path $logRoot 'SBILogs'); Workloads=@('TP'); CleanupEnabled=$true; CollectEnabled=$true; SafetyMarker='.braintrace-log-root' } }
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1; EnvironmentId=$EnvironmentId; ConfigRevision="$($EnvironmentId.ToLowerInvariant())-$($Name.ToLowerInvariant())-1"; CanonicalHashProfile='BrainTraceCanonicalNodeV1'
        Node=[pscustomobject][ordered]@{ Name=$Name; MachineNames=@($Name); Roles=$Roles; WorkerRoot=(Join-Path $ScenarioRoot (Join-Path 'Nodes' $Name)); AllowedCleanupRoots=@($logRoot); Components=$components; LogSources=$sources; CollectionAssignments=@() }
    }
}

function New-BTSimulationScenario {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('QA','PROD_6TP','PDX_AIO','FULL_AIO_SEPARATE_LOGS','FULL_AIO_SHARED_LOGS')][string]$Name, [Parameter(Mandatory = $true)][string]$RootPath)
    $scenarioRoot = Join-Path (Get-BTCanonicalPath $RootPath) $Name
    if (-not (Test-Path -LiteralPath $scenarioRoot)) { New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null }
    $spec = @(switch ($Name) {
        'QA' { [pscustomobject]@{Name='TP1';Roles=@('TP')};[pscustomobject]@{Name='TP2';Roles=@('TP')};[pscustomobject]@{Name='APP1';Roles=@('APP')};[pscustomobject]@{Name='APP2';Roles=@('APP')};[pscustomobject]@{Name='WEB1';Roles=@('WEB')};[pscustomobject]@{Name='WEB2';Roles=@('WEB')} }
        'PROD_6TP' { 1..6|ForEach-Object{[pscustomobject]@{Name="TP$_";Roles=@('TP')}} }
        'PDX_AIO' { [pscustomobject]@{Name='TP1';Roles=@('TP')};[pscustomobject]@{Name='AIO1';Roles=@('APP','WEB')} }
        'FULL_AIO_SEPARATE_LOGS' { [pscustomobject]@{Name='FULLAIO1';Roles=@('APP','WEB','TP')} }
        'FULL_AIO_SHARED_LOGS' { [pscustomobject]@{Name='FULLAIO1';Roles=@('APP','WEB','TP')} }
    })
    $nodeConfigDirectory = Join-Path $scenarioRoot 'NodeConfigs'
    New-Item -ItemType Directory -Path $nodeConfigDirectory -Force | Out-Null
    $nodeConfigs = @{}
    foreach ($item in $spec) {
        $nodeName = $item.Name; $roles = @($item.Roles)
        $config = New-BTSimulationNodeConfig -EnvironmentId $Name -Name $nodeName -Roles $roles -ScenarioRoot $scenarioRoot -SharedFullLogs:($Name -eq 'FULL_AIO_SHARED_LOGS')
        $nodeConfigs[$nodeName] = $config
        $nodeRoot = $config.Node.WorkerRoot; Initialize-BTQueue $nodeRoot
        foreach ($source in @($config.Node.LogSources)) {
            New-Item -ItemType Directory -Path $source.Path -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $source.Path $source.SafetyMarker), 'simulation-only')
            if (-not (Test-Path -LiteralPath (Join-Path $source.Path 'sample.log'))) { [IO.File]::WriteAllText((Join-Path $source.Path 'sample.log'), "simulated $nodeName $($source.Id)") }
        }
        $state = [ordered]@{}
        foreach ($component in @($config.Node.Components)) { $state[(Get-BTComponentKey $component)] = 'Running' }
        Write-BTJsonAtomic $state (Join-Path $nodeRoot 'State.json') | Out-Null
    }
    $controller = [string]$spec[0].Name
    $aggregator = if ($Name -eq 'QA') { 'APP1' } elseif ($Name -eq 'PDX_AIO') { 'AIO1' } else { $controller }
    $nodes = foreach ($item in $spec) {
        $nodeName = [string]$item.Name; $config = $nodeConfigs[$nodeName]
        [pscustomobject]@{ Name=$nodeName; Roles=@($config.Node.Roles); Inbox=(Join-Path $config.Node.WorkerRoot 'Inbox'); ExpectedConfigRevision=$config.ConfigRevision; ExpectedConfigHash=(Get-BTNodeConfigHash $config) }
    }
    $commandRoutes = foreach ($item in $spec) {
        $target = [string]$item.Name
        $hops = if ($Name -eq 'QA' -and $target -in @('WEB1','WEB2')) { @($controller,'APP1',$target) } elseif ($target -eq $controller) { @($controller) } else { @($controller,$target) }
        [pscustomobject]@{ Target=$target; Hops=$hops }
    }
    $collectionRoutes = @()
    foreach ($item in $spec) {
        $sourceNode = [string]$item.Name
        foreach ($source in @($nodeConfigs[$sourceNode].Node.LogSources | Where-Object CollectEnabled)) {
            $collector = if ($Name -eq 'QA' -and $sourceNode -in @('WEB1','WEB2')) { 'APP1' } else { $controller }
            $routeId = "$sourceNode-$($source.Id)-to-$aggregator"
            $readPath = $source.Path
            $writePath = Join-Path $scenarioRoot (Join-Path 'StagingTemplate' (Join-Path 'nodes' (Join-Path $sourceNode $source.Id)))
            $steps=@()
            if($Name-eq'PDX_AIO' -and $sourceNode-eq'TP1'){
                $intermediate=Join-Path $scenarioRoot 'CollectorStaging\{RunId}\TP1\SBILogs'
                $steps+= [pscustomobject]@{Order=1;ExecutorNode='TP1';Read=[pscustomobject]@{Node=$sourceNode;Kind='LogSource';Ref=$source.Id;AccessPath=$readPath};Write=[pscustomobject]@{Node='TP1';Kind='CollectorStaging';PathTemplate=$intermediate}}
                $steps+= [pscustomobject]@{Order=2;ExecutorNode='TP1';Read=[pscustomobject]@{Node='TP1';Kind='CollectorStaging';Ref=$source.Id;AccessPath=$intermediate};Write=[pscustomobject]@{Node=$aggregator;Kind='AggregatorStaging';PathTemplate=$writePath}}
            }else{
                $steps+= [pscustomobject]@{ Order=1; ExecutorNode=$collector; Read=[pscustomobject]@{Node=$sourceNode;Kind='LogSource';Ref=$source.Id;AccessPath=$readPath}; Write=[pscustomobject]@{Node=$aggregator;Kind='AggregatorStaging';PathTemplate=$writePath} }
            }
            $collectionRoutes += [pscustomobject]@{ Id=$routeId;SourceNode=$sourceNode;LogSourceId=$source.Id;CollectorNode=$collector;AggregatorNode=$aggregator;Steps=$steps }
            foreach($step in $steps){$nodeConfigs[$step.ExecutorNode].Node.CollectionAssignments += [pscustomobject]@{ RouteId=$routeId;StepOrder=$step.Order;ExecutorNode=$step.ExecutorNode;Read=$step.Read;Write=$step.Write }}
        }
    }
    # Collection assignments are hash-relevant, so persist configs and expected hashes only after route construction.
    foreach ($item in $spec) {
        $nodeName = [string]$item.Name; $config = $nodeConfigs[$nodeName]
        $nodeEntry = $nodes | Where-Object Name -EQ $nodeName
        $nodeEntry.ExpectedConfigHash = Get-BTNodeConfigHash $config
        Write-BTJsonAtomic $config (Join-Path $nodeConfigDirectory ($nodeName + '.json')) | Out-Null
    }
    $environment = [pscustomobject][ordered]@{
        SchemaVersion=1;EnvironmentId=$Name;DisplayName="$Name simulation";ControllerNode=$controller;AggregatorNode=$aggregator;EnvironmentConfigRevision='simulation-1'
        WorkspaceRoot=(Join-Path $scenarioRoot 'Runs');Lock=[pscustomobject]@{Mode='ControllerLocal';Path=(Join-Path $scenarioRoot 'Locks\environment.lock.json')}
        TimeoutsSeconds=[pscustomobject]@{Inventory=5;State=5;Stop=5;Clean=5;Start=5;PhaseClose=5;Relay=5;Collect=30;Compress=30;PublishBundle=30;PollInterval=1}
        Nodes=$nodes;CommandRoutes=$commandRoutes
        Collection=[pscustomobject]@{CopyProvider='Simulation';RobocopyRetryCount=0;RobocopyWaitSeconds=0;ChangingFilePolicy='Fail';CompressionProvider='Simulation';Routes=$collectionRoutes;BundleDestination=[pscustomobject]@{Node=$aggregator;Path=(Join-Path $scenarioRoot 'Bundles');VerifySha256=$true}}
    }
    $environmentPath = Join-Path $scenarioRoot 'environment.json'
    if (Test-Path -LiteralPath $environmentPath) { [IO.File]::Delete($environmentPath) }
    Write-BTJsonAtomic $environment $environmentPath | Out-Null
    [pscustomobject]@{ Name=$Name;RootPath=$scenarioRoot;EnvironmentPath=$environmentPath;NodeConfigDirectory=$nodeConfigDirectory;Environment=$environment }
}

function Get-BTSimulationFault {
    param([string]$NodeRoot, [string]$Action)
    $path = Join-Path $NodeRoot 'Faults.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $faults = Import-BTJsonFile $path
    $property = $faults.PSObject.Properties[$Action]
    if ($null -eq $property) { return $null }
    return $property.Value
}
