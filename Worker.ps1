[CmdletBinding()]
param(
    [string]$Root = 'D:\BrainTrace',
    [string]$ConfigPath = (Join-Path $Root 'NodeConfig.json'),
    [switch]$DryRun,
    [int]$MaxCommands = 20
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrainTrace.Common.ps1')

function Stop-BrainTraceIIS { param([switch]$WhatIf) if($WhatIf){return};Stop-Service -Name W3SVC -Force -ErrorAction Stop }
function Start-BrainTraceIIS { param([switch]$WhatIf) if($WhatIf){return};Start-Service -Name W3SVC -ErrorAction Stop }
function Stop-BrainTraceService { param([string]$Name,[switch]$WhatIf) if($WhatIf){return};Stop-Service -Name $Name -Force -ErrorAction Stop }
function Start-BrainTraceService { param([string]$Name,[switch]$WhatIf) if($WhatIf){return};Start-Service -Name $Name -ErrorAction Stop }
function Stop-BrainTraceAppPool {
    param([string]$Name,[switch]$WhatIf)
    if($WhatIf){return};Import-Module WebAdministration -ErrorAction Stop
    Stop-WebAppPool -Name $Name -ErrorAction Stop
}
function Start-BrainTraceAppPool {
    param([string]$Name,[switch]$WhatIf)
    if($WhatIf){return};Import-Module WebAdministration -ErrorAction Stop
    Start-WebAppPool -Name $Name -ErrorAction Stop
}

function Test-BrainTraceCleanupPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)-or-not[IO.Path]::IsPathRooted($Path)){throw "Unsafe cleanup path: '$Path'."}
    if($Path.IndexOfAny([char[]]'*?')-ge0){throw "Wildcards are not allowed in cleanup path '$Path'."}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root=[IO.Path]::GetPathRoot($full).TrimEnd('\')
    if($full-ieq$root-or$full.Length-lt12){throw "Cleanup path is too broad: '$full'."}
    if($full-ieq$env:windir-or$full.StartsWith($env:windir+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Windows path cannot be cleaned: '$full'."}
    return $full
}

function Invoke-BrainTraceComponents {
    param($Node,[string]$Action,$Config,[switch]$WhatIf)
    $order=if($Action-eq'STOP'){@($Config.StopOrder)}else{@($Config.StartOrder)}
    $performed=@()
    foreach($group in $order){
        switch($group){
            'Services' { foreach($service in @($Node.Components.Services)){if($Action-eq'STOP'){Stop-BrainTraceService $service -WhatIf:$WhatIf}else{Start-BrainTraceService $service -WhatIf:$WhatIf};$performed+="Service:$service"} }
            'AppPools' { foreach($pool in @($Node.Components.AppPools)){if($Action-eq'STOP'){Stop-BrainTraceAppPool $pool -WhatIf:$WhatIf}else{Start-BrainTraceAppPool $pool -WhatIf:$WhatIf};$performed+="AppPool:$pool"} }
            'IIS' { if([bool]$Node.Components.ManageIIS){if($Action-eq'STOP'){Stop-BrainTraceIIS -WhatIf:$WhatIf}else{Start-BrainTraceIIS -WhatIf:$WhatIf};$performed+='IIS:W3SVC'} }
            default { throw "Unknown component order group '$group'." }
        }
    }
    return $performed
}

function Invoke-BrainTraceClean {
    param($Node,[switch]$WhatIf)
    $cleaned=@()
    foreach($log in @($Node.Logs)){
        $path=Test-BrainTraceCleanupPath ([string]$log.LocalPath)
        if(-not(Test-Path -LiteralPath $path -PathType Container)){throw "Configured log path does not exist: $path"}
        $items=@(Get-ChildItem -LiteralPath $path -Force)
        if(-not$WhatIf){$items|Remove-Item -Recurse -Force -ErrorAction Stop}
        $cleaned+="$($log.Id):$path ($($items.Count) item(s))"
    }
    return $cleaned
}

function Invoke-BrainTraceCopy {
    param([string]$Source,[string]$Destination,[string]$LogPath,[switch]$WhatIf)
    if($WhatIf){return [pscustomobject]@{Success=$true;Message="DRYRUN robocopy '$Source' -> '$Destination'"}}
    if(-not(Test-Path -LiteralPath $Destination)){New-Item -ItemType Directory -Path $Destination -Force|Out-Null}
    $arguments=@($Source,$Destination,'/E','/R:1','/W:1','/NP','/TEE',('/LOG+:'+$LogPath))
    & robocopy.exe @arguments|Out-Null;$result=Get-BrainTraceRobocopyResult $LASTEXITCODE
    [pscustomobject]@{Success=$result.Success;Message="Robocopy exit $($result.ExitCode)$(if($result.Warning){' (nonfatal warning)'}else{''})"}
}

function Invoke-BrainTraceCollect {
    param($Command,$Config,$LocalNode,[string]$LogPath,[switch]$WhatIf)
    $sourceNode=Get-BrainTraceNode $Config ([string]$Command.SourceNode)
    if($null-eq$sourceNode){throw "Unknown SourceNode '$($Command.SourceNode)'."}
    if($sourceNode.CollectBy-ine$LocalNode.Name){throw "'$($LocalNode.Name)' is not configured to collect '$($sourceNode.Name)'."}
    $messages=@()
    $multiple=@($sourceNode.Logs).Count-gt1
    foreach($log in @($sourceNode.Logs)){
        $source=if($sourceNode.Name-ieq$LocalNode.Name){[string]$log.LocalPath}else{[string]$log.UNCPath}
        $base=if($Config.Aggregator-ieq$LocalNode.Name){[string]$Config.StagingRoot}else{[string]$Config.StagingRootUNC}
        $destination=Join-Path (Join-Path $base $Command.RunId) $sourceNode.Name
        if($multiple){$destination=Join-Path $destination $log.Id}
        $copy=Invoke-BrainTraceCopy $source $destination $LogPath -WhatIf:$WhatIf
        if(-not$copy.Success){throw $copy.Message};$messages+="$source -> $destination [$($copy.Message)]"
    }
    return $messages
}

function Invoke-BrainTraceBundle {
    param($Command,$Config,$LocalNode,[switch]$WhatIf)
    if($LocalNode.Name-ine$Config.Aggregator){throw 'BUNDLE may run only on the configured Aggregator.'}
    $safeName=ConvertTo-BrainTraceSafeName ([string]$Command.Name);$source=Join-Path $Config.StagingRoot $Command.RunId
    $zip=Join-Path $Config.StagingRoot ($safeName+'_'+$Command.RunId+'.zip')
    if($WhatIf){return "Compress '$source' -> '$zip'"}
    if(-not(Test-Path -LiteralPath $source)){throw "Staging path does not exist: $source"}
    Compress-Archive -LiteralPath $source -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
    $destination=$Config.BundleDestination
    if($null-ne$destination-and-not[string]::IsNullOrWhiteSpace([string]$destination.Path)){
        if(-not(Test-Path -LiteralPath $destination.Path)){New-Item -ItemType Directory -Path $destination.Path -Force|Out-Null}
        $final=Join-Path $destination.Path (Split-Path -Leaf $zip);Copy-Item -LiteralPath $zip -Destination $final -ErrorAction Stop
        if((Get-Item $zip).Length-ne(Get-Item $final).Length){throw 'Final ZIP size verification failed.'};return $final
    }
    return $zip
}

function Wait-BrainTraceStatus {
    param([string]$Path,[datetime]$Deadline,[int]$PollSeconds)
    while([datetime]::UtcNow-lt$Deadline){if(Test-Path -LiteralPath $Path){return Read-BrainTraceJson $Path};Start-Sleep -Seconds $PollSeconds}
    return $null
}

function Invoke-BrainTraceRelay {
    param($Command,$Config,$LocalNode,[string]$Root)
    $target=Get-BrainTraceNode $Config $Command.TargetNode
    if($null-eq$target-or$target.CommandAccess-ne'Via'-or$target.CommandVia-ine$LocalNode.Name){throw "Relay is not authorized for '$($Command.TargetNode)'."}
    $targetCommand=Join-Path (Join-Path $target.CommandRoot 'Commands') ((Split-Path -Leaf $script:CurrentCommandPath))
    Write-BrainTraceJsonAtomic $Command $targetCommand
    $statusName="$($Command.RunId)_$($Command.CommandId).status.json"
    $targetStatus=Join-Path (Join-Path $target.CommandRoot 'Status') $statusName
    $status=Wait-BrainTraceStatus $targetStatus ([datetime]$Command.ExpiresUtc) ([int]$Config.PollSeconds)
    if($null-eq$status){throw "Timed out waiting for relayed status from '$($Command.TargetNode)'."}
    Write-BrainTraceJsonAtomic $status (Join-Path (Join-Path $Root 'Status') $statusName)
    return "Relayed $($Command.Action) to $($Command.TargetNode)."
}

$installed=Read-BrainTraceJson $ConfigPath
$config=$installed.EnvironmentConfig;[void](Test-BrainTraceEnvironment $config)
$localNode=Get-BrainTraceNode $config ([string]$installed.LocalNode)
if($null-eq$localNode){throw "LocalNode '$($installed.LocalNode)' is not in configuration."}
foreach($folder in @('Commands','Status','Archive','Logs')){$path=Join-Path $Root $folder;if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}}
$processed=0
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Root 'Commands') -File -Filter '*.command.json'|Sort-Object Name|Select-Object -First $MaxCommands)){
    $script:CurrentCommandPath=$file.FullName;$command=$null;$success=$false;$message=''
    try{
        $command=Read-BrainTraceJson $file.FullName
        if($command.Environment-ine$config.Environment){throw 'Command Environment mismatch.'}
        if($command.Action-notin@('STOP','CLEAN','START','COLLECT','BUNDLE')){throw "Unsupported action '$($command.Action)'."}
        if(([datetime]$command.ExpiresUtc)-le[datetime]::UtcNow){throw 'Command is expired.'}
        if($command.TargetNode-ine$localNode.Name){$message=Invoke-BrainTraceRelay $command $config $localNode $Root}
        else{
            $workerLog=Join-Path (Join-Path $Root 'Logs') ($command.RunId+'.log')
            switch($command.Action){
                'STOP' {$message=(Invoke-BrainTraceComponents $localNode STOP $config -WhatIf:$DryRun)-join'; '}
                'START' {$message=(Invoke-BrainTraceComponents $localNode START $config -WhatIf:$DryRun)-join'; '}
                'CLEAN' {$message=(Invoke-BrainTraceClean $localNode -WhatIf:$DryRun)-join'; '}
                'COLLECT' {$message=(Invoke-BrainTraceCollect $command $config $localNode $workerLog -WhatIf:$DryRun)-join'; '}
                'BUNDLE' {$message=Invoke-BrainTraceBundle $command $config $localNode -WhatIf:$DryRun}
            }
        }
        $success=$true
    }catch{$message=$_.Exception.Message}
    $nodeName=if($null-ne$command){[string]$command.TargetNode}else{$localNode.Name};$action=if($null-ne$command){[string]$command.Action}else{'UNKNOWN'};$run=if($null-ne$command){[string]$command.RunId}else{'unknown'}
    if($null-ne$command-and($command.TargetNode-ieq$localNode.Name-or-not$success)){
        $statusNode=if($command.TargetNode-ieq$localNode.Name){$localNode.Name}else{$command.TargetNode}
        $status=[ordered]@{RunId=$run;CommandId=$command.CommandId;Environment=$config.Environment;Node=$statusNode;Action=$action;Success=$success;Message=$message;TimestampUtc=[datetime]::UtcNow.ToString('o')}
        Write-BrainTraceJsonAtomic $status (Join-Path (Join-Path $Root 'Status') ("$run`_$($command.CommandId).status.json"))
    }
    Write-BrainTraceLog (Join-Path (Join-Path $Root 'Logs') 'Worker.jsonl') $run $config.Environment $nodeName $action $success $message
    Move-Item -LiteralPath $file.FullName -Destination (Join-Path (Join-Path $Root 'Archive') $file.Name) -Force
    [pscustomobject]@{RunId=$run;Node=$nodeName;Action=$action;Success=$success;Message=$message};$processed++
}
