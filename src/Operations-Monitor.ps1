[CmdletBinding()]
param(
    [string]$Root,
    [string]$ConfigPath,
    [ValidateRange(1,20)][int]$MaxRequests=3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Root)){$Root=$PSScriptRoot}
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $Root 'NodeConfig.json'}
trap {
    try{
        $logDirectory=Join-Path $Root 'Logs';if(-not(Test-Path -LiteralPath $logDirectory)){New-Item -ItemType Directory -Path $logDirectory -Force|Out-Null}
        $record=[ordered]@{TimestampUtc=[datetime]::UtcNow.ToString('o');Error=$_.Exception.Message;Root=$Root}
        [IO.File]::AppendAllText((Join-Path $logDirectory 'Operations-Monitor-Fatal.jsonl'),(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    }catch{}
    exit 1
}
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')

function Initialize-BrainTraceOperationsFolders {
    param([string]$Base)
    foreach($name in @('Requests','Results','Archive','Logs')){
        $path=Join-Path $Base $name
        if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
    }
}

function Write-BrainTraceOperationsLog {
    param([string]$Base,[string]$Environment,[string]$Node,[string]$Action,[bool]$Success,[string]$Message)
    Write-BrainTraceLog (Join-Path (Join-Path $Base 'Logs') 'Operations-Monitor.jsonl') 'operations' $Environment $Node $Action $Success $Message
}

function Invoke-BrainTraceOperationsRelay {
    param($Config,$LocalNode)
    $operations=$Config.Operations
    $hub=[string]$operations.HubRootUNC;$relay=[string]$operations.RelayRoot
    Initialize-BrainTraceOperationsFolders $hub;Initialize-BrainTraceOperationsFolders $relay

    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $hub 'Requests') -File -Filter '*.request.json'|Sort-Object Name)){
        $relayRequest=Join-Path (Join-Path $relay 'Requests') $file.Name
        $relayArchive=Join-Path (Join-Path $relay 'Archive') $file.Name
        $resultName=$file.Name-replace '\.request\.json$','.result.json'
        if(-not(Test-Path -LiteralPath $relayRequest)-and-not(Test-Path -LiteralPath $relayArchive)-and-not(Test-Path -LiteralPath (Join-Path (Join-Path $hub 'Results') $resultName))){
            Write-BrainTraceJsonAtomic (Read-BrainTraceJson $file.FullName) $relayRequest
        }
    }

    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $relay 'Results') -File -Filter '*.result.json'|Sort-Object Name)){
        $hubResult=Join-Path (Join-Path $hub 'Results') $file.Name
        Write-BrainTraceJsonAtomic (Read-BrainTraceJson $file.FullName) $hubResult
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path (Join-Path $relay 'Archive') $file.Name) -Force
        $requestName=$file.Name-replace '\.result\.json$','.request.json'
        $hubRequest=Join-Path (Join-Path $hub 'Requests') $requestName
        if(Test-Path -LiteralPath $hubRequest){Move-Item -LiteralPath $hubRequest -Destination (Join-Path (Join-Path $hub 'Archive') $requestName) -Force}
    }
    Write-BrainTraceOperationsLog $relay $Config.Environment $LocalNode.Name RELAY $true 'Request/result file relay completed.'
}

function Invoke-BrainTraceOperationsRequest {
    param($Request,$Config,[string]$CliPath)
    if($Request.Environment-ine$Config.Environment){throw 'Request Environment mismatch.'}
    if($Request.Operation-notin@('Diagnose','Test','Prepare','Collect')){throw "Unsupported operation '$($Request.Operation)'."}
    if(([datetime]$Request.ExpiresUtc).ToUniversalTime()-le[datetime]::UtcNow){throw 'Request is expired.'}
    if($Request.Operation-eq'Collect'-and[string]::IsNullOrWhiteSpace([string]$Request.Name)){throw 'Collect requires Name.'}
    if($Request.Operation-eq'Prepare'-and-not[bool]$Request.DryRun-and-not[bool]$Request.Confirmed){throw 'Live Prepare requires explicit confirmation.'}

    $arguments=@([string]$Request.Operation,'-Environment',[string]$Config.Environment)
    if($Request.Operation-eq'Collect'){$arguments+=@('-Name',[string]$Request.Name)}
    if([bool]$Request.DryRun-and$Request.Operation-ne'Diagnose'){$arguments+='-DryRun'}
    $output=(& $CliPath @arguments 6>&1|Out-String).Trim()
    return $output
}

function Invoke-BrainTraceOperationsExecutor {
    param($Config,$LocalNode,[string]$Root,[int]$Limit)
    $relay=[string]$Config.Operations.RelayRootUNC
    Initialize-BrainTraceOperationsFolders $relay
    $cli=Join-Path $Root 'BrainTrace.ps1'
    if(-not(Test-Path -LiteralPath $cli -PathType Leaf)){throw "Controller CLI not found: $cli"}
    $mutex=New-Object Threading.Mutex($false,'Global\BrainTrace-Operations-Monitor')
    if(-not$mutex.WaitOne(0)){return}
    try{
        foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $relay 'Requests') -File -Filter '*.request.json'|Sort-Object Name|Select-Object -First $Limit)){
            $request=$null;$success=$false;$message='';$started=[datetime]::UtcNow
            try{$request=Read-BrainTraceJson $file.FullName;$message=Invoke-BrainTraceOperationsRequest $request $Config $cli;$success=$true}catch{$message=$_.Exception.Message}
            $requestId=if($null-ne$request){[string]$request.RequestId}else{[IO.Path]::GetFileNameWithoutExtension($file.Name)}
            $operation=if($null-ne$request){[string]$request.Operation}else{'UNKNOWN'}
            $result=[ordered]@{
                RequestId=$requestId;Environment=$Config.Environment;Operation=$operation;Success=$success
                StartedUtc=$started.ToString('o');CompletedUtc=[datetime]::UtcNow.ToString('o');Executor=$LocalNode.Name;Message=$message
            }
            Write-BrainTraceJsonAtomic $result (Join-Path (Join-Path $relay 'Results') ($requestId+'.result.json'))
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path (Join-Path $relay 'Archive') $file.Name) -Force
            Write-BrainTraceOperationsLog $relay $Config.Environment $LocalNode.Name $operation $success $message
        }
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}

$installed=Read-BrainTraceJson $ConfigPath
$config=$installed.EnvironmentConfig;[void](Test-BrainTraceEnvironment $config)
$localNode=Get-BrainTraceNode $config ([string]$installed.LocalNode)
$operations=Get-BrainTraceProperty $config Operations $null
if($null-eq$operations){return}

if($localNode.Name-ieq$operations.Relay){Invoke-BrainTraceOperationsRelay $config $localNode}
elseif($localNode.Name-ieq$operations.Executor){Invoke-BrainTraceOperationsExecutor $config $localNode $Root $MaxRequests}
