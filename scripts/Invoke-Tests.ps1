[CmdletBinding()]
param([ValidateSet('None','Normal','Detailed')][string]$Verbosity = 'Normal')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repositoryRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = $Verbosity
$result = Invoke-Pester -Configuration $configuration
[pscustomobject]@{
    Result = [string]$result.Result
    Total = $result.TotalCount
    Passed = $result.PassedCount
    Failed = $result.FailedCount
    Skipped = $result.SkippedCount
    Duration = $result.Duration
}
if ($result.FailedCount -gt 0) { exit 1 }
