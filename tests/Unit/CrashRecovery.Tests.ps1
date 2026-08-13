BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Worker crash-boundary recovery' {
    BeforeEach {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $configPath=Join-Path $scenario.NodeConfigDirectory 'TP1.json';$config=Import-BTJsonFile $configPath
        $root=$config.Node.WorkerRoot;$hash=Get-BTNodeConfigHash $config;$runId='crash-'+[guid]::NewGuid();$token=[guid]::NewGuid().ToString()
        $route=[pscustomobject]@{Hops=@('TP1');NextHopIndex=0};Open-BTPhase $root $runId STOP 1 $token $hash|Out-Null
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $token -Route $route
        $statePath=Join-Path $root 'State.json';$componentKey='IISAPPPOOL|STANDARDBANKINGSERVICE'
    }

    It 'recovers a command left before claim' {
        Publish-BTMessage $command $root|Out-Null
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Running
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be SUCCESS
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Stopped
    }

    It 'recovers a command already claimed into Processing' {
        Publish-BTMessage $command $root|Out-Null
        InModuleScope BrainTrace -Parameters @{r=$root} { Claim-BTMessage $r|Out-Null }
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be SUCCESS
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Stopped
    }

    It 'resumes safely after CLAIMED and AUTHORIZED receipt boundaries' -TestCases @(
        @{Mode='CrashAfterClaim';Expected='CLAIMED'},@{Mode='CrashAfterAuthorized';Expected='AUTHORIZED'}
    ) {
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),('{"STOP":{"Mode":"'+$Mode+'"}}'))
        Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be CRASHED
        (Import-BTJsonFile (Join-Path $root ('Receipts\'+$command.CommandId+'.receipt.json'))).State|Should -Be $Expected
        [IO.File]::Delete((Join-Path $root 'Faults.json'))
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be SUCCESS
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Stopped
    }

    It 'does not guess that an EXECUTING receipt had no effect' {
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),' {"STOP":{"Mode":"CrashBeforeEffect"}} ')
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be CRASHED
        [IO.File]::Delete((Join-Path $root 'Faults.json'))
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be INDETERMINATE
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Running
        $reconcile=Close-BTPhase $root $runId STOP 1 $token $hash $config
        $reconcile.ObservedComponents[0].State|Should -Be Running
        (Import-BTJsonFile (Join-Path $root ('Receipts\'+$command.CommandId+'.receipt.json'))).State|Should -Be TERMINAL
    }

    It 'recovers an applied effect before terminal receipt without replaying it' {
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),' {"STOP":{"Mode":"CrashAfterEffect"}} ')
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be CRASHED
        (Import-BTJsonFile $statePath).$componentKey|Should -Be Stopped
        [IO.File]::Delete((Join-Path $root 'Faults.json'))
        $recovered=@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0]
        $recovered.Result|Should -Be RECOVERED;$recovered.Disposition|Should -Be EXECUTED_STATUS_LOST
        (Import-BTJsonFile (Join-Path $root ('Receipts\'+$command.CommandId+'.receipt.json'))).State|Should -Be TERMINAL
    }

    It 'republishes a terminal receipt after crash before status and archives after restart' -TestCases @(
        @{Mode='CrashAfterTerminalReceipt';StatusExists=$false},@{Mode='CrashAfterStatus';StatusExists=$true}
    ) {
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),('{"STOP":{"Mode":"'+$Mode+'"}}'))
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be CRASHED
        (Test-Path (Join-Path $root ('Status\'+$runId+'__'+$command.CommandId+'.status.json')))|Should -Be $StatusExists
        [IO.File]::Delete((Join-Path $root 'Faults.json'));@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be DUPLICATE
        Test-Path (Join-Path $root ('Status\'+$runId+'__'+$command.CommandId+'.status.json'))|Should -BeTrue
        @(Get-ChildItem (Join-Path $root Archive) -Filter ('*'+$command.CommandId+'*')).Count|Should -Be 1
    }

    It 'never automatically replays an uncertain CLEAN after restart' {
        Close-BTPhase $root $runId STOP 1 $token $hash $config|Out-Null
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $log=Join-Path $scenario.RootPath 'ApplicationLogs\TP1\SBILogs\sample.log';$before=[IO.File]::ReadAllText($log)
        $clean=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route
        [IO.File]::WriteAllText((Join-Path $root 'Faults.json'),' {"CLEAN":{"Mode":"CrashBeforeEffect"}} ');Publish-BTMessage $clean $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be CRASHED;[IO.File]::Delete((Join-Path $root 'Faults.json'))
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be INDETERMINATE
        [IO.File]::ReadAllText($log)|Should -BeExactly $before
        (Close-BTPhase $root $runId CLEAN 2 $cleanToken $hash $config).Disposition|Should -Be INDETERMINATE
    }
}
