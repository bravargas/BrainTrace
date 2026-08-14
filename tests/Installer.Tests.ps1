BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $src=Join-Path $repo 'src'
    $scripts=Join-Path $repo 'scripts'
    . (Join-Path $src 'BrainTrace.Common.ps1')
}

Describe 'Worker installer support' {
    It 'provides a no-server six-node LocalLab launcher' {
        Test-Path (Join-Path $repo 'LocalLab.cmd')|Should -BeTrue
        Test-Path (Join-Path $scripts 'LocalLab.ps1')|Should -BeTrue
        Test-Path (Join-Path $scripts 'LocalLab-Agent.ps1')|Should -BeTrue
        $lab=Get-Content (Join-Path $scripts 'LocalLab.ps1') -Raw
        foreach($node in @('TP1','TP2','App1','App2','Web1','Web2')){$lab|Should -Match ([regex]::Escape($node))}
        $lab|Should -Match "Environment='LOCAL'"
        $lab|Should -Match 'Simulation=\$true'
        $lab|Should -Not -Match 'Register-ScheduledTask|schtasks\.exe'
    }
    It 'provides parameter-free DEV launchers and copy-paste commands' {
        Test-Path (Join-Path $scripts 'Deploy-DEV.ps1')|Should -BeTrue
        Test-Path (Join-Path $repo 'Deploy-DEV.cmd')|Should -BeTrue
        $commands=Get-Content (Join-Path (Join-Path $repo 'docs') 'DEPLOY-DEV-COMMANDS.txt') -Raw
        $commands|Should -Match ([regex]::Escape('.\Deploy-DEV.cmd'))
        $commands|Should -Match ([regex]::Escape('BrainTrace.ps1 Test -Environment DEV'))
    }

    It 'selects the DEV tier from its configured deployment manager' {
        $launcher=Get-Content (Join-Path $scripts 'Deploy-DEV.ps1') -Raw
        $launcher|Should -Match 'DeploymentManager'
        $launcher|Should -Match 'TP1, App1, or Web1'
        $launcher|Should -Match "Read-Host"
    }

    It 'offers a non-mutating same-tier deployment preview' {
        $output=& (Join-Path $scripts 'Deploy-BrainTrace.ps1') -Environment DEV -Manager vsmobwebdev05 -WhatIf 6>&1|Out-String
        $output|Should -Match 'vsmobwebdev05'
        $output|Should -Match 'vsmobwebdev06'
        $output|Should -Not -Match 'vsmobappdev04'
        $output|Should -Match 'Planned only'
    }

    It 'keeps installation boundaries configuration-driven by same-role manager' {
        $deployment=Get-Content (Join-Path $scripts 'Deploy-BrainTrace.ps1') -Raw
        $deployment|Should -Match 'config\.Nodes'
        $deployment|Should -Match 'config\.WorkerRoot'
        $deployment|Should -Match 'DeploymentManager'
        $deployment|Should -Match 'same-tier'
        $deployment|Should -Match 'task unchanged'
        $controller=Get-Content (Join-Path $src 'BrainTrace.ps1') -Raw
        $controller|Should -Not -Match 'schtasks'
    }

    It 'persists fatal Scheduled Task context errors for diagnosis' {
        $worker = Get-Content -LiteralPath (Join-Path $src 'Worker.ps1') -Raw
        $worker | Should -Match ([regex]::Escape('Worker-Fatal.jsonl'))
        $worker | Should -Match 'Publish-BrainTraceRelayDiagnostics'
        $worker | Should -Match 'trap\s*\{'
    }

    It 'can atomically replace an existing NodeConfig file' {
        $path=Join-Path $TestDrive 'NodeConfig.json'
        Write-BrainTraceJsonAtomic ([ordered]@{Revision=1}) $path
        Write-BrainTraceJsonAtomic ([ordered]@{Revision=2}) $path
        (Read-BrainTraceJson $path).Revision|Should -Be 2
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count|Should -Be 0
    }
    It 'uses a finite Task Scheduler repetition duration' {
        $text=Get-Content (Join-Path $scripts 'Install-Worker.ps1') -Raw
        $text|Should -Not -Match 'TimeSpan\]::MaxValue'
        $text|Should -Match 'New-TimeSpan -Days 3650'
    }
    It 'defaults installation to the approved FiservSoftware path' {
        $text=Get-Content (Join-Path $scripts 'Install-Worker.ps1') -Raw
        $text|Should -Match ([regex]::Escape("D:\FiservSoftware\PowerShell\BrainTrace"))
        $worker=Get-Content (Join-Path $src 'Worker.ps1') -Raw
        $worker|Should -Match 'IsNullOrWhiteSpace\(\$Root\).*\$Root=\$PSScriptRoot'
    }
    It 'installs the organized repository into the unchanged flat runtime layout' {
        $destination=Join-Path $TestDrive 'installed-controller'
        & (Join-Path $scripts 'Install-Worker.ps1') -Environment DEV -Node vscorappdev01 -Destination $destination|Out-Null
        foreach($relativePath in @('Worker.ps1','BrainTrace.Common.ps1','Test-Worker.ps1','Operations-Monitor.ps1','BrainTrace.ps1','Diagnose-DEV.cmd','NodeConfig.json','config\DEV.json')){
            Test-Path (Join-Path $destination $relativePath)|Should -BeTrue
        }
        (Read-BrainTraceJson (Join-Path $destination 'NodeConfig.json')).LocalNode|Should -BeExactly 'vscorappdev01'
    }
    It 'starts an installed Worker without explicit Root parameters on PowerShell 5.1' {
        $destination=Join-Path $TestDrive 'default-root-worker'
        & (Join-Path $scripts 'Install-Worker.ps1') -Environment DEV -Node vscorappdev01 -Destination $destination|Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $destination 'Worker.ps1') -MaxCommands 1|Out-Null
        $LASTEXITCODE|Should -Be 0
        $heartbeat=Read-BrainTraceJson (Join-Path (Join-Path $destination 'Status') 'Worker-Heartbeat.json')
        $heartbeat.Node|Should -BeExactly 'vscorappdev01'
    }
    It 'installs the operations portal only on the configured Web1 hub' {
        $destination=Join-Path $TestDrive 'installed-hub'
        & (Join-Path $scripts 'Install-Worker.ps1') -Environment DEV -Node vsmobwebdev05 -Destination $destination|Out-Null
        Test-Path (Join-Path $destination 'Operations-Portal.ps1')|Should -BeTrue
        Test-Path (Join-Path $destination 'Operations-DEV.cmd')|Should -BeTrue
        (Read-BrainTraceJson (Join-Path $destination 'NodeConfig.json')).LocalNode|Should -BeExactly 'vsmobwebdev05'
    }
    It 'installs the one-command smoke-test script' {
        $text=Get-Content (Join-Path $scripts 'Install-Worker.ps1') -Raw
        $text|Should -Match 'Test-Worker\.ps1'
        $smoke=Get-Content (Join-Path $scripts 'Test-Worker.ps1') -Raw
        $smoke|Should -Match '-DryRun'
        $smoke|Should -Match 'ComponentsBefore'
        $smoke|Should -Match 'LiveStopStart'
        $smoke|Should -Match 'finally'
    }
    It 'runs the Worker smoke test without changing component state' {
        $root=Join-Path $TestDrive 'worker'
        New-Item -ItemType Directory -Path $root -Force|Out-Null
        Copy-Item (Join-Path $src 'Worker.ps1') $root
        Copy-Item (Join-Path $src 'BrainTrace.Common.ps1') $root
        $environment=Get-BrainTraceEnvironmentConfig DEV $repo
        Write-BrainTraceJsonAtomic ([ordered]@{LocalNode='vsmobwebdev05';EnvironmentConfig=$environment}) (Join-Path $root 'NodeConfig.json')
        $result=& (Join-Path $scripts 'Test-Worker.ps1') -Root $root
        $result.Success|Should -BeTrue
        ($result.ComponentsBefore|ConvertTo-Json -Compress)|Should -Be ($result.ComponentsAfter|ConvertTo-Json -Compress)
    }
    It 'includes the Controller CLI and environment configuration for the Controller node' {
        $text=Get-Content (Join-Path $scripts 'Install-Worker.ps1') -Raw
        $text|Should -Match 'nodeConfig\.Name-ieq\$config\.Controller'
        $text|Should -Match "'BrainTrace\.ps1'"
        $text|Should -Match "'config'"
    }
}
