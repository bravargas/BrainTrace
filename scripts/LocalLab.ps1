[CmdletBinding()]
param(
    [ValidateSet('Menu','Initialize','Diagnose','Test','PrepareDryRun','Portal','Reset')]
    [string]$Action='Menu'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$sourceRoot=Join-Path $repositoryRoot 'src'
$labRoot=Join-Path $repositoryRoot 'LocalLab'
$nodesRoot=Join-Path $labRoot 'Nodes'
$configPath=Join-Path (Join-Path $labRoot 'config') 'LOCAL.json'
$stopFile=Join-Path $labRoot 'Engine.stop'
$agentStatusRoot=Join-Path $labRoot 'AgentStatus'
. (Join-Path $sourceRoot 'BrainTrace.Common.ps1')

function Remove-BrainTraceLocalLab {
    if(-not(Test-Path -LiteralPath $labRoot)){return}
    $resolved=[IO.Path]::GetFullPath($labRoot).TrimEnd('\')
    $expectedParent=[IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
    if((Split-Path -Parent $resolved)-ine$expectedParent-or(Split-Path -Leaf $resolved)-ine'LocalLab'){
        throw "Refusing to remove unexpected LocalLab path '$resolved'."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-BrainTraceLocalLabNode {
    param([string]$Name,[string]$Role,[string]$Manager,[string]$CommandAccess,[string]$CommandVia,[string]$CollectBy)
    $root=Join-Path $nodesRoot $Name
    $logRoot=Join-Path $root 'SampleLogs'
    $node=[ordered]@{
        Name=$Name;Alias=$Name;DeploymentManager=$Manager;Roles=@($Role);CommandAccess=$CommandAccess
        CommandRoot=$root;CollectBy=$CollectBy
        Components=[ordered]@{Services=@();AppPools=@();ManageIIS=$false}
        Logs=@([ordered]@{Id='SampleLogs';LocalPath=$logRoot;UNCPath=$logRoot})
    }
    if($CommandAccess-eq'Via'){$node.CommandVia=$CommandVia}
    return $node
}

function Initialize-BrainTraceLocalLab {
    Remove-BrainTraceLocalLab
    foreach($path in @($labRoot,$nodesRoot,(Split-Path -Parent $configPath),$agentStatusRoot)){New-Item -ItemType Directory -Path $path -Force|Out-Null}

    $tp1=Join-Path $nodesRoot 'TP1';$app1=Join-Path $nodesRoot 'App1';$web1=Join-Path $nodesRoot 'Web1'
    $config=[ordered]@{
        Environment='LOCAL';Simulation=$true;Controller='TP1';Aggregator='App1';WorkerRoot=$tp1
        StagingRoot=(Join-Path $app1 'Staging');StagingRootUNC=(Join-Path $app1 'Staging')
        TimeoutSeconds=15;PollSeconds=1;StopOrder=@('AppPools','Services','IIS');StartOrder=@('IIS','Services','AppPools')
        BundleDestination=$null
        Operations=[ordered]@{
            Hub='Web1';Relay='App1';Executor='TP1';HubRoot=(Join-Path $web1 'OperationsHub');HubRootUNC=(Join-Path $web1 'OperationsHub')
            RelayRoot=(Join-Path $app1 'OperationsRelay');RelayRootUNC=(Join-Path $app1 'OperationsRelay');RequestTimeoutMinutes=5
        }
        Nodes=@(
            (New-BrainTraceLocalLabNode TP1 TP TP1 Direct $null TP1),
            (New-BrainTraceLocalLabNode TP2 TP TP1 Direct $null TP1),
            (New-BrainTraceLocalLabNode App1 APP App1 Direct $null TP1),
            (New-BrainTraceLocalLabNode App2 APP App1 Direct $null TP1),
            (New-BrainTraceLocalLabNode Web1 WEB Web1 Via App1 App1),
            (New-BrainTraceLocalLabNode Web2 WEB Web1 Via App1 App1)
        )
    }
    [void](Test-BrainTraceEnvironment $config)
    Write-BrainTraceJsonAtomic $config $configPath

    foreach($node in @($config.Nodes)){
        $root=[string]$node.CommandRoot
        foreach($folder in @($root,(Join-Path $root 'Commands'),(Join-Path $root 'Status'),(Join-Path $root 'Archive'),(Join-Path $root 'Logs'),[string]$node.Logs[0].LocalPath)){
            if(-not(Test-Path -LiteralPath $folder)){New-Item -ItemType Directory -Path $folder -Force|Out-Null}
        }
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'Worker.ps1') -Destination $root -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'BrainTrace.Common.ps1') -Destination $root -Force
        Write-BrainTraceJsonAtomic ([ordered]@{LocalNode=$node.Name;EnvironmentConfig=$config}) (Join-Path $root 'NodeConfig.json')
        [IO.File]::WriteAllText((Join-Path ([string]$node.Logs[0].LocalPath) 'sample.log'),("Sample log for $($node.Name)"),(New-Object Text.UTF8Encoding($false)))
    }

    foreach($name in @('TP1','App1')){Copy-Item -LiteralPath (Join-Path $sourceRoot 'Operations-Monitor.ps1') -Destination (Join-Path $nodesRoot $name) -Force}
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'BrainTrace.ps1') -Destination $tp1 -Force
    $controllerConfig=Join-Path $tp1 'config';New-Item -ItemType Directory -Path $controllerConfig -Force|Out-Null
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $controllerConfig 'LOCAL.json') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Operations-Portal.ps1') -Destination $web1 -Force

    Write-Host "`nBrainTrace LocalLab initialized." -ForegroundColor Green
    Write-Host "Six simulated nodes: $nodesRoot"
    Write-Host 'No Scheduled Tasks, services, IIS components, or remote shares were changed.'
}

function Assert-BrainTraceLocalLab {
    if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){throw 'LocalLab is not initialized. Select option 1 first.'}
}

function Start-BrainTraceLocalLabAgents {
    Assert-BrainTraceLocalLab
    if(Test-Path -LiteralPath $stopFile){Remove-Item -LiteralPath $stopFile -Force}
    if(-not(Test-Path -LiteralPath $agentStatusRoot)){New-Item -ItemType Directory -Path $agentStatusRoot -Force|Out-Null}
    $agentScript=Join-Path $PSScriptRoot 'LocalLab-Agent.ps1'
    $specs=@()
    foreach($name in @('TP1','TP2','App1','App2','Web1','Web2')){$specs+=,[pscustomobject]@{Kind='Worker';Node=$name}}
    foreach($name in @('TP1','App1')){$specs+=,[pscustomobject]@{Kind='Monitor';Node=$name}}
    $processes=@()
    foreach($spec in $specs){
        $root=Join-Path $nodesRoot $spec.Node
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -Kind {1} -Node "{2}" -Root "{3}" -StopFile "{4}" -StatusRoot "{5}"' -f $agentScript,$spec.Kind,$spec.Node,$root,$stopFile,$agentStatusRoot
        $processes+=Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    Start-Sleep -Seconds 2
    return $processes
}

function Stop-BrainTraceLocalLabAgents {
    param([object[]]$Processes)
    if(-not(Test-Path -LiteralPath $stopFile)){New-Item -ItemType File -Path $stopFile -Force|Out-Null}
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    foreach($process in @($Processes)){
        while(-not$process.HasExited-and[datetime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 200;$process.Refresh()}
        if(-not$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
        $process.Dispose()
    }
}

function Invoke-BrainTraceWithLocalLabAgents {
    param([Parameter(Mandatory=$true)][scriptblock]$Operation)
    $agents=@(Start-BrainTraceLocalLabAgents)
    try{& $Operation}finally{Stop-BrainTraceLocalLabAgents $agents}
}

function Invoke-BrainTraceLocalLabAction {
    param([string]$Selected)
    $controller=Join-Path (Join-Path $nodesRoot 'TP1') 'BrainTrace.ps1'
    switch($Selected){
        'Initialize' {Initialize-BrainTraceLocalLab}
        'Reset' {Remove-BrainTraceLocalLab;Write-Host 'BrainTrace LocalLab removed. Production files were not touched.' -ForegroundColor Green}
        'Diagnose' {Assert-BrainTraceLocalLab;Invoke-BrainTraceWithLocalLabAgents {& $controller Diagnose -Environment LOCAL}}
        'Test' {Assert-BrainTraceLocalLab;Invoke-BrainTraceWithLocalLabAgents {& $controller Test -Environment LOCAL}}
        'PrepareDryRun' {Assert-BrainTraceLocalLab;& $controller Prepare -Environment LOCAL -DryRun}
        'Portal' {
            Assert-BrainTraceLocalLab
            $portal=Join-Path (Join-Path $nodesRoot 'Web1') 'Operations-Portal.ps1'
            Invoke-BrainTraceWithLocalLabAgents {& $portal}
        }
        default {throw "Unknown LocalLab action '$Selected'."}
    }
}

if($Action-ne'Menu'){Invoke-BrainTraceLocalLabAction $Action;return}

while($true){
    Write-Host "`nBrainTrace LocalLab" -ForegroundColor Cyan
    Write-Host '1  Initialize or reset the six-node lab'
    Write-Host '2  Diagnose simulated environment'
    Write-Host '3  Test Workers, relay, and collection access'
    Write-Host '4  Open Web1 Operations portal'
    Write-Host '5  Preview Prepare (DryRun)'
    Write-Host '6  Open LocalLab folder'
    Write-Host 'Q  Quit'
    $choice=Read-Host 'Select'
    try{
        switch($choice.ToUpperInvariant()){
            '1' {Invoke-BrainTraceLocalLabAction Initialize}
            '2' {Invoke-BrainTraceLocalLabAction Diagnose}
            '3' {Invoke-BrainTraceLocalLabAction Test}
            '4' {Invoke-BrainTraceLocalLabAction Portal}
            '5' {Invoke-BrainTraceLocalLabAction PrepareDryRun}
            '6' {Assert-BrainTraceLocalLab;Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$labRoot+'"')|Out-Null}
            'Q' {return}
            default {Write-Host 'Unknown selection.' -ForegroundColor Yellow}
        }
    }catch{Write-Host ("ERROR: "+$_.Exception.Message) -ForegroundColor Red}
}
