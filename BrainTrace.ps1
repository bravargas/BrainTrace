[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Prepare', 'Collect')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [string]$Name,

    [switch]$DryRun,

    [string]$WorkspaceRoot = (Join-Path $PSScriptRoot '.braintrace-work')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'BrainTrace.psd1') -Force -WarningAction SilentlyContinue

try {
    $scenario = New-BTSimulationScenario -Name $Environment -RootPath (Join-Path $WorkspaceRoot 'simulation')
    if ($Command -eq 'Prepare') {
        $result = Invoke-BTPrepare -EnvironmentPath $scenario.EnvironmentPath -NodeConfigDirectory $scenario.NodeConfigDirectory -WorkspaceRoot (Join-Path $WorkspaceRoot 'runs') -ControllerNode $scenario.Environment.ControllerNode -DryRun:$DryRun -SimulationRoot $scenario.RootPath
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Collect requires -Name.' }
        $result = Invoke-BTCollect -EnvironmentPath $scenario.EnvironmentPath -NodeConfigDirectory $scenario.NodeConfigDirectory -WorkspaceRoot (Join-Path $WorkspaceRoot 'runs') -ControllerNode $scenario.Environment.ControllerNode -Name $Name -DryRun:$DryRun -SimulationRoot $scenario.RootPath
    }

    $result
    if ($result.Result -notin @('SUCCESS', 'DRYRUN', 'SUCCEEDED_WITH_WARNINGS')) { exit 2 }
}
catch {
    Write-Error $_
    exit 1
}
