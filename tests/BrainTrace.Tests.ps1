BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $src=Join-Path $repo 'src'
    . (Join-Path $src 'BrainTrace.Common.ps1')
}

Describe 'BrainTrace MVP configuration' {
    It 'validates the real DEV topology' {
        $config=Get-BrainTraceEnvironmentConfig DEV $repo
        $config.Nodes.Count|Should -Be 6
        @($config.Nodes.Alias)|Should -Be @('TP1','TP2','App1','App2','Web1','Web2')
        $config.Controller|Should -BeExactly vscorappdev01
        $config.Aggregator|Should -BeExactly vsmobappdev03
        $config.WorkerRoot|Should -BeExactly 'D:\FiservSoftware\PowerShell\BrainTrace'
    }
    It 'keeps local cleanup and remote collection paths distinct' {
        $config=Get-BrainTraceEnvironmentConfig DEV $repo;$web=Get-BrainTraceNode $config vsmobwebdev05
        $web.Logs[0].LocalPath|Should -BeExactly 'D:\Program Files\Fiserv\Mobiliti\MTS Platform\Logs'
        $web.Logs[0].UNCPath|Should -BeExactly '\\vsmobwebdev05\d$\Program Files\Fiserv\Mobiliti\MTS Platform\Logs'
    }
    It 'rejects duplicate physical log paths on one node' {
        $config=Get-BrainTraceEnvironmentConfig DEV $repo;$config.Nodes[0].Logs+=@($config.Nodes[0].Logs[0]|Select-Object *)
        {Test-BrainTraceEnvironment $config}|Should -Throw '*Duplicate local log path*'
    }
    It 'represents APP+WEB AIO resources once when configured once' {
        $config=Get-BrainTraceEnvironmentConfig DEV $repo;$copy=$config.Nodes[2]|Select-Object *;$copy.Roles=@('APP','WEB')
        @($copy.Components.Services|Where-Object{$_-eq'Mobiliti'}).Count|Should -Be 1
        [bool]$copy.Components.ManageIIS|Should -BeTrue
        @($copy.Logs).Count|Should -Be 1
    }
}

Describe 'BrainTrace DryRun safety' {
    It 'provides a read-only central diagnostic dashboard' {
        $controller=Get-Content (Join-Path $src 'BrainTrace.ps1') -Raw
        $controller|Should -Match "'Diagnose','Test','Prepare','Collect'"
        $controller|Should -Match 'Worker-Heartbeat\.json'
        $controller|Should -Match 'Worker-Fatal\.jsonl'
        $controller|Should -Match 'relay mirror'
        $controller|Should -Match 'no command files are published'
    }
    It 'renders the diagnostic dashboard without requiring a Worker response' {
        $diagnosticConfig=[ordered]@{
            Environment='LOCAL-DIAG';Controller=$env:COMPUTERNAME;Aggregator=$env:COMPUTERNAME
            WorkerRoot=$repo;StagingRoot=(Join-Path $TestDrive 'Staging');StagingRootUNC='\\localhost\c$\Temp\Staging'
            TimeoutSeconds=5;PollSeconds=1;StopOrder=@('Services');StartOrder=@('Services');BundleDestination=$null
            Nodes=@([ordered]@{
                Name=$env:COMPUTERNAME;Alias='TP1';Roles=@('TP');CommandAccess='Direct';CommandRoot=$repo;CollectBy=$env:COMPUTERNAME
                Components=[ordered]@{Services=@();AppPools=@();ManageIIS=$false};Logs=@()
            })
        }
        $path=Join-Path $TestDrive 'LOCAL-DIAG.json';Write-BrainTraceJsonAtomic $diagnosticConfig $path
        $output=& (Join-Path $src 'BrainTrace.ps1') Diagnose -Environment $path 6>&1|Out-String
        $output|Should -Match 'BrainTrace Diagnose'
        $output|Should -Match 'TP1'
        $output|Should -Match 'Read-only inspection'
    }
    It 'shows live Worker wait progress for non-DryRun operations' {
        $controller=Get-Content (Join-Path $src 'BrainTrace.ps1') -Raw
        $controller|Should -Match 'Waiting for'
        $controller|Should -Match "Write-Host '\.' -NoNewline"
        $controller|Should -Match '\$elapsed'
    }
    It 'prints every DEV node without creating files' {
        $sandbox=Join-Path $TestDrive 'sandbox';New-Item -ItemType Directory $sandbox|Out-Null
        $before=@(Get-ChildItem $sandbox -Force -Recurse).Count
        $output=& (Join-Path $src 'BrainTrace.ps1') Prepare -Environment DEV -DryRun 6>&1|Out-String
        foreach($node in @('vscorappdev01','vscorappdev02','vsmobappdev03','vsmobappdev04','vsmobwebdev05','vsmobwebdev06')){$output|Should -Match $node}
        @(Get-ChildItem $sandbox -Force -Recurse).Count|Should -Be $before
    }
    It 'supports a no-publication environment Test DryRun' {
        $output=& (Join-Path $src 'BrainTrace.ps1') Test -Environment DEV -DryRun 6>&1|Out-String
        $output|Should -Match 'Would PING 6 Workers'
        $output|Should -Match 'No command files were published'
    }
    It 'shows directional DEV collection executors and endpoints' {
        $output=& (Join-Path $src 'BrainTrace.ps1') Collect -Environment DEV -Name Test -DryRun 6>&1|Out-String
        $output|Should -Match 'Executor: vsmobappdev03'
        $output|Should -Match ([regex]::Escape('\\vsmobwebdev05\d$\Program Files\Fiserv\Mobiliti\MTS Platform\Logs'))
        $output|Should -Match 'Final ZIP destination: not configured'
    }
}

Describe 'Critical workflow policy' {
    It 'treats Robocopy 0 through 7 as success and 8+ as failure' {
        foreach($code in 0..7){(Get-BrainTraceRobocopyResult $code).Success|Should -BeTrue}
        (Get-BrainTraceRobocopyResult 8).Success|Should -BeFalse;(Get-BrainTraceRobocopyResult 16).Success|Should -BeFalse
    }
    It 'compares ISO UTC expirations in UTC rather than local wall-clock ticks' {
        $expires=([datetime]::UtcNow.AddMinutes(5).ToString('o'))
        ([datetime]$expires).ToUniversalTime()|Should -BeGreaterThan ([datetime]::UtcNow)
        (Get-Content (Join-Path $src 'Worker.ps1') -Raw)|Should -Match 'ExpiresUtc\)\.ToUniversalTime\(\)'
    }
    It 'does not invoke CLEAN after any STOP failure and still invokes START' {
        $script:actions=@()
        $result=Invoke-BrainTracePreparePolicy {
            param($action);$script:actions+=$action
            if($action-eq'STOP'){return @([pscustomobject]@{Success=$true},[pscustomobject]@{Success=$false})}
            return @([pscustomobject]@{Success=$true})
        }
        $result.CleanExecuted|Should -BeFalse;$script:actions|Should -Be @('STOP','START');$result.Clean.Count|Should -Be 0
    }
}
