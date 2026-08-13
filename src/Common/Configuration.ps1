function Get-BTCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-BT (-not [string]::IsNullOrWhiteSpace($Path)) 'Path cannot be empty.' 'BrainTrace.Path.Empty'
    Assert-BT ($Path.IndexOfAny([char[]]'*?') -lt 0) "Wildcards are not allowed in path '$Path'." 'BrainTrace.Path.Wildcard'
    $expanded = [Environment]::ExpandEnvironmentVariables($Path).Trim()
    Assert-BT ($expanded -notmatch '%[^%]+%') "Unresolved environment variable in '$Path'." 'BrainTrace.Path.EnvironmentVariable'
    try { $full = [IO.Path]::GetFullPath($expanded) } catch { throw "Invalid path '$Path': $($_.Exception.Message)" }
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char]'\', [char]'/') }
    return $full.Normalize([Text.NormalizationForm]::FormC)
}

function Test-BTPathStrictlyWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $canonicalPath = Get-BTCanonicalPath $Path
    $canonicalRoot = Get-BTCanonicalPath $Root
    if ($canonicalPath.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $rootPrefix = $canonicalRoot.TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
    return $canonicalPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-BTNoReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    Assert-BT (Test-BTPathStrictlyWithinRoot $Path $Root) "Path '$Path' is not strictly contained by '$Root'." 'BrainTrace.Simulation.RootGuard'
    $canonicalRoot = Get-BTCanonicalPath $Root
    $cursor = Get-BTCanonicalPath $Path
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-BT (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse point is not allowed in simulation path '$cursor'." 'BrainTrace.Simulation.ReparsePoint'
        }
        if ($cursor.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $cursor
        Assert-BT (-not [string]::IsNullOrWhiteSpace($parent) -and $parent -ne $cursor) "Cannot prove containment for '$Path'." 'BrainTrace.Simulation.RootGuard'
        $cursor = Get-BTCanonicalPath $parent
    }
}

function Get-BTComponentKey {
    param([Parameter(Mandatory = $true)]$Component)
    return ('{0}|{1}' -f ([string]$Component.Type).Trim().ToUpperInvariant(), ([string]$Component.ResourceName).Trim().ToUpperInvariant())
}

function Get-BTLogSourceKey {
    param([Parameter(Mandatory = $true)]$LogSource)
    return (Get-BTCanonicalPath $LogSource.Path).ToUpperInvariant()
}

function Assert-BTUnique {
    param([object[]]$Items, [scriptblock]$Key, [string]$Label)
    $seen = @{}
    foreach ($item in @($Items)) {
        $value = & $Key $item
        $normalized = ([string]$value).ToUpperInvariant()
        if ($seen.ContainsKey($normalized)) { throw "Duplicate $Label '$value'." }
        $seen[$normalized] = $true
    }
}

function Sort-BTOrdinalStrings {
    param([object[]]$Values)
    [string[]]$sorted=@($Values|ForEach-Object{[string]$_})
    [Array]::Sort($sorted,[StringComparer]::Ordinal)
    return $sorted
}

function Sort-BTOrdinalByKey {
    param([object[]]$Items,[scriptblock]$Key)
    $map=New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($item in @($Items)){$map.Add([string](& $Key $item),$item)}
    return @($map.Values)
}

function Test-BTNodeConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Configuration, [switch]$PassThru)
    Assert-BT ($Configuration.SchemaVersion -eq 1) 'Node SchemaVersion must be 1.'
    Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$Configuration.EnvironmentId)) 'Node EnvironmentId is required.'
    Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$Configuration.ConfigRevision)) 'ConfigRevision is required.'
    Assert-BT ($null -ne $Configuration.Node) 'Node object is required.'
    Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$Configuration.Node.Name)) 'Node.Name is required.'
    $allowedRoles = @('TP', 'APP', 'WEB')
    Assert-BT (@($Configuration.Node.Roles).Count -gt 0) 'At least one role is required.'
    foreach ($role in @($Configuration.Node.Roles)) { Assert-BT ($allowedRoles -contains ([string]$role).ToUpperInvariant()) "Unknown role '$role'." }
    Assert-BTUnique @($Configuration.Node.Roles) { param($x) [string]$x } 'role'

    $components = @($Configuration.Node.Components)
    $allowedTypes = @('WindowsService', 'IIS', 'IISAppPool')
    Assert-BTUnique $components { param($x) [string]$x.Id } 'component Id'
    Assert-BTUnique $components { param($x) Get-BTComponentKey $x } 'physical component'
    foreach ($component in $components) {
        Assert-BT ($allowedTypes -contains [string]$component.Type) "Unknown component type '$($component.Type)'."
        Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$component.ResourceName)) 'Component ResourceName is required.'
        Assert-BT ($component.StopOrder -is [int] -or $component.StopOrder -is [long]) "StopOrder must be an integer for '$($component.Id)'."
        Assert-BT ($component.StartOrder -is [int] -or $component.StartOrder -is [long]) "StartOrder must be an integer for '$($component.Id)'."
    }

    $sources = @($Configuration.Node.LogSources)
    Assert-BTUnique $sources { param($x) [string]$x.Id } 'LogSource Id'
    Assert-BTUnique $sources { param($x) Get-BTLogSourceKey $x } 'canonical LogSource path'
    foreach ($source in $sources) {
        $sourcePath=Get-BTCanonicalPath $source.Path
        Assert-BT (-not $sourcePath.Equals([IO.Path]::GetPathRoot($sourcePath),[StringComparison]::OrdinalIgnoreCase)) "LogSource '$($source.Id)' cannot be a drive or share root." 'BrainTrace.Path.Root'
        Assert-BT ($source.CleanupEnabled -is [bool]) "CleanupEnabled must be Boolean for '$($source.Id)'."
        Assert-BT ($source.CollectEnabled -is [bool]) "CollectEnabled must be Boolean for '$($source.Id)'."
    }
    foreach ($root in @($Configuration.Node.AllowedCleanupRoots)) {
        $canonicalRoot=Get-BTCanonicalPath $root
        Assert-BT (-not $canonicalRoot.Equals([IO.Path]::GetPathRoot($canonicalRoot),[StringComparison]::OrdinalIgnoreCase)) "AllowedCleanupRoot cannot be a drive or share root." 'BrainTrace.Path.Root'
    }

    $assignments = @($Configuration.Node.CollectionAssignments)
    Assert-BTUnique $assignments { param($x) '{0}|{1}' -f $x.RouteId, $x.StepOrder } 'CollectionAssignment'
    foreach ($assignment in $assignments) {
        Assert-BT ($assignment.ExecutorNode -ieq $Configuration.Node.Name) "CollectionAssignment '$($assignment.RouteId)' belongs to another ExecutorNode."
        Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$assignment.Read.AccessPath)) 'CollectionAssignment read AccessPath is required.'
        Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$assignment.Write.PathTemplate)) 'CollectionAssignment write PathTemplate is required.'
    }
    if ($PassThru) { return $Configuration }
    return $true
}

function Test-BTEnvironmentConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Configuration, [switch]$PassThru)
    Assert-BT ($Configuration.SchemaVersion -eq 1) 'Environment SchemaVersion must be 1.'
    Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$Configuration.EnvironmentId)) 'EnvironmentId is required.'
    $nodes = @($Configuration.Nodes)
    Assert-BT ($nodes.Count -gt 0) 'At least one physical node is required.'
    Assert-BTUnique $nodes { param($x) [string]$x.Name } 'physical node'
    $names = @($nodes | ForEach-Object { [string]$_.Name })
    Assert-BT ($names -icontains [string]$Configuration.ControllerNode) 'ControllerNode must reference a physical node.'
    Assert-BT ($names -icontains [string]$Configuration.AggregatorNode) 'AggregatorNode must reference a physical node.'
    foreach ($node in $nodes) {
        Assert-BT ([string]$node.ExpectedConfigHash -match '^[0-9a-fA-F]{64}$') "ExpectedConfigHash is invalid for '$($node.Name)'."
        foreach ($role in @($node.Roles)) { Assert-BT (@('TP','APP','WEB') -contains ([string]$role).ToUpperInvariant()) "Unknown role '$role'." }
    }
    Assert-BT ([string]$Configuration.Lock.Mode -eq 'ControllerLocal') 'Phase 2 supports only ControllerLocal environment locks.'
    Assert-BT (-not [string]::IsNullOrWhiteSpace([string]$Configuration.Collection.BundleDestination.Path)) 'BundleDestination.Path is required.'
    Assert-BT ($names -icontains [string]$Configuration.Collection.BundleDestination.Node) 'BundleDestination.Node must be configured.'

    $routes = @($Configuration.CommandRoutes)
    Assert-BTUnique $routes { param($x) [string]$x.Target } 'command route target'
    foreach ($nodeName in $names) { Assert-BT ($null -ne ($routes | Where-Object { $_.Target -ieq $nodeName })) "CommandRoute missing for '$nodeName'." }
    foreach ($route in $routes) {
        $hops = @($route.Hops)
        Assert-BT ($hops.Count -gt 0 -and $hops[0] -ieq $Configuration.ControllerNode -and $hops[-1] -ieq $route.Target) "Invalid CommandRoute for '$($route.Target)'."
        Assert-BTUnique $hops { param($x) [string]$x } 'command route hop'
        foreach ($hop in $hops) { Assert-BT ($names -icontains [string]$hop) "Unknown command route hop '$hop'." }
    }

    $collectionRoutes = @($Configuration.Collection.Routes)
    Assert-BTUnique $collectionRoutes { param($x) [string]$x.Id } 'collection route Id'
    Assert-BTUnique $collectionRoutes { param($x) '{0}|{1}' -f $x.SourceNode, $x.LogSourceId } 'collection source'
    foreach ($route in $collectionRoutes) {
        foreach ($field in @('SourceNode','CollectorNode','AggregatorNode')) { Assert-BT ($names -icontains [string]$route.$field) "Unknown $field '$($route.$field)' in collection route '$($route.Id)'." }
        Assert-BT ($route.AggregatorNode -ieq $Configuration.AggregatorNode) "Collection route '$($route.Id)' does not terminate at configured AggregatorNode."
        $steps = @($route.Steps | Sort-Object Order)
        Assert-BT ($steps.Count -gt 0) "Collection route '$($route.Id)' has no steps."
        for ($index = 0; $index -lt $steps.Count; $index++) {
            Assert-BT ($steps[$index].Order -eq ($index + 1)) "Collection route '$($route.Id)' has a step gap."
            Assert-BT ($names -icontains [string]$steps[$index].ExecutorNode) "Unknown ExecutorNode in '$($route.Id)'."
            if ($index -gt 0) {
                Assert-BT ($steps[$index - 1].Write.Node -ieq $steps[$index].Read.Node) "Collection route '$($route.Id)' steps do not connect."
                Assert-BT ([string]$steps[$index - 1].Write.PathTemplate -ieq [string]$steps[$index].Read.AccessPath) "Collection route '$($route.Id)' step endpoints do not identify the same staging path."
            }
        }
        Assert-BT ($steps[-1].Write.Node -ieq $Configuration.AggregatorNode) "Final collection step for '$($route.Id)' does not reach AggregatorNode."
        Assert-BT ($steps[-1].Write.Kind -eq 'AggregatorStaging') "Final collection step for '$($route.Id)' does not terminate in Aggregator staging."
    }
    if ($PassThru) { return $Configuration }
    return $true
}

function ConvertTo-BTCanonicalNode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Configuration)
    [void](Test-BTNodeConfiguration $Configuration)
    $node = $Configuration.Node
    $components = @(Sort-BTOrdinalByKey @($node.Components | ForEach-Object {
        [ordered]@{
            Id = ([string]$_.Id).Normalize([Text.NormalizationForm]::FormC)
            Type = [string]$_.Type
            ResourceName = ([string]$_.ResourceName).Trim().Normalize([Text.NormalizationForm]::FormC)
            PhysicalIdentity = Get-BTComponentKey $_
            StopOrder = [int64]$_.StopOrder
            StartOrder = [int64]$_.StartOrder
            RequiredEndState = if ($_.PSObject.Properties['RequiredEndState']) { [string]$_.RequiredEndState } else { 'Running' }
        }
    }) { param($item) $item.PhysicalIdentity })
    $sources = @(Sort-BTOrdinalByKey @($node.LogSources | ForEach-Object {
        $workloads = @(Sort-BTOrdinalStrings @($_.Workloads | ForEach-Object { ([string]$_).ToUpperInvariant() }))
        $canonicalPath = (Get-BTCanonicalPath $_.Path).ToUpperInvariant()
        [ordered]@{
            Id = [string]$_.Id
            CanonicalPath = $canonicalPath
            PhysicalPathKey = $canonicalPath.ToUpperInvariant()
            Workloads = $workloads
            CleanupEnabled = [bool]$_.CleanupEnabled
            CollectEnabled = [bool]$_.CollectEnabled
            SafetyMarker = if ($_.PSObject.Properties['SafetyMarker'] -and $null -ne $_.SafetyMarker) { [string]$_.SafetyMarker } else { $null }
        }
    }) { param($item) $item.PhysicalPathKey })
    $assignments = @(Sort-BTOrdinalByKey @($node.CollectionAssignments | ForEach-Object {
        [ordered]@{
            RouteId = ([string]$_.RouteId).Normalize([Text.NormalizationForm]::FormC)
            StepOrder = [int64]$_.StepOrder
            ExecutorNode = ([string]$_.ExecutorNode).ToUpperInvariant()
            Read = [ordered]@{ Node = ([string]$_.Read.Node).ToUpperInvariant(); Kind = [string]$_.Read.Kind; Ref = [string]$_.Read.Ref; AccessPath = (Get-BTCanonicalPath ([string]$_.Read.AccessPath)).ToUpperInvariant() }
            Write = [ordered]@{ Node = ([string]$_.Write.Node).ToUpperInvariant(); Kind = [string]$_.Write.Kind; PathTemplate = (Get-BTCanonicalPath ([string]$_.Write.PathTemplate)).ToUpperInvariant() }
        }
    }) { param($item) '{0}`0{1:D20}' -f $item.RouteId,$item.StepOrder })
    return [ordered]@{
        CanonicalHashProfile = 'BrainTraceCanonicalNodeV1'
        SchemaVersion = [int64]$Configuration.SchemaVersion
        EnvironmentId = ([string]$Configuration.EnvironmentId).Normalize([Text.NormalizationForm]::FormC).ToUpperInvariant()
        ConfigRevision = ([string]$Configuration.ConfigRevision).Normalize([Text.NormalizationForm]::FormC)
        Node = [ordered]@{
            Name = ([string]$node.Name).ToUpperInvariant()
            MachineNames = @(Sort-BTOrdinalStrings @($node.MachineNames | ForEach-Object { ([string]$_).ToUpperInvariant() }))
            Roles = @(Sort-BTOrdinalStrings @($node.Roles | ForEach-Object { ([string]$_).ToUpperInvariant() }))
            WorkerRoot = if ($node.PSObject.Properties['WorkerRoot']) { (Get-BTCanonicalPath $node.WorkerRoot).ToUpperInvariant() } else { $null }
            AllowedCleanupRoots = @(Sort-BTOrdinalStrings @($node.AllowedCleanupRoots | ForEach-Object { (Get-BTCanonicalPath $_).ToUpperInvariant() }))
            Components = $components
            LogSources = $sources
            CollectionAssignments = $assignments
        }
    }
}

function Get-BTNodeConfigHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Configuration)
    $canonical = ConvertTo-BTCanonicalNode $Configuration
    return Get-BTSha256Hex (ConvertTo-BTCanonicalJsonValue $canonical)
}

function Get-BTNodeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Configuration)
    $canonical = ConvertTo-BTCanonicalNode $Configuration
    [pscustomobject][ordered]@{
        ProtocolVersion = 1
        EnvironmentId = $canonical.EnvironmentId
        Node = $canonical.Node.Name
        Roles = $canonical.Node.Roles
        ConfigRevision = $canonical.ConfigRevision
        ConfigHashAlgorithm = 'BrainTraceCanonicalNodeV1+SHA256'
        ConfigHash = Get-BTNodeConfigHash $Configuration
        Components = $canonical.Node.Components
        LogSources = $canonical.Node.LogSources
        Safety = [ordered]@{ AllowedCleanupRoots = $canonical.Node.AllowedCleanupRoots; WorkerRoot = $canonical.Node.WorkerRoot }
        CollectionAssignments = $canonical.Node.CollectionAssignments
    }
}
