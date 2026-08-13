BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Filesystem protocol' {
    BeforeEach {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $configPath=Join-Path $scenario.NodeConfigDirectory 'TP1.json';$config=Import-BTJsonFile $configPath;$root=$config.Node.WorkerRoot;$hash=Get-BTNodeConfigHash $config
        $runId='test-'+[guid]::NewGuid();$phase=[pscustomobject]@{Name='STOP';Epoch=1;Token=[guid]::NewGuid().ToString()}
        $route=[pscustomobject]@{Hops=@('TP1');NextHopIndex=0}
    }
    It 'publishes atomically without leaving tmp files' {
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -Route $route
        $path=Publish-BTMessage $command $root
        Test-Path $path|Should -BeTrue;@(Get-ChildItem (Join-Path $root Inbox) -Filter '*.tmp').Count|Should -Be 0
    }
    It 'rejects malformed JSON safely' {
        [IO.File]::WriteAllText((Join-Path (Join-Path $root Inbox) 'bad.command.json'),'{bad')
        $result=@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0]
        $result.Result|Should -Be 'REJECTED';@(Get-ChildItem (Join-Path $root Rejected)).Count|Should -Be 1
    }
    It 'rejects duplicate JSON properties before deserialization' {
        $path=Join-Path $TestDrive 'duplicate.json';[IO.File]::WriteAllText($path,'{"Action":"STOP","Action":"CLEAN"}')
        {Import-BTJsonFile $path}|Should -Throw '*Duplicate JSON property*'
    }
    It 'rejects an unknown action' {
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -Route $route;$command.Action='SCRIPT'
        Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be 'REJECTED'
    }
    It 'rejects an arbitrary path field in a command' {
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -Route $route;$command|Add-Member Path 'D:\untrusted'
        Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be 'REJECTED'
    }
    It 'rejects action parameters outside the closed schema' {
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -Parameters @{Path='D:\untrusted'} -Route $route
        Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
    It 'rejects the wrong target' {
        $command=New-BTCommand PDX_AIO $runId TP1 OTHER INVENTORY -Route $route;Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be 'REJECTED'
    }
    It 'rejects an expired command' {
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -Route $route -CreatedUtc ([datetime]::UtcNow.AddMinutes(-10)) -LifetimeSeconds 1;Publish-BTMessage $command $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be 'REJECTED'
    }
    It 'reuses an identical duplicate CommandId result' {
        Open-BTPhase $root $runId STOP 1 $phase.Token $hash|Out-Null
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 STOP -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName STOP -PhaseEpoch 1 -PhaseToken $phase.Token -Route $route
        Publish-BTMessage $command $root|Out-Null;$first=@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0]
        Publish-BTMessage $command $root|Out-Null;$second=@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0]
        $first.Result|Should -Be SUCCESS;$second.Result|Should -Be DUPLICATE
    }
    It 'rejects a CommandId collision' {
        $id=[guid]::NewGuid();$one=New-BTCommand PDX_AIO $runId TP1 TP1 INVENTORY -CommandId $id -Route $route;Publish-BTMessage $one $root|Out-Null;Invoke-BTWorker $root $configPath $scenario.RootPath|Out-Null
        $two=New-BTCommand PDX_AIO $runId TP1 TP1 STATE -CommandId $id -Route $route;Publish-BTMessage $two $root|Out-Null
        @(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
}
