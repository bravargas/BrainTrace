$script:BTAllowedActions = @('INVENTORY', 'STATE', 'PHASE_OPEN', 'PHASE_CLOSE', 'STOP', 'CLEAN', 'START', 'COLLECT')

function Initialize-BTQueue {
    param([Parameter(Mandatory = $true)][string]$NodeRoot)
    foreach ($name in @('Inbox','Control','Processing','Status','Archive','Rejected','Receipts','Phases','RunSnapshots','Logs')) {
        $path = Join-Path $NodeRoot $name
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
}

function New-BTCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$SourceNode,
        [Parameter(Mandatory = $true)][string]$TargetNode,
        [Parameter(Mandatory = $true)][ValidateSet('INVENTORY','STATE','PHASE_OPEN','PHASE_CLOSE','STOP','CLEAN','START','COLLECT')][string]$Action,
        [string]$ConfigRevision = '', [string]$ExpectedNodeConfigHash = '',
        [string]$PhaseName = '', [int]$PhaseEpoch = 0, [string]$PhaseToken = '',
        [hashtable]$Parameters = @{}, [object]$Route,
        [guid]$CommandId = [guid]::NewGuid(), [datetime]$CreatedUtc = [datetime]::MinValue, [int]$LifetimeSeconds = 300
    )
    if ($CreatedUtc -eq [datetime]::MinValue) { $CreatedUtc = Get-BTUtcNow }
    $phase = $null
    if ($PhaseEpoch -gt 0) { $phase = [ordered]@{ Name = $PhaseName; Epoch = $PhaseEpoch; Token = $PhaseToken } }
    [pscustomobject][ordered]@{
        ProtocolVersion = 1; EnvironmentId = $EnvironmentId; ConfigRevision = $ConfigRevision
        ExpectedNodeConfigHash = $ExpectedNodeConfigHash.ToLowerInvariant(); RunId = $RunId
        CommandId = $CommandId.ToString().ToLowerInvariant(); CreatedUtc = $CreatedUtc.ToUniversalTime().ToString('o')
        ExpiresUtc = $CreatedUtc.ToUniversalTime().AddSeconds($LifetimeSeconds).ToString('o')
        SourceNode = $SourceNode; TargetNode = $TargetNode; Action = $Action; Phase = $phase
        Parameters = [pscustomobject]$Parameters; Route = $Route
    }
}

function Get-BTCommandFileName {
    param($Command, [switch]$Control)
    $suffix = if ($Control) { 'control.json' } else { 'command.json' }
    return '{0}__{1}.{2}' -f $Command.RunId, $Command.CommandId, $suffix
}

function Publish-BTMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Message, [Parameter(Mandatory = $true)][string]$NodeRoot, [switch]$Control)
    Initialize-BTQueue $NodeRoot
    $isControl = $Control -or $Message.Action -in @('PHASE_OPEN','PHASE_CLOSE')
    $folder = if ($isControl) { 'Control' } else { 'Inbox' }
    $path = Join-Path (Join-Path $NodeRoot $folder) (Get-BTCommandFileName $Message -Control:$isControl)
    if (Test-Path -LiteralPath $path) {
        $existing=Import-BTJsonFile $path
        Assert-BT ((Get-BTCommandHash $existing) -eq (Get-BTCommandHash $Message)) 'Published CommandId collision.' 'BrainTrace.Protocol.CommandCollision'
        return $path
    }
    Write-BTJsonAtomic -InputObject $Message -Path $path | Out-Null
    return $path
}

function Claim-BTMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NodeRoot, [switch]$ControlOnly)
    Initialize-BTQueue $NodeRoot
    $sources = if ($ControlOnly) { @('Control') } else { @('Control','Inbox') }
    foreach ($source in $sources) {
        $candidates = @(Get-ChildItem -LiteralPath (Join-Path $NodeRoot $source) -File -Filter '*.json')
        if ($source -eq 'Control') {
            $candidates = @($candidates | Sort-Object @{ Expression = {
                try { if ((Import-BTJsonFile $_.FullName).Action -eq 'PHASE_CLOSE') { 0 } else { 1 } } catch { 0 }
            } }, Name)
        }
        else { $candidates = @($candidates | Sort-Object Name) }
        $candidate = $candidates | Select-Object -First 1
        if ($null -eq $candidate) { continue }
        $target = Join-Path (Join-Path $NodeRoot 'Processing') $candidate.Name
        try { [IO.File]::Move($candidate.FullName, $target); return $target } catch [IO.IOException] { continue }
    }
    return $null
}

function Test-BTCommand {
    param($Command, [string]$NodeName, [string]$EnvironmentId, [switch]$AllowExpiredClose)
    foreach ($field in @('ProtocolVersion','EnvironmentId','RunId','CommandId','CreatedUtc','ExpiresUtc','SourceNode','TargetNode','Action')) {
        if (-not $Command.PSObject.Properties[$field]) { throw "Command field '$field' is required." }
    }
    $allowedFields=@('ProtocolVersion','EnvironmentId','ConfigRevision','ExpectedNodeConfigHash','RunId','CommandId','CreatedUtc','ExpiresUtc','SourceNode','TargetNode','Action','Phase','Parameters','Route')
    foreach($property in $Command.PSObject.Properties){Assert-BT ($allowedFields-contains$property.Name) "Unknown command field '$($property.Name)'." 'BrainTrace.Protocol.Field'}
    Assert-BT ($Command.ProtocolVersion -eq 1) 'Unsupported ProtocolVersion.' 'BrainTrace.Protocol.Version'
    Assert-BT ($script:BTAllowedActions -contains [string]$Command.Action) "Unknown action '$($Command.Action)'." 'BrainTrace.Protocol.Action'
    Assert-BT ($Command.EnvironmentId -ieq $EnvironmentId) 'Command EnvironmentId mismatch.' 'BrainTrace.Protocol.Environment'
    Assert-BT ($Command.TargetNode -ieq $NodeName) 'Command TargetNode mismatch.' 'BrainTrace.Protocol.Target'
    $parsedGuid = [guid]::Empty
    Assert-BT ([guid]::TryParse([string]$Command.CommandId, [ref]$parsedGuid)) 'Invalid CommandId.' 'BrainTrace.Protocol.CommandId'
    $created = [datetime]::MinValue;$expires = [datetime]::MinValue
    Assert-BT ([datetime]::TryParse([string]$Command.CreatedUtc, [ref]$created)) 'Invalid CreatedUtc.' 'BrainTrace.Protocol.Expiration'
    Assert-BT ([datetime]::TryParse([string]$Command.ExpiresUtc, [ref]$expires)) 'Invalid ExpiresUtc.' 'BrainTrace.Protocol.Expiration'
    Assert-BT ($created.ToUniversalTime() -lt $expires.ToUniversalTime()) 'CreatedUtc must precede ExpiresUtc.' 'BrainTrace.Protocol.Expiration'
    Assert-BT (($expires.ToUniversalTime()-$created.ToUniversalTime()).TotalHours -le 24) 'Command lifetime exceeds the protocol maximum.' 'BrainTrace.Protocol.Expiration'
    if (-not ($AllowExpiredClose -and $Command.Action -eq 'PHASE_CLOSE')) { Assert-BT ($expires.ToUniversalTime() -gt (Get-BTUtcNow)) 'Command is expired.' 'BrainTrace.Protocol.Expired' }
    if ($Command.Action -in @('PHASE_OPEN','PHASE_CLOSE','STOP','CLEAN','START','COLLECT')) {
        Assert-BT ($null -ne $Command.Phase -and $Command.Phase.Epoch -gt 0) 'Mutation phase identity is required.' 'BrainTrace.Protocol.Phase'
    }
    $parameterNames = @($Command.Parameters.PSObject.Properties | ForEach-Object { $_.Name })
    if ($Command.Action -in @('STOP','CLEAN','START','COLLECT')) {
        if ($Command.Action -eq 'COLLECT') {
            foreach ($name in $parameterNames) { Assert-BT ($name -in @('CollectionRouteId','StepOrder')) "COLLECT parameter '$name' is not allowed." 'BrainTrace.Protocol.Parameter' }
        } else { Assert-BT ($parameterNames.Count -eq 0) "$($Command.Action) cannot contain parameters." 'BrainTrace.Protocol.Parameter' }
    }
    else { Assert-BT ($parameterNames.Count -eq 0) "$($Command.Action) cannot contain parameters." 'BrainTrace.Protocol.Parameter' }
    return $true
}

function Get-BTCommandHash {
    param($Command)
    Get-BTSha256Hex (ConvertTo-BTCanonicalJsonValue $Command)
}

function Get-BTReceiptPath {
    param([string]$NodeRoot, [string]$CommandId)
    Join-Path (Join-Path $NodeRoot 'Receipts') ($CommandId.ToLowerInvariant() + '.receipt.json')
}

function Read-BTReceipt {
    param([string]$NodeRoot, [string]$CommandId)
    $path = Get-BTReceiptPath $NodeRoot $CommandId
    if (Test-Path -LiteralPath $path) { return Import-BTJsonFile $path }
    return $null
}

function Write-BTReceipt {
    param([string]$NodeRoot, $Receipt)
    $path = Get-BTReceiptPath $NodeRoot $Receipt.CommandId
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    Write-BTJsonAtomic $Receipt $path | Out-Null
}

function Publish-BTStatus {
    param([string]$NodeRoot, $Status)
    $path = Join-Path (Join-Path $NodeRoot 'Status') ('{0}__{1}.status.json' -f $Status.RunId, $Status.CommandId)
    if (Test-Path -LiteralPath $path) { return $path }
    Write-BTJsonAtomic $Status $path | Out-Null
    return $path
}

function Move-BTProcessedMessage {
    param([string]$NodeRoot, [string]$ProcessingPath, [switch]$Rejected)
    $folder = if ($Rejected) { 'Rejected' } else { 'Archive' }
    $target = Join-Path (Join-Path $NodeRoot $folder) ([IO.Path]::GetFileName($ProcessingPath))
    if (Test-Path -LiteralPath $target) { $target = $target + '.' + [guid]::NewGuid().ToString('N') }
    [IO.File]::Move($ProcessingPath, $target)
}
