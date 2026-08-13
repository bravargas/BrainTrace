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
}
