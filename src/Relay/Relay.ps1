function Invoke-BTRelaySimulation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Command, [Parameter(Mandatory = $true)]$Environment, [Parameter(Mandatory = $true)][hashtable]$NodeRoots, [hashtable]$Faults = @{})
    $route = @($Environment.CommandRoutes | Where-Object Target -EQ $Command.TargetNode)
    Assert-BT ($route.Count -eq 1) "No unique configured command route for '$($Command.TargetNode)'."
    $hops = @($route[0].Hops)
    Assert-BT ($Command.Route.Hops.Count -eq $hops.Count) 'Command route differs from configured route.'
    for ($index=0; $index -lt $hops.Count; $index++) { Assert-BT ($Command.Route.Hops[$index] -ieq $hops[$index]) 'Command route hop mismatch.' }
    foreach ($hop in $hops) {
        if ($Faults.ContainsKey($hop) -and $Faults[$hop] -eq 'Unavailable') { return [pscustomobject]@{Result='FAILED';Hop=$hop;Message='Simulated relay unavailable'} }
        if ($Faults.ContainsKey($hop) -and [string]$Faults[$hop] -match '^Delay:(\d+)$') { Invoke-BTDelay -Milliseconds ([int]$Matches[1]) }
        $sentinel=Join-Path $NodeRoots[[string]$hop] ("$($Command.Action).unavailable")
        if(Test-Path -LiteralPath $sentinel){return [pscustomobject]@{Result='FAILED';Hop=$hop;Message="Simulated relay unavailable for $($Command.Action)"}}
    }
    $targetRoot = $NodeRoots[[string]$Command.TargetNode]
    Publish-BTMessage -Message $Command -NodeRoot $targetRoot -Control:($Command.Action -in @('PHASE_OPEN','PHASE_CLOSE')) | Out-Null
    $statusReturn='SUCCESS';foreach($hop in $hops){
        if($Faults.ContainsKey("StatusReturn:$hop")-and$Faults["StatusReturn:$hop"]-eq'Unavailable'){$statusReturn='FAILED'}
        $statusSentinel=Join-Path $NodeRoots[[string]$hop] ("$($Command.Action).status-return-unavailable")
        if(Test-Path -LiteralPath $statusSentinel){$statusReturn='FAILED'}
    }
    [pscustomobject]@{Result='SUCCESS';Hops=$hops;Target=$Command.TargetNode;StatusReturn=$statusReturn}
}
