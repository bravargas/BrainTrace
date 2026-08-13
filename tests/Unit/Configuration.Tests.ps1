BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Configuration validation and topology' {
    It 'validates <Name>' -TestCases @(
        @{Name='QA'},@{Name='PROD_6TP'},@{Name='PDX_AIO'},@{Name='FULL_AIO_SEPARATE_LOGS'},@{Name='FULL_AIO_SHARED_LOGS'}
    ) {
            $scenario=New-BTSimulationScenario -Name $Name -RootPath (Join-Path $TestDrive $Name)
            Test-BTEnvironmentConfiguration (Import-BTJsonFile $scenario.EnvironmentPath)|Should -BeTrue
    }
    It 'represents APP+WEB as one IIS component' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'aio');$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory 'AIO1.json')
        @($config.Node.Components|Where-Object Type -EQ IIS).Count|Should -Be 1
        @($config.Node.LogSources).Count|Should -Be 1
    }
    It 'supports separate APP+WEB+TP LogSources' {
        $scenario=New-BTSimulationScenario FULL_AIO_SEPARATE_LOGS (Join-Path $TestDrive 'separate');$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory 'FULLAIO1.json')
        @($config.Node.LogSources).Count|Should -Be 2
    }
    It 'supports one APP+WEB+TP shared LogSource' {
        $scenario=New-BTSimulationScenario FULL_AIO_SHARED_LOGS (Join-Path $TestDrive 'shared');$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory 'FULLAIO1.json')
        @($config.Node.LogSources).Count|Should -Be 1;@($config.Node.LogSources[0].Workloads).Count|Should -Be 3
    }
    It 'rejects a duplicate physical component' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'dupcomp');$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory 'AIO1.json');$duplicate=$config.Node.Components[0]|Select-Object *;$duplicate.Id='AnotherId';$config.Node.Components+=@($duplicate)
        {Test-BTNodeConfiguration $config}|Should -Throw '*Duplicate physical component*'
    }
    It 'rejects a duplicate canonical LogSource path' {
        $scenario=New-BTSimulationScenario FULL_AIO_SEPARATE_LOGS (Join-Path $TestDrive 'duplog');$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory 'FULLAIO1.json');$config.Node.LogSources[1].Path=$config.Node.LogSources[0].Path.ToUpperInvariant()+'\'
        {Test-BTNodeConfiguration $config}|Should -Throw '*Duplicate canonical LogSource path*'
    }
    It 'rejects an invalid command route' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'badroute');$env=Import-BTJsonFile $scenario.EnvironmentPath;$env.CommandRoutes[1].Hops=@('TP1','UNKNOWN','TP2')
        {Test-BTEnvironmentConfiguration $env}|Should -Throw '*Unknown command route hop*'
    }
    It 'fails closed on a wrong ExpectedConfigHash' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'badhash');$env=Import-BTJsonFile $scenario.EnvironmentPath;$env.Nodes[0].ExpectedConfigHash='0'*64;$path=Join-Path $TestDrive 'bad-env.json';[IO.File]::WriteAllText($path,($env|ConvertTo-Json -Depth 20))
        {Invoke-BTPrepare $path $scenario.NodeConfigDirectory (Join-Path $TestDrive 'runs') TP1 -DryRun -SimulationRoot $scenario.RootPath}|Should -Throw '*ExpectedConfigHash mismatch*'
    }
    It 'fails closed when Worker inventory roles differ from environment expectations' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'inventory-mismatch');$env=Import-BTJsonFile $scenario.EnvironmentPath;$env.Nodes[1].Roles=@('WEB');$path=Join-Path $TestDrive 'inventory-env.json';[IO.File]::WriteAllText($path,($env|ConvertTo-Json -Depth 20))
        {Invoke-BTPrepare $path $scenario.NodeConfigDirectory (Join-Path $TestDrive 'inventory-runs') TP1 -DryRun -SimulationRoot $scenario.RootPath}|Should -Throw '*Role inventory mismatch*'
    }
}
