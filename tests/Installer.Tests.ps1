BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'BrainTrace.Common.ps1')
}

Describe 'Worker installer support' {
    It 'can atomically replace an existing NodeConfig file' {
        $path=Join-Path $TestDrive 'NodeConfig.json'
        Write-BrainTraceJsonAtomic ([ordered]@{Revision=1}) $path
        Write-BrainTraceJsonAtomic ([ordered]@{Revision=2}) $path
        (Read-BrainTraceJson $path).Revision|Should -Be 2
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count|Should -Be 0
    }
    It 'uses a finite Task Scheduler repetition duration' {
        $text=Get-Content (Join-Path $repo 'Install-Worker.ps1') -Raw
        $text|Should -Not -Match 'TimeSpan\]::MaxValue'
        $text|Should -Match 'New-TimeSpan -Days 3650'
    }
    It 'defaults installation to the approved FiservSoftware path' {
        $text=Get-Content (Join-Path $repo 'Install-Worker.ps1') -Raw
        $text|Should -Match ([regex]::Escape("D:\FiservSoftware\PowerShell\BrainTrace"))
        $worker=Get-Content (Join-Path $repo 'Worker.ps1') -Raw
        $worker|Should -Match '\$Root = \$PSScriptRoot'
    }
    It 'installs the one-command smoke-test script' {
        $text=Get-Content (Join-Path $repo 'Install-Worker.ps1') -Raw
        $text|Should -Match 'Test-Worker\.ps1'
        $smoke=Get-Content (Join-Path $repo 'Test-Worker.ps1') -Raw
        $smoke|Should -Match '-DryRun'
        $smoke|Should -Match 'ComponentsBefore'
    }
    It 'runs the Worker smoke test without changing component state' {
        $root=Join-Path $TestDrive 'worker'
        New-Item -ItemType Directory -Path $root -Force|Out-Null
        Copy-Item (Join-Path $repo 'Worker.ps1') $root
        Copy-Item (Join-Path $repo 'BrainTrace.Common.ps1') $root
        $environment=Get-BrainTraceEnvironmentConfig DEV $repo
        Write-BrainTraceJsonAtomic ([ordered]@{LocalNode='vsmobwebdev05';EnvironmentConfig=$environment}) (Join-Path $root 'NodeConfig.json')
        $result=& (Join-Path $repo 'Test-Worker.ps1') -Root $root
        $result.Success|Should -BeTrue
        ($result.ComponentsBefore|ConvertTo-Json -Compress)|Should -Be ($result.ComponentsAfter|ConvertTo-Json -Compress)
    }
}
