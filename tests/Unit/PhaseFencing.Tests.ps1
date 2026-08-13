BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Phase fencing and reconciliation' {
    BeforeEach {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive ([guid]::NewGuid().ToString()));$configPath=Join-Path $scenario.NodeConfigDirectory 'TP1.json';$config=Import-BTJsonFile $configPath;$root=$config.Node.WorkerRoot;$hash=Get-BTNodeConfigHash $config;$runId='run-'+[guid]::NewGuid();$token=[guid]::NewGuid().ToString();$route=[pscustomobject]@{Hops=@('TP1');NextHopIndex=0}
        Open-BTPhase $root $runId STOP 1 $token $hash|Out-Null
    }
    It 'suppresses STOP waiting in Inbox when PHASE_CLOSE is observable' {
        $stop=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $stop $root|Out-Null
        $close=New-BTCommand PDX_AIO $runId TP1 TP1 PHASE_CLOSE -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $close $root -Control|Out-Null
        $results=@(Invoke-BTWorker $root $configPath $scenario.RootPath);@($results|Where-Object{$_.CommandId-eq$stop.CommandId}).Count|Should -Be 0
        (Import-BTJsonFile (Join-Path $root State.json)).'IISAPPPOOL|STANDARDBANKINGSERVICE'|Should -Be Running
        (InModuleScope BrainTrace -Parameters @{r=$root;run=$runId} { Get-BTPhaseRecord $r $run STOP }).State|Should -Be Closed
        (InModuleScope BrainTrace -Parameters @{r=$root;id=$stop.CommandId} { Read-BTReceipt $r $id }).Disposition|Should -Be NOT_EXECUTED
    }
    It 'suppresses STOP claimed but not executing' {
        $stop=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $stop $root|Out-Null;InModuleScope BrainTrace -Parameters @{r=$root} {Claim-BTMessage $r|Out-Null}
        $reconcile=Close-BTPhase $root $runId STOP 1 $token $hash $config
        $reconcile.Commands[0].Disposition|Should -Be NOT_EXECUTED
    }
    It 'classifies an executing STOP during close reconciliation' {
        $receipt=[pscustomobject]@{CommandId=[guid]::NewGuid().ToString();CommandHash='x';RunId=$runId;Action='STOP';PhaseName='STOP';PhaseEpoch=1;State='EXECUTING';Disposition='NOT_EXECUTED';ConfigHash=$hash}
        InModuleScope BrainTrace -Parameters @{r=$root;receipt=$receipt} { Write-BTReceipt $r $receipt }
        $reconcile=Close-BTPhase $root $runId STOP 1 $token $hash $config
        $reconcile.Commands[0].Disposition|Should -Be EXECUTED_STATUS_LOST
    }
    It 'never replays an indeterminate CLEAN' {
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $receipt=[pscustomobject]@{CommandId=[guid]::NewGuid().ToString();CommandHash='x';RunId=$runId;Action='CLEAN';PhaseName='CLEAN';PhaseEpoch=2;State='EXECUTING';Disposition='NOT_EXECUTED';ConfigHash=$hash}
        InModuleScope BrainTrace -Parameters @{r=$root;receipt=$receipt} { Write-BTReceipt $r $receipt }
        (Close-BTPhase $root $runId CLEAN 2 $cleanToken $hash $config).Disposition|Should -Be INDETERMINATE
    }
    It 'rejects a late STOP after a closed epoch and after Worker restart' {
        Close-BTPhase $root $runId STOP 1 $token $hash $config|Out-Null
        $stop=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $stop $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'rejects CLEAN before a closed STOP barrier' {
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $clean=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route;Publish-BTMessage $clean $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'rejects mutation after ConfigHash drift' {
        $config.Node.Components[0].StopOrder++;[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 20))
        $stop=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $stop $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'rejects CLEAN after ConfigHash drift and does not touch the simulated log' {
        Close-BTPhase $root $runId STOP 1 $token $hash $config|Out-Null;$cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $config.Node.AllowedCleanupRoots[0]+='-changed';[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 20));$logFile=Join-Path $scenario.RootPath 'ApplicationLogs\TP1\SBILogs\sample.log';$before=[IO.File]::ReadAllText($logFile)
        $clean=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route;Publish-BTMessage $clean $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED;[IO.File]::ReadAllText($logFile)|Should -Be $before
    }
    It 'rejects START after ConfigHash drift' {
        Close-BTPhase $root $runId STOP 1 $token $hash $config|Out-Null;$startToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId START 2 $startToken $hash|Out-Null
        $config.Node.Components[0].StartOrder++;[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 20))
        $start=New-BTCommand PDX_AIO $runId TP1 TP1 START -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName START -PhaseEpoch 2 -PhaseToken $startToken -Route $route;Publish-BTMessage $start $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'rejects a late START after its epoch is closed' {
        $startToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId START 2 $startToken $hash|Out-Null;Close-BTPhase $root $runId START 2 $startToken $hash $config|Out-Null
        $start=New-BTCommand PDX_AIO $runId TP1 TP1 START -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName START -PhaseEpoch 2 -PhaseToken $startToken -Route $route;Publish-BTMessage $start $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'processes PHASE_CLOSE ahead of a delayed PHASE_OPEN and mutation' {
        $newRun='priority-'+[guid]::NewGuid();$newToken=[guid]::NewGuid().ToString()
        $open=New-BTCommand PDX_AIO $newRun TP1 TP1 PHASE_OPEN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $newToken -Route $route
        $stop=New-BTCommand PDX_AIO $newRun TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $newToken -Route $route
        $close=New-BTCommand PDX_AIO $newRun TP1 TP1 PHASE_CLOSE -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $newToken -Route $route
        Publish-BTMessage $open $root -Control|Out-Null;Publish-BTMessage $stop $root|Out-Null;Publish-BTMessage $close $root -Control|Out-Null
        $results=@(Invoke-BTWorker $root $configPath $scenario.RootPath)
        $results[0].CommandId|Should -Be $close.CommandId
        (Import-BTJsonFile (Join-Path $root State.json)).'IISAPPPOOL|STANDARDBANKINGSERVICE'|Should -Be Running
        (InModuleScope BrainTrace -Parameters @{r=$root;run=$newRun} { Get-BTPhaseRecord $r $run STOP }).State|Should -Be Closed
    }
    It 'accepts duplicate PHASE_CLOSE without weakening the persisted fence' {
        Close-BTPhase $root $runId STOP 1 $token $hash $config|Out-Null
        $again=Close-BTPhase $root $runId STOP 1 $token $hash $config
        $again.Disposition|Should -Be RECONCILED
        (InModuleScope BrainTrace -Parameters @{r=$root;run=$runId} { Get-BTPhaseRecord $r $run STOP }).State|Should -Be Closed
    }
    It 'rejects a stale lower epoch after a higher epoch is persisted' {
        Open-BTPhase $root $runId STOP 2 ([guid]::NewGuid().ToString()) $hash|Out-Null
        {Open-BTPhase $root $runId STOP 1 $token $hash}|Should -Throw '*stale*'
        (InModuleScope BrainTrace -Parameters @{r=$root;run=$runId} { Get-BTPhaseRecord $r $run STOP }).Epoch|Should -Be 2
    }
    It 'retains a durable fence when PHASE_CLOSE crashes during reconciliation' {
        $stop=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route;Publish-BTMessage $stop $root|Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),' {"PHASE_CLOSE":{"Mode":"CrashAfterFence"}} ')
        {Close-BTPhase $root $runId STOP 1 $token $hash $config}|Should -Throw '*durable fence*'
        (InModuleScope BrainTrace -Parameters @{r=$root;run=$runId} { Get-BTPhaseRecord $r $run STOP }).State|Should -Be Closed
        [IO.File]::Delete((Join-Path $root 'Faults.json'))
        (Close-BTPhase $root $runId STOP 1 $token $hash $config).Commands[0].Disposition|Should -Be NOT_EXECUTED
        (Import-BTJsonFile (Join-Path $root State.json)).'IISAPPPOOL|STANDARDBANKINGSERVICE'|Should -Be Running
    }
}
