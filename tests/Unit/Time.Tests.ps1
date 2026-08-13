BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Injectable protocol time and scheduler' {
    AfterEach { InModuleScope BrainTrace { Set-BTTimeProvider $null } }

    It 'tests expiration deterministically without sleeping' {
        $now=[datetime]'2026-08-13T12:00:00Z'
        InModuleScope BrainTrace -Parameters @{clock=$now} { $script:fixedNow=$clock;Set-BTTimeProvider ([pscustomobject]@{UtcNow={ $script:fixedNow }}) }
        $command=New-BTCommand QA run TP1 TP1 INVENTORY -CreatedUtc $now -LifetimeSeconds 10 -Route ([pscustomobject]@{Hops=@('TP1');NextHopIndex=0})
        InModuleScope BrainTrace -Parameters @{clock=$now} { $script:fixedNow=$clock.AddSeconds(11) }
        {InModuleScope BrainTrace -Parameters @{c=$command} { Test-BTCommand $c TP1 QA }}|Should -Throw '*expired*'
    }

    It 'routes simulated delay through the injected scheduler' {
        $script:delayObserved=0
        InModuleScope BrainTrace { Set-BTTimeProvider ([pscustomobject]@{UtcNow={ [datetime]'2026-08-13T12:00:00Z' };Delay={param($milliseconds)$script:delayObserved=$milliseconds}}) }
        InModuleScope BrainTrace { Invoke-BTDelay 250;$script:delayObserved }|Should -Be 250
    }
}
