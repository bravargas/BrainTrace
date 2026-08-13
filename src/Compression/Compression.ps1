function New-BTSimulationCompressionProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SimulationRoot)
    [pscustomobject]@{
        Name='Simulation'
        Preflight={ param($Source,$Destination) [pscustomobject]@{Success=$true;Provider='Simulation'} }
        Create={ param($Source,$Destination) [pscustomobject]@{Success=$true;PlannedArchive=$Destination;Source=$Source} }
        Validate={ param($Destination) [pscustomobject]@{Success=$true;PlannedArchive=$Destination} }
        Report={ param($Result) $Result }
    }
}

