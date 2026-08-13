@{
    RootModule = 'BrainTrace.psm1'
    ModuleVersion = '0.2.0'
    GUID = '95e9ba95-5167-4adc-ac24-a688b37b903c'
    Author = 'BrainTrace contributors'
    CompanyName = 'Community'
    Copyright = '(c) BrainTrace contributors'
    Description = 'BrainTrace Phase 2 simulation and DryRun orchestration core.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Import-BTJsonFile', 'Test-BTEnvironmentConfiguration', 'Test-BTNodeConfiguration',
        'ConvertTo-BTCanonicalNode', 'Get-BTNodeConfigHash', 'Get-BTNodeInventory',
        'New-BTCommand', 'Publish-BTMessage', 'Invoke-BTWorker',
        'Open-BTPhase', 'Close-BTPhase', 'Get-BTCollectionPlan', 'Get-BTRobocopyResult',
        'New-BTSimulationScenario', 'Invoke-BTPrepare', 'Invoke-BTCollect',
        'Enter-BTEnvironmentLock', 'Exit-BTEnvironmentLock'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell', 'Simulation', 'Troubleshooting')
            ProjectUri = 'https://example.invalid/BrainTrace'
        }
    }
}
