BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Simulation CLEAN containment' {
    BeforeEach {
        $scenario=New-BTSimulationScenario PDX_AIO (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $configPath=Join-Path $scenario.NodeConfigDirectory 'TP1.json';$config=Import-BTJsonFile $configPath;$root=$config.Node.WorkerRoot
        $runId='clean-'+[guid]::NewGuid();$route=[pscustomobject]@{Hops=@('TP1');NextHopIndex=0}
    }

    It 'rejects unsafe path spelling before any CLEAN effect' -TestCases @(
        @{Kind='empty';Path=''},@{Kind='wildcard';Path='D:\safe\*'},@{Kind='drive root';Path='C:\'}
    ) {
        $config.Node.LogSources[0].Path=$Path
        {Get-BTNodeConfigHash $config}|Should -Throw
    }

    It 'rejects traversal, sibling, absolute outside, and root-prefix confusion' -TestCases @(
        @{Kind='dot-dot';Suffix='..\..\outside'},
        @{Kind='alternate separators';Suffix='../outside'},
        @{Kind='sibling';Suffix='..\sibling'},
        @{Kind='prefix collision';Suffix=$null}
    ) {
        $outside=if($Kind -eq 'prefix collision'){$scenario.RootPath+'-evil'}else{Join-Path $scenario.RootPath $Suffix}
        $outside=[IO.Path]::GetFullPath($outside);New-Item -ItemType Directory -Path $outside -Force|Out-Null
        $sentinel=Join-Path $outside 'outside.log';[IO.File]::WriteAllText($sentinel,'must-survive')
        $config.Node.LogSources[0].Path=$outside;[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 20))
        $hash=Get-BTNodeConfigHash $config;$stopToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId STOP 1 $stopToken $hash|Out-Null;Close-BTPhase $root $runId STOP 1 $stopToken $hash $config|Out-Null
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
        [IO.File]::ReadAllText($sentinel)|Should -BeExactly 'must-survive'
    }

    It 'accepts a case-variant path only when it remains inside the same simulation root' {
        $source=$config.Node.LogSources[0].Path;$config.Node.LogSources[0].Path=$source.ToUpperInvariant();[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 20))
        $hash=Get-BTNodeConfigHash $config;$stopToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId STOP 1 $stopToken $hash|Out-Null;Close-BTPhase $root $runId STOP 1 $stopToken $hash $config|Out-Null
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be SUCCESS
    }

    It 'fails closed on a symlink or junction below the cleanup source' -TestCases @(
        @{LinkType='SymbolicLink'},@{LinkType='Junction'}
    ) {
        $source=$config.Node.LogSources[0].Path;$outside=Join-Path $TestDrive ('outside-'+$LinkType);New-Item -ItemType Directory -Path $outside -Force|Out-Null
        $link=Join-Path $source ('escape-'+$LinkType)
        try { New-Item -ItemType $LinkType -Path $link -Target $outside -ErrorAction Stop|Out-Null } catch { Set-ItResult -Skipped -Because "$LinkType creation is unavailable: $($_.Exception.Message)";return }
        $hash=Get-BTNodeConfigHash $config;$stopToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId STOP 1 $stopToken $hash|Out-Null;Close-BTPhase $root $runId STOP 1 $stopToken $hash $config|Out-Null
        $cleanToken=[guid]::NewGuid().ToString();Open-BTPhase $root $runId CLEAN 2 $cleanToken $hash|Out-Null
        $command=New-BTCommand PDX_AIO $runId TP1 TP1 CLEAN -ConfigRevision $config.ConfigRevision -ExpectedNodeConfigHash $hash -PhaseName CLEAN -PhaseEpoch 2 -PhaseToken $cleanToken -Route $route
        Publish-BTMessage $command $root|Out-Null;@(Invoke-BTWorker $root $configPath $scenario.RootPath)[0].Result|Should -Be REJECTED
    }
}
