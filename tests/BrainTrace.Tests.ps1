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
        @($config.Nodes.DeploymentManager)|Should -Be @('vscorappdev01','vscorappdev01','vsmobappdev03','vsmobappdev03','vsmobwebdev05','vsmobwebdev05')
        $config.Controller|Should -BeExactly vscorappdev01
        $config.Aggregator|Should -BeExactly vsmobappdev03
        $config.WorkerRoot|Should -BeExactly 'D:\FiservSoftware\PowerShell\BrainTrace'
        $config.Operations.Hub|Should -BeExactly 'vsmobwebdev05'
        $config.Operations.Relay|Should -BeExactly 'vsmobappdev03'
        $config.Operations.Executor|Should -BeExactly 'vscorappdev01'
        $config.Operations.HubRootUNC|Should -BeExactly '\\vsmobwebdev05\FiservSoftware$\PowerShell\BrainTrace\OperationsHub'
        $config.Operations.RelayRootUNC|Should -BeExactly '\\vsmobappdev03\FiservSoftware$\PowerShell\BrainTrace\OperationsRelay'
        (Get-BrainTraceNode $config vsmobwebdev05).CommandRoot|Should -BeExactly '\\vsmobwebdev05\FiservSoftware$\PowerShell\BrainTrace'
        (Get-BrainTraceNode $config vsmobwebdev06).CommandRoot|Should -BeExactly '\\vsmobwebdev06\FiservSoftware$\PowerShell\BrainTrace'
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
                Name=$env:COMPUTERNAME;Alias='TP1';DeploymentManager=$env:COMPUTERNAME;Roles=@('TP');CommandAccess='Direct';CommandRoot=$repo;CollectBy=$env:COMPUTERNAME
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
    It 'limits Web1 operations to safe high-level file requests' {
        $monitor=Get-Content (Join-Path $src 'Operations-Monitor.ps1') -Raw
        $portal=Get-Content (Join-Path $src 'Operations-Portal.ps1') -Raw
        $monitor|Should -Match "'Diagnose','Test','Prepare','Collect'"
        $monitor|Should -Match 'Request is expired'
        $monitor|Should -Match 'Live Prepare requires explicit confirmation'
        $monitor|Should -Not -Match "Operation-eq'CLEAN'"
        $portal|Should -Match 'Type PREPARE to continue'
        $portal|Should -Match 'Web1 -> App1 -> TP1'
    }
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

Describe 'Web1 operations file relay' {
    It 'moves an expired request Web1 to App1 to TP1 and returns its failure result' {
        $hub=Join-Path $TestDrive 'hub';$relay=Join-Path $TestDrive 'relay'
        $appRoot=Join-Path $TestDrive 'app';$tpRoot=Join-Path $TestDrive 'tp'
        foreach($path in @($hub,$relay,$appRoot,$tpRoot)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
        foreach($root in @($appRoot,$tpRoot)){
            Copy-Item (Join-Path $src 'Operations-Monitor.ps1') $root
            Copy-Item (Join-Path $src 'BrainTrace.Common.ps1') $root
        }
        Copy-Item (Join-Path $src 'BrainTrace.ps1') $tpRoot
        $toUnc={param($path) ([IO.Path]::GetFullPath($path)-replace '^([A-Za-z]):','\\localhost\$1$')}
        $nodes=@(
            [ordered]@{Name='TP1';Alias='TP1';DeploymentManager='TP1';Roles=@('TP');CommandAccess='Direct';CommandRoot=$tpRoot;CollectBy='TP1';Components=[ordered]@{Services=@();AppPools=@();ManageIIS=$false};Logs=@()},
            [ordered]@{Name='APP1';Alias='App1';DeploymentManager='APP1';Roles=@('APP');CommandAccess='Direct';CommandRoot=$appRoot;CollectBy='TP1';Components=[ordered]@{Services=@();AppPools=@();ManageIIS=$false};Logs=@()},
            [ordered]@{Name='WEB1';Alias='Web1';DeploymentManager='WEB1';Roles=@('WEB');CommandAccess='Via';CommandVia='APP1';CommandRoot=(Join-Path $TestDrive 'web');CollectBy='APP1';Components=[ordered]@{Services=@();AppPools=@();ManageIIS=$false};Logs=@()}
        )
        $config=[ordered]@{
            Environment='OPS-TEST';Controller='TP1';Aggregator='APP1';WorkerRoot=$tpRoot;StagingRoot=(Join-Path $TestDrive 'staging');StagingRootUNC=(& $toUnc (Join-Path $TestDrive 'staging'))
            TimeoutSeconds=5;PollSeconds=1;StopOrder=@('Services');StartOrder=@('Services');BundleDestination=$null;Nodes=$nodes
            Operations=[ordered]@{Hub='WEB1';Relay='APP1';Executor='TP1';HubRoot=$hub;HubRootUNC=(& $toUnc $hub);RelayRoot=$relay;RelayRootUNC=(& $toUnc $relay);RequestTimeoutMinutes=30}
        }
        Write-BrainTraceJsonAtomic ([ordered]@{LocalNode='APP1';EnvironmentConfig=$config}) (Join-Path $appRoot 'NodeConfig.json')
        Write-BrainTraceJsonAtomic ([ordered]@{LocalNode='TP1';EnvironmentConfig=$config}) (Join-Path $tpRoot 'NodeConfig.json')
        New-Item -ItemType Directory -Path (Join-Path $hub 'Requests') -Force|Out-Null
        $request=[ordered]@{RequestId='expired01';Environment='OPS-TEST';Operation='Test';Name=$null;DryRun=$false;Confirmed=$true;CreatedUtc=[datetime]::UtcNow.AddHours(-1).ToString('o');ExpiresUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
        Write-BrainTraceJsonAtomic $request (Join-Path (Join-Path $hub 'Requests') 'expired01.request.json')

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'Operations-Monitor.ps1')|Out-Null;$LASTEXITCODE|Should -Be 0
        Test-Path (Join-Path (Join-Path $relay 'Requests') 'expired01.request.json')|Should -BeTrue
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tpRoot 'Operations-Monitor.ps1')|Out-Null;$LASTEXITCODE|Should -Be 0
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'Operations-Monitor.ps1')|Out-Null;$LASTEXITCODE|Should -Be 0

        $result=Read-BrainTraceJson (Join-Path (Join-Path $hub 'Results') 'expired01.result.json')
        $result.Success|Should -BeFalse
        $result.Message|Should -Match 'expired'
        Test-Path (Join-Path (Join-Path $hub 'Archive') 'expired01.request.json')|Should -BeTrue
    }
}
