Set-StrictMode -Version 2.0

$script:ModuleRoot = $PSScriptRoot
$sourceFiles = @(
    'src\Common\Errors.ps1',
    'src\Common\Time.ps1',
    'src\Common\Json.ps1',
    'src\Common\Configuration.ps1',
    'src\Common\Logging.ps1',
    'src\Common\Protocol.ps1',
    'src\Collection\Collection.ps1',
    'src\Compression\Compression.ps1',
    'src\Simulation\Simulation.ps1',
    'src\Relay\Relay.ps1',
    'src\Worker\Worker.ps1',
    'src\Controller\Controller.ps1'
)

foreach ($sourceFile in $sourceFiles) {
    . (Join-Path $script:ModuleRoot $sourceFile)
}

Export-ModuleMember -Function @(
    'Import-BTJsonFile', 'Test-BTEnvironmentConfiguration', 'Test-BTNodeConfiguration',
    'ConvertTo-BTCanonicalNode', 'Get-BTNodeConfigHash', 'Get-BTNodeInventory',
    'New-BTCommand', 'Publish-BTMessage', 'Invoke-BTWorker',
    'Open-BTPhase', 'Close-BTPhase', 'Get-BTCollectionPlan', 'Get-BTRobocopyResult',
    'New-BTSimulationScenario', 'Invoke-BTPrepare', 'Invoke-BTCollect',
    'Enter-BTEnvironmentLock', 'Exit-BTEnvironmentLock'
)
