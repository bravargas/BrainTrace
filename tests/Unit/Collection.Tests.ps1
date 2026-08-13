BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Directional collection planning' {
    It 'plans SourceNode different from CollectorNode without reverse inference' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'qa');$env=Import-BTJsonFile $scenario.EnvironmentPath;$inventories=@{}
        foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        $plan=Get-BTCollectionPlan $env $inventories
        @($plan|Where-Object{$_.SourceNode-eq'WEB1'-and$_.CollectorNode-eq'APP1'}).Count|Should -Be 1
    }
    It 'plans CollectorNode different from AggregatorNode' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'pdx');$env=Import-BTJsonFile $scenario.EnvironmentPath;$inventories=@{}
        foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        @((Get-BTCollectionPlan $env $inventories)|Where-Object{$_.CollectorNode-ne$_.AggregatorNode}).Count|Should -BeGreaterThan 0
    }
    It 'rejects a wrong CollectionAssignment source binding' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'wrong');$env=Import-BTJsonFile $scenario.EnvironmentPath;$inventories=@{}
        foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        $inventories['APP1'].CollectionAssignments[0].Read.Ref='WrongSource'
        {Get-BTCollectionPlan $env $inventories}|Should -Throw '*read endpoint mismatch*'
    }
    It 'rejects a gapped route' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'gap');$env=Import-BTJsonFile $scenario.EnvironmentPath;$env.Collection.Routes[0].Steps[0].Order=2
        {Test-BTEnvironmentConfiguration $env}|Should -Throw '*step gap*'
    }
    It 'does not treat the Controller command route as reverse collection access' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'direction');$env=Import-BTJsonFile $scenario.EnvironmentPath
        $webRoute=@($env.Collection.Routes|Where-Object SourceNode -EQ WEB1)[0]
        $webRoute.Steps[0].ExecutorNode|Should -Be APP1
        @($env.CommandRoutes|Where-Object Target -EQ WEB1)[0].Hops|Should -Be @('TP1','APP1','WEB1')
    }
    It 'rejects the wrong ExecutorNode even when the endpoint text is unchanged' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'wrong-executor');$env=Import-BTJsonFile $scenario.EnvironmentPath;$inventories=@{}
        foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        @($env.Collection.Routes|Where-Object SourceNode -EQ WEB1)[0].Steps[0].ExecutorNode='TP1'
        {Get-BTCollectionPlan $env $inventories}|Should -Throw '*does not have one matching assignment*'
    }
    It 'rejects wrong SourceNode and wrong LogSourceId identities' -TestCases @(
        @{Field='SourceNode';Value='WEB2'},@{Field='LogSourceId';Value='UnknownLogs'}
    ) {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive ('identity-'+$Field));$env=Import-BTJsonFile $scenario.EnvironmentPath;$inventories=@{}
        foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        @($env.Collection.Routes|Where-Object SourceNode -EQ WEB1)[0].$Field=$Value
        {Get-BTCollectionPlan $env $inventories}|Should -Throw
    }
    It 'rejects disconnected endpoint paths and a reversed first step' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'disconnected');$env=Import-BTJsonFile $scenario.EnvironmentPath
        $multi=@($env.Collection.Routes|Where-Object{$_.Steps.Count-eq 2})[0];$multi.Steps[1].Read.AccessPath+='-different'
        {Test-BTEnvironmentConfiguration $env}|Should -Throw '*same staging path*'
        $multi.Steps[1].Read.AccessPath=$multi.Steps[0].Write.PathTemplate;$multi.Steps[0].Read.Node='AIO1'
        $inventories=@{};foreach($node in $env.Nodes){$inventories[$node.Name]=Get-BTNodeInventory (Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json')))}
        {Get-BTCollectionPlan $env $inventories}|Should -Throw
    }
    It 'rejects a route that ends at the Aggregator node but not Aggregator staging' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'wrong-final-kind');$env=Import-BTJsonFile $scenario.EnvironmentPath
        $env.Collection.Routes[0].Steps[-1].Write.Kind='CollectorStaging'
        {Test-BTEnvironmentConfiguration $env}|Should -Throw '*Aggregator staging*'
    }
    It 'rejects a duplicate route for the same authoritative source' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'duplicate-source');$env=Import-BTJsonFile $scenario.EnvironmentPath
        $duplicate=$env.Collection.Routes[0]|Select-Object *;$duplicate.Id='duplicate-route';$env.Collection.Routes+=@($duplicate)
        {Test-BTEnvironmentConfiguration $env}|Should -Throw '*Duplicate collection source*'
    }
}

Describe 'Robocopy result policy without invoking Robocopy' {
    It 'treats <Code> as nonfatal' -TestCases @(0..7|ForEach-Object{@{Code=$_}}) {(Get-BTRobocopyResult $Code).IsFailure|Should -BeFalse}
    It 'treats <Code> as failure' -TestCases @(@{Code=8},@{Code=16},@{Code=24}) {(Get-BTRobocopyResult $Code).IsFailure|Should -BeTrue}
    It 'decodes combined nonfatal bits' {(Get-BTRobocopyResult 7).Warnings|Should -Contain MismatchedFilesOrDirectories}
    It 'decodes combined failure bits' {(Get-BTRobocopyResult 24).Warnings|Should -Contain FatalError}
}
