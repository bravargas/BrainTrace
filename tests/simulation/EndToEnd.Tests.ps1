BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Phase 2 end-to-end simulation' {
    It 'completes Prepare across PDX AIO with one physical IIS operation' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'prepare')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be SUCCESS
        @($result.Stop|Where-Object{$_.Status.Node-eq'AIO1'}).Count|Should -Be 1
        @($result.Stop|Where-Object{$_.Status.Node-eq'AIO1'}|ForEach-Object{$_.Status.Details.Components}|Where-Object Id -EQ IIS).Count|Should -Be 1
    }
    It 'produces a useful QA DryRun without publishing commands' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'dry')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'runs-dry') TP1 -DryRun -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be DRYRUN;$result.PhysicalNodes.Count|Should -Be 6;$result.CollectionRoutes.Count|Should -Be 6
        foreach($node in $scenario.Environment.Nodes){@(Get-ChildItem (Join-Path (Split-Path $node.Inbox -Parent) 'Archive')).Count|Should -Be 0}
    }
    It 'simulates directional collection and preserves provenance' {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive 'collect')
        $result=Invoke-BTCollect $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'collect-runs') TP1 LoginFailure -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be SUCCESS;$result.BundlePlan.Provenance|Should -Be 'nodes/<SourceNode>/<LogSourceId>'
        Test-Path (Join-Path $scenario.RootPath 'StagingTemplate\nodes\WEB1\MobilitiLogs\sample.log')|Should -BeTrue
    }
    It 'retains an inspectable run workspace' {
        $scenario=New-BTSimulationScenario FULL_AIO_SHARED_LOGS (Join-Path $TestDrive 'workspace')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'workspace-runs') FULLAIO1 -DryRun -SimulationRoot $scenario.RootPath
        $runPath=Join-Path (Join-Path (Join-Path $TestDrive 'workspace-runs') FULL_AIO_SHARED_LOGS) $result.RunId
        foreach($name in @('run.json','plan.json','inventory','state','phases','commands','status','logs')){Test-Path (Join-Path $runPath $name)|Should -BeTrue}
    }
    It 'rejects a non-authoritative Controller' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'authority')
        {Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'authority-runs') AIO1 -DryRun -SimulationRoot $scenario.RootPath}|Should -Throw '*Non-authoritative*'
    }
    It 'reconciles STOP timeout before simulated rollback' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'stop-timeout');$tp=Join-Path $scenario.RootPath 'Nodes\TP1';[IO.File]::WriteAllText((Join-Path $tp 'Faults.json'),'{"STOP":{"Mode":"Timeout"}}')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'timeout-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be FAILED_ROLLED_BACK;$result.Reconciliation.Count|Should -Be 2
    }
    It 'restores a component that was initially stopped during rollback' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'initially-stopped');$tp=Join-Path $scenario.RootPath 'Nodes\TP1';$state=Import-BTJsonFile (Join-Path $tp 'State.json');$state.'IISAPPPOOL|STANDARDBANKINGSERVICE'='Stopped';[IO.File]::WriteAllText((Join-Path $tp 'State.json'),($state|ConvertTo-Json));$aio=Join-Path $scenario.RootPath 'Nodes\AIO1';[IO.File]::WriteAllText((Join-Path $aio 'Faults.json'),'{"STOP":{"Mode":"Timeout"}}')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'initial-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be FAILED_ROLLED_BACK;(Import-BTJsonFile (Join-Path $tp 'State.json')).'IISAPPPOOL|STANDARDBANKINGSERVICE'|Should -Be Stopped
    }
    It 'reconciles STOP effect when terminal status is lost' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'status-lost');$tp=Join-Path $scenario.RootPath 'Nodes\TP1';[IO.File]::WriteAllText((Join-Path $tp 'Faults.json'),'{"STOP":{"Mode":"StatusLost"}}')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'lost-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be FAILED_ROLLED_BACK
        @($result.Reconciliation|Where-Object{$_.Status.Details.Commands.Disposition-contains'EXECUTED_STATUS_LOST'}).Count|Should -BeGreaterThan 0
    }
    It 'treats relay status-return failure as a failed STOP barrier and reconciles it' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'relay-status-lost');$tp=Join-Path $scenario.RootPath 'Nodes\TP1'
        [IO.File]::WriteAllText((Join-Path $tp 'STOP.status-return-unavailable'),'simulation fault')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'relay-lost-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be FAILED_ROLLED_BACK
        @($result.Stop|Where-Object Result -EQ STATUS_LOST).Count|Should -Be 1
    }
    It 'reconciles a Worker crash after STOP effect' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'crash');$tp=Join-Path $scenario.RootPath 'Nodes\TP1';[IO.File]::WriteAllText((Join-Path $tp 'Faults.json'),'{"STOP":{"Mode":"CrashAfterEffect"}}')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'crash-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be FAILED_ROLLED_BACK
    }
    It 'returns RECOVERY_REQUIRED when phase close cannot reach a required Worker' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'unreachable');$tp=Join-Path $scenario.RootPath 'Nodes\TP1';[IO.File]::WriteAllText((Join-Path $tp 'PHASE_CLOSE.unavailable'),'simulation fault')
        $result=Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory (Join-Path $TestDrive 'unreachable-runs') TP1 -SimulationRoot $scenario.RootPath
        $result.Result|Should -Be RECOVERY_REQUIRED
    }
}

Describe 'Controller-local lock' {
    It 'recovers a stale diagnostic file' {
        $path=Join-Path $TestDrive 'locks\QA.lock.json';New-Item -ItemType Directory (Split-Path $path -Parent)-Force|Out-Null;[IO.File]::WriteAllText($path,'{}')
        $lock=Enter-BTEnvironmentLock QA run1 $path TP1 TP1
        try{$lock.StaleRecovered|Should -Not -BeNullOrEmpty}finally{Exit-BTEnvironmentLock $lock}
    }
    It 'rejects a non-authoritative lock request' {
        {Enter-BTEnvironmentLock QA run2 (Join-Path $TestDrive 'x.lock.json') TP1 APP1}|Should -Throw '*authoritative*'
    }
    It 'rejects a second active lock' {
        $path=Join-Path $TestDrive 'active\QA.lock.json';$first=Enter-BTEnvironmentLock QA run1 $path TP1 TP1
        try{{Enter-BTEnvironmentLock QA run2 $path TP1 TP1}|Should -Throw '*already locked*'}finally{Exit-BTEnvironmentLock $first}
    }
    It 'scopes live locks by EnvironmentId so different environments proceed independently' {
        $qa=Enter-BTEnvironmentLock QA run1 (Join-Path $TestDrive 'multi\QA.lock.json') TP1 TP1
        $pdx=$null
        try{$pdx=Enter-BTEnvironmentLock PDX run2 (Join-Path $TestDrive 'multi\PDX.lock.json') TP1 TP1;$pdx|Should -Not -BeNullOrEmpty}finally{if($null-ne$pdx){Exit-BTEnvironmentLock $pdx};Exit-BTEnvironmentLock $qa}
    }
    It 'does not let a stale-looking diagnostic file override a live mutex' {
        $path=Join-Path $TestDrive 'live\QA.lock.json';$first=Enter-BTEnvironmentLock QA run1 $path TP1 TP1;$before=[IO.File]::ReadAllText($path)
        try{{Enter-BTEnvironmentLock QA run2 $path TP1 TP1}|Should -Throw '*already locked*';[IO.File]::ReadAllText($path)|Should -BeExactly $before}finally{Exit-BTEnvironmentLock $first}
    }
    It 'prevents Prepare and Collect from overlapping in the same environment' {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive 'operation-overlap');$runs=Join-Path $TestDrive 'overlap-runs'
        $held=Enter-BTEnvironmentLock PDX_AIO held (Join-Path $TestDrive 'held\PDX_AIO.lock.json') TP1 TP1
        try {
            {Invoke-BTPrepare $scenario.EnvironmentPath $scenario.NodeConfigDirectory $runs TP1 -SimulationRoot $scenario.RootPath}|Should -Throw '*already locked*'
            {Invoke-BTCollect $scenario.EnvironmentPath $scenario.NodeConfigDirectory $runs TP1 LoginFailure -SimulationRoot $scenario.RootPath}|Should -Throw '*already locked*'
        } finally { Exit-BTEnvironmentLock $held }
    }
}
