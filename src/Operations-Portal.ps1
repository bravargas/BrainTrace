[CmdletBinding()]
param([string]$Root,[string]$ConfigPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Root)){$Root=$PSScriptRoot}
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $Root 'NodeConfig.json'}
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')

function Wait-BrainTracePortalResult {
    param([string]$Path,[datetime]$Deadline,[string]$RequestId)
    $started=[datetime]::UtcNow;$nextNotice=$started
    while([datetime]::UtcNow-lt$Deadline.ToUniversalTime()){
        if(Test-Path -LiteralPath $Path){return Read-BrainTraceJson $Path}
        if([datetime]::UtcNow-ge$nextNotice){
            $elapsed=[math]::Round(([datetime]::UtcNow-$started).TotalSeconds)
            Write-Host "Waiting for $RequestId through Web1 -> App1 -> TP1... ${elapsed}s"
            $nextNotice=[datetime]::UtcNow.AddSeconds(30)
        }
        Start-Sleep -Seconds 5
    }
    return $null
}

function Submit-BrainTracePortalRequest {
    param($Config,[string]$Operation,[string]$Name,[bool]$DryRun,[bool]$Confirmed)
    $hub=[string]$Config.Operations.HubRoot
    foreach($folder in @('Requests','Results','Archive','Logs')){$path=Join-Path $hub $folder;if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}}
    $id=([datetime]::Now.ToString('yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $expires=[datetime]::UtcNow.AddMinutes([int]$Config.Operations.RequestTimeoutMinutes)
    $request=[ordered]@{
        RequestId=$id;Environment=$Config.Environment;Operation=$Operation;Name=if($Name){$Name}else{$null}
        DryRun=$DryRun;Confirmed=$Confirmed;RequestedBy=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        CreatedUtc=[datetime]::UtcNow.ToString('o');ExpiresUtc=$expires.ToString('o')
    }
    Write-BrainTraceJsonAtomic $request (Join-Path (Join-Path $hub 'Requests') ($id+'.request.json'))
    Write-Host "`nRequest published: $id"
    $result=Wait-BrainTracePortalResult (Join-Path (Join-Path $hub 'Results') ($id+'.result.json')) $expires $id
    if($null-eq$result){Write-Host "TIMEOUT: no result reached Web1 before $($expires.ToLocalTime())." -ForegroundColor Red;return}
    $color=if($result.Success){'Green'}else{'Red'}
    Write-Host "`n$($result.Operation): $(if($result.Success){'SUCCESS'}else{'FAILED'})" -ForegroundColor $color
    Write-Host "Executor: $($result.Executor)`nStarted: $($result.StartedUtc)`nCompleted: $($result.CompletedUtc)`n"
    Write-Host ([string]$result.Message)
}

$installed=Read-BrainTraceJson $ConfigPath
$config=$installed.EnvironmentConfig;[void](Test-BrainTraceEnvironment $config)
$localNode=Get-BrainTraceNode $config ([string]$installed.LocalNode)
if($null-eq(Get-BrainTraceProperty $config Operations $null)){throw 'Operations topology is not configured.'}
if($localNode.Name-ine$config.Operations.Hub){throw "Operations Portal may run only on configured hub '$($config.Operations.Hub)'."}

while($true){
    Write-Host "`nBrainTrace Operations - DEV (Web1)" -ForegroundColor Cyan
    Write-Host '1  Diagnose environment'
    Write-Host '2  Test Workers and collection access'
    Write-Host '3  Collect logs'
    Write-Host '4  Preview Prepare (DryRun)'
    Write-Host '5  LIVE Prepare (STOP, CLEAN, START)'
    Write-Host 'Q  Quit'
    $choice=Read-Host 'Select'
    switch($choice.ToUpperInvariant()){
        '1' {Submit-BrainTracePortalRequest $config Diagnose $null $false $true}
        '2' {Submit-BrainTracePortalRequest $config Test $null $false $true}
        '3' {$name=Read-Host 'Collection name';if(-not[string]::IsNullOrWhiteSpace($name)){Submit-BrainTracePortalRequest $config Collect $name $false $true}}
        '4' {Submit-BrainTracePortalRequest $config Prepare $null $true $true}
        '5' {
            Write-Host 'WARNING: this stops every configured component and cleans logs only after every STOP succeeds.' -ForegroundColor Yellow
            if((Read-Host 'Type PREPARE to continue')-ceq'PREPARE'){Submit-BrainTracePortalRequest $config Prepare $null $false $true}else{Write-Host 'Cancelled.'}
        }
        'Q' {return}
        default {Write-Host 'Unknown selection.'}
    }
}
