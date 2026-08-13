function Get-BTRobocopyResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    $warnings = @()
    if (($ExitCode -band 1) -ne 0) { $warnings += 'FilesCopied' }
    if (($ExitCode -band 2) -ne 0) { $warnings += 'ExtraFilesOrDirectories' }
    if (($ExitCode -band 4) -ne 0) { $warnings += 'MismatchedFilesOrDirectories' }
    if (($ExitCode -band 8) -ne 0) { $warnings += 'CopyFailures' }
    if (($ExitCode -band 16) -ne 0) { $warnings += 'FatalError' }
    [pscustomobject]@{ ExitCode=$ExitCode; IsFailure=($ExitCode -ge 8); Category=if ($ExitCode -ge 8) {'FAILED'} elseif ($ExitCode -eq 0) {'SUCCESS'} else {'SUCCESS_WITH_WARNINGS'}; Warnings=$warnings }
}

function Get-BTCollectionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Environment, [Parameter(Mandatory = $true)][hashtable]$Inventories)
    [void](Test-BTEnvironmentConfiguration $Environment)
    $routes = @($Environment.Collection.Routes)
    $planned = @()
    foreach ($sourceNode in @($Environment.Nodes)) {
        Assert-BT ($Inventories.ContainsKey([string]$sourceNode.Name)) "Inventory missing for '$($sourceNode.Name)'."
        $inventory = $Inventories[[string]$sourceNode.Name]
        foreach ($source in @($inventory.LogSources | Where-Object CollectEnabled)) {
            $matches = @($routes | Where-Object { $_.SourceNode -ieq $sourceNode.Name -and $_.LogSourceId -ieq $source.Id })
            Assert-BT ($matches.Count -eq 1) "Collection-enabled source '$($sourceNode.Name)/$($source.Id)' must have exactly one route."
            $route = $matches[0]
            foreach ($step in @($route.Steps | Sort-Object Order)) {
                Assert-BT ($Inventories.ContainsKey([string]$step.ExecutorNode)) "Executor inventory missing for '$($step.ExecutorNode)'."
                $executorInventory = $Inventories[[string]$step.ExecutorNode]
                $assignments = @($executorInventory.CollectionAssignments | Where-Object { $_.RouteId -ieq $route.Id -and $_.StepOrder -eq $step.Order })
                Assert-BT ($assignments.Count -eq 1) "Executor '$($step.ExecutorNode)' does not have one matching assignment for '$($route.Id)' step $($step.Order)."
                $assignment = $assignments[0]
                Assert-BT ($assignment.ExecutorNode -ieq $step.ExecutorNode) "CollectionAssignment ExecutorNode mismatch for '$($route.Id)'."
                Assert-BT ($assignment.Read.Node -ieq $step.Read.Node -and $assignment.Read.Kind -eq $step.Read.Kind -and $assignment.Read.Ref -ieq $step.Read.Ref -and $assignment.Read.AccessPath -ieq $step.Read.AccessPath) "CollectionAssignment read endpoint mismatch for '$($route.Id)'."
                Assert-BT ($assignment.Write.Node -ieq $step.Write.Node -and $assignment.Write.Kind -eq $step.Write.Kind -and $assignment.Write.PathTemplate -ieq $step.Write.PathTemplate) "CollectionAssignment write endpoint mismatch for '$($route.Id)'."
                if ($step.Order -eq 1) {
                    Assert-BT ($step.Read.Node -ieq $route.SourceNode -and $step.Read.Ref -ieq $route.LogSourceId) "First step for '$($route.Id)' points to the wrong authoritative source."
                }
            }
            $planned += $route
        }
    }
    Assert-BT ($planned.Count -eq $routes.Count) 'Environment contains a collection route that does not match an authoritative collection-enabled source.'
    return $planned
}

function Invoke-BTSimulatedCopy {
    param($Assignment, [string]$SimulationRoot, [string]$RunId)
    $root = Get-BTCanonicalPath $SimulationRoot
    $sourceText = ([string]$Assignment.Read.AccessPath).Replace('{RunId}', $RunId)
    $source = Get-BTCanonicalPath $sourceText
    $destination = Get-BTCanonicalPath ([string]$Assignment.Write.PathTemplate).Replace('{RunId}', $RunId)
    Assert-BTNoReparsePoint -Path $source -Root $root
    Assert-BTNoReparsePoint -Path $destination -Root $root
    if (-not (Test-Path -LiteralPath $source)) { return [pscustomobject]@{Result='FAILED';ExitCode=8;Message='Source unavailable'} }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $sourceItems = @(Get-ChildItem -LiteralPath $source -Force -Recurse)
    foreach ($item in $sourceItems) {
        Assert-BT (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse point is not allowed in simulation source '$($item.FullName)'." 'BrainTrace.Simulation.ReparsePoint'
    }
    $sourceItems | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length).TrimStart('\')
        $target = Join-Path $destination $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::Copy($_.FullName, $target, $true)
    }
    [pscustomobject]@{Result='SUCCESS';ExitCode=1;Message='Simulated copy completed';Destination=$destination}
}
