function Get-BTPhasePath {
    param([string]$NodeRoot, [string]$RunId, [string]$PhaseName)
    Join-Path (Join-Path $NodeRoot 'Phases') (('{0}__{1}.phase.json' -f $RunId, $PhaseName).ToLowerInvariant())
}

function Get-BTPhaseRecord {
    param([string]$NodeRoot, [string]$RunId, [string]$PhaseName)
    $path = Get-BTPhasePath $NodeRoot $RunId $PhaseName
    if (Test-Path -LiteralPath $path) { return Import-BTJsonFile $path }
    return $null
}

function Set-BTPhaseRecord {
    param([string]$NodeRoot, $Record)
    $path = Get-BTPhasePath $NodeRoot $Record.RunId $Record.PhaseName
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    Write-BTJsonAtomic $Record $path | Out-Null
}

function Open-BTPhase {
    [CmdletBinding()]
    param([string]$NodeRoot, [string]$RunId, [string]$PhaseName, [int]$Epoch, [string]$Token, [string]$ConfigHash)
    $existing = Get-BTPhaseRecord $NodeRoot $RunId $PhaseName
    if ($null -ne $existing) {
        if ($Epoch -lt $existing.Epoch -or ($Epoch -eq $existing.Epoch -and $existing.State -eq 'Closed')) { throw "Phase '$PhaseName' epoch $Epoch is fenced closed or stale." }
        if ($Epoch -eq $existing.Epoch -and $existing.Token -ne $Token) { throw "Phase token collision for '$PhaseName' epoch $Epoch." }
    }
    $record = [pscustomobject][ordered]@{RunId=$RunId;PhaseName=$PhaseName;Epoch=$Epoch;Token=$Token;ConfigHash=$ConfigHash;State='Open';UpdatedUtc=(Get-BTUtcNow).ToString('o')}
    Set-BTPhaseRecord $NodeRoot $record
    return $record
}

function Get-BTObservedState {
    param([string]$NodeRoot, $NodeConfig)
    $path = Join-Path $NodeRoot 'State.json'
    $state = if (Test-Path -LiteralPath $path) { Import-BTJsonFile $path } else { [pscustomobject]@{} }
    @($NodeConfig.Node.Components | ForEach-Object {
        $key = Get-BTComponentKey $_
        $property = $state.PSObject.Properties[$key]
        [pscustomobject]@{Id=$_.Id;PhysicalIdentity=$key;State=if ($null -ne $property){[string]$property.Value}else{'Unknown'}}
    })
}

function Close-BTPhase {
    [CmdletBinding()]
    param([string]$NodeRoot, [string]$RunId, [string]$PhaseName, [int]$Epoch, [string]$Token, [string]$ConfigHash, $NodeConfig)
    Initialize-BTQueue $NodeRoot
    $existing = Get-BTPhaseRecord $NodeRoot $RunId $PhaseName
    if ($null -eq $existing) {
        $record = [pscustomobject][ordered]@{RunId=$RunId;PhaseName=$PhaseName;Epoch=$Epoch;Token=$Token;ConfigHash=$ConfigHash;State='Closed';UpdatedUtc=(Get-BTUtcNow).ToString('o')}
        Set-BTPhaseRecord $NodeRoot $record
        return [pscustomobject]@{Disposition='NOT_SEEN';Commands=@();ObservedComponents=(Get-BTObservedState $NodeRoot $NodeConfig);IndeterminateLogSources=@()}
    }
    Assert-BT ($existing.Epoch -eq $Epoch -and $existing.Token -eq $Token) 'PHASE_CLOSE identity does not match persisted phase.'
    $existing.State='Closed'; $existing.UpdatedUtc=(Get-BTUtcNow).ToString('o'); Set-BTPhaseRecord $NodeRoot $existing
    $closeFault=Get-BTSimulationFault $NodeRoot 'PHASE_CLOSE'
    if($null-ne$closeFault -and $closeFault.Mode -eq 'CrashAfterFence'){throw 'Simulated PHASE_CLOSE crash after durable fence.'}
    $dispositions = @()
    foreach ($folder in @('Inbox','Processing')) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $NodeRoot $folder) -File -Filter '*.json')) {
            try { $command = Import-BTJsonFile $file.FullName } catch { continue }
            if ($command.RunId -ne $RunId -or $null -eq $command.Phase -or $command.Phase.Name -ne $PhaseName -or $command.Phase.Epoch -ne $Epoch) { continue }
            if ($command.Action -in @('PHASE_OPEN','PHASE_CLOSE')) { continue }
            $receipt = Read-BTReceipt $NodeRoot $command.CommandId
            $disposition = 'NOT_EXECUTED'
            if ($null -ne $receipt) {
                if ($receipt.State -eq 'TERMINAL') { $disposition = 'EXECUTED' }
                elseif ($receipt.State -eq 'EFFECT_APPLIED') { $disposition = 'EXECUTED_STATUS_LOST' }
                elseif ($receipt.State -eq 'EXECUTING') { $disposition = if ($command.Action -eq 'CLEAN') {'INDETERMINATE'} else {'EXECUTED_STATUS_LOST'} }
                $receipt.State='TERMINAL';$receipt.Disposition=$disposition;$receipt|Add-Member -NotePropertyName CompletedUtc -NotePropertyValue ((Get-BTUtcNow).ToString('o')) -Force;Write-BTReceipt $NodeRoot $receipt
            }
            else {
                $receipt=[pscustomobject][ordered]@{CommandId=$command.CommandId;CommandHash=(Get-BTCommandHash $command);RunId=$command.RunId;Action=$command.Action;PhaseName=$command.Phase.Name;PhaseEpoch=$command.Phase.Epoch;State='TERMINAL';Disposition='NOT_EXECUTED';ConfigHash=$ConfigHash;CreatedUtc=(Get-BTUtcNow).ToString('o');CompletedUtc=(Get-BTUtcNow).ToString('o');EffectResult=$null;Status=$null}
                Write-BTReceipt $NodeRoot $receipt
            }
            $dispositions += [pscustomobject]@{CommandId=$command.CommandId;Disposition=$disposition}
            if (Test-Path -LiteralPath $file.FullName) { Move-BTProcessedMessage $NodeRoot $file.FullName }
        }
    }
    foreach ($receiptFile in @(Get-ChildItem -LiteralPath (Join-Path $NodeRoot 'Receipts') -File -Filter '*.json')) {
        $receipt = Import-BTJsonFile $receiptFile.FullName
        $disposedIds = @($dispositions | ForEach-Object { $_.CommandId })
        if ($receipt.RunId -eq $RunId -and $receipt.PhaseName -eq $PhaseName -and $receipt.PhaseEpoch -eq $Epoch -and $receipt.Action -notin @('PHASE_OPEN','PHASE_CLOSE') -and -not ($disposedIds -contains $receipt.CommandId)) {
            $disposition = if ($receipt.State -eq 'TERMINAL') {$receipt.Disposition} elseif ($receipt.State -eq 'EFFECT_APPLIED') {'EXECUTED_STATUS_LOST'} elseif ($receipt.State -eq 'EXECUTING' -and $receipt.Action -eq 'CLEAN') {'INDETERMINATE'} elseif ($receipt.State -eq 'EXECUTING') {'EXECUTED_STATUS_LOST'} else {'NOT_EXECUTED'}
            $dispositions += [pscustomobject]@{CommandId=$receipt.CommandId;Disposition=$disposition}
        }
    }
    $indeterminate = @($dispositions | Where-Object Disposition -EQ 'INDETERMINATE')
    [pscustomobject]@{Disposition=if($indeterminate.Count){'INDETERMINATE'}else{'RECONCILED'};Commands=$dispositions;ObservedComponents=(Get-BTObservedState $NodeRoot $NodeConfig);IndeterminateLogSources=@($indeterminate | ForEach-Object CommandId)}
}

function Invoke-BTSimulationMutation {
    param([string]$Action, $NodeConfig, [string]$NodeRoot, [string]$SimulationRoot, $Command)
    $fault = Get-BTSimulationFault $NodeRoot $Action
    if ($null -ne $fault -and $fault.Mode -eq 'Exception') { throw "Simulated $Action exception." }
    if ($null -ne $fault -and $null-ne$fault.PSObject.Properties['DelayMs'] -and $fault.DelayMs -gt 0) { Invoke-BTDelay -Milliseconds ([int]$fault.DelayMs) }
    if ($null -ne $fault -and $fault.Mode -eq 'Timeout') { throw "Simulated $Action timeout." }
    if ($Action -in @('STOP','START')) {
        $path = Join-Path $NodeRoot 'State.json'; $state = Import-BTJsonFile $path
        $snapshotPath=Join-Path (Join-Path $NodeRoot 'RunSnapshots') ($Command.RunId+'.json')
        $snapshot=if(Test-Path -LiteralPath $snapshotPath){Import-BTJsonFile $snapshotPath}else{$null}
        $ordered = if ($Action -eq 'STOP') { @($NodeConfig.Node.Components | Sort-Object StopOrder, Id) } else { @($NodeConfig.Node.Components | Sort-Object StartOrder, Id) }
        $details = @()
        foreach ($component in $ordered) {
            $phase = Get-BTPhaseRecord $NodeRoot $Command.RunId $Command.Phase.Name
            Assert-BT ($phase.State -eq 'Open' -and $phase.Epoch -eq $Command.Phase.Epoch -and $phase.Token -eq $Command.Phase.Token) 'Phase closed before physical effect.' 'BrainTrace.Phase.Closed'
            Assert-BT ((Get-BTNodeConfigHash $NodeConfig) -eq $Command.ExpectedNodeConfigHash) 'ConfigHash drift before physical effect.' 'BrainTrace.ConfigHash.Drift'
            $key=Get-BTComponentKey $component; $old=[string]$state.PSObject.Properties[$key].Value
            if($Action-eq'STOP'){$desired='Stopped'}elseif($Command.Phase.Name-eq'ROLLBACK_START' -and $null-ne$snapshot -and $null-ne$snapshot.PSObject.Properties[$key]){$desired=[string]$snapshot.PSObject.Properties[$key].Value}else{$desired='Running'}
            $state.PSObject.Properties[$key].Value=$desired
            $details += [pscustomobject]@{Id=$component.Id;PhysicalIdentity=$key;InitialState=$old;FinalState=$desired;ChangedByRun=($old -ne $desired);Result='SUCCESS'}
        }
        if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }; Write-BTJsonAtomic $state $path | Out-Null
        return [pscustomobject]@{Result='SUCCESS';Components=$details;Fault=$fault}
    }
    if ($Action -eq 'CLEAN') {
        $stopFence=Get-BTPhaseRecord $NodeRoot $Command.RunId 'STOP'
        Assert-BT ($null-ne$stopFence -and $stopFence.State-eq'Closed') 'CLEAN requires a closed STOP authorization for the same RunId.' 'BrainTrace.Barrier.StopRequired'
        $root = Get-BTCanonicalPath $SimulationRoot; $cleaned=@()
        foreach ($source in @($NodeConfig.Node.LogSources | Where-Object CleanupEnabled)) {
            $phase = Get-BTPhaseRecord $NodeRoot $Command.RunId $Command.Phase.Name
            Assert-BT ($phase.State -eq 'Open') 'CLEAN phase is closed.'
            Assert-BT ((Get-BTNodeConfigHash $NodeConfig) -eq $Command.ExpectedNodeConfigHash) 'ConfigHash drift before CLEAN.' 'BrainTrace.ConfigHash.Drift'
            $path=Get-BTCanonicalPath $source.Path
            Assert-BTNoReparsePoint -Path $path -Root $root
            foreach ($item in @(Get-ChildItem -LiteralPath $path -Force -Recurse)) {
                Assert-BT (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse point is not allowed below CLEAN target '$path'." 'BrainTrace.Simulation.ReparsePoint'
            }
            # Phase 2 simulates the cleanup effect by truncating only *.log files under the guarded root.
            foreach($file in @(Get-ChildItem -LiteralPath $path -File -Filter '*.log')) { [IO.File]::WriteAllText($file.FullName,'') }
            $cleaned += [pscustomobject]@{Id=$source.Id;CanonicalPath=$path;Result='SUCCESS'}
        }
        return [pscustomobject]@{Result='SUCCESS';LogSources=$cleaned;Fault=$fault}
    }
    if ($Action -eq 'COLLECT') {
        $assignment = @($NodeConfig.Node.CollectionAssignments | Where-Object { $_.RouteId -eq $Command.Parameters.CollectionRouteId -and $_.StepOrder -eq $Command.Parameters.StepOrder })
        Assert-BT ($assignment.Count -eq 1) 'Unknown or ambiguous CollectionAssignment.' 'BrainTrace.Collection.Assignment'
        return Invoke-BTSimulatedCopy $assignment[0] $SimulationRoot $Command.RunId
    }
    throw "Unsupported simulation mutation '$Action'."
}

function New-BTStatus {
    param($Command, $Inventory, [string]$Result, [string]$Message, $Details, [datetime]$StartedUtc)
    [pscustomobject][ordered]@{
        ProtocolVersion=1;EnvironmentId=$Command.EnvironmentId;ConfigRevision=$Inventory.ConfigRevision;NodeConfigHash=$Inventory.ConfigHash
        RunId=$Command.RunId;CommandId=$Command.CommandId;Node=$Inventory.Node;Roles=$Inventory.Roles;Action=$Command.Action;Phase=$Command.Phase
        Result=$Result;StartedUtc=$StartedUtc.ToString('o');CompletedUtc=(Get-BTUtcNow).ToString('o');Message=$Message;Details=$Details
    }
}

function Invoke-BTWorkerCommand {
    param([string]$ProcessingPath, [string]$NodeRoot, $NodeConfig, [string]$SimulationRoot)
    $started=Get-BTUtcNow; $inventory=Get-BTNodeInventory $NodeConfig; $command=$null
    try {
        $command=Import-BTJsonFile $ProcessingPath
        [void](Test-BTCommand $command $NodeConfig.Node.Name $NodeConfig.EnvironmentId -AllowExpiredClose)
        $commandHash=Get-BTCommandHash $command
        $existing=Read-BTReceipt $NodeRoot $command.CommandId
        if($null -ne $existing){
            if($existing.CommandHash -ne $commandHash){throw (New-BTErrorRecord 'CommandId collision with different canonical content.' 'BrainTrace.Protocol.CommandCollision')}
            if($existing.State -eq 'TERMINAL'){
                if($null -ne $existing.Status){Publish-BTStatus $NodeRoot $existing.Status|Out-Null}
                if(Test-Path -LiteralPath $ProcessingPath){Move-BTProcessedMessage $NodeRoot $ProcessingPath}
                return [pscustomobject]@{Result='DUPLICATE';CommandId=$command.CommandId;Disposition=$existing.Disposition}
            }
            if($existing.State -eq 'EFFECT_APPLIED'){
                $recoveredStatus=New-BTStatus $command $inventory 'SUCCESS' "$($command.Action) effect recovered from durable receipt." $existing.EffectResult $started
                $existing.State='TERMINAL';$existing.Disposition='EXECUTED_STATUS_LOST';$existing.Status=$recoveredStatus
                $existing|Add-Member -NotePropertyName CompletedUtc -NotePropertyValue ((Get-BTUtcNow).ToString('o')) -Force
                Write-BTReceipt $NodeRoot $existing;Publish-BTStatus $NodeRoot $recoveredStatus|Out-Null
                if(Test-Path -LiteralPath $ProcessingPath){Move-BTProcessedMessage $NodeRoot $ProcessingPath}
                return [pscustomobject]@{Result='RECOVERED';CommandId=$command.CommandId;Disposition='EXECUTED_STATUS_LOST';Status=$recoveredStatus}
            }
            if($existing.State -eq 'EXECUTING'){
                return [pscustomobject]@{Result='INDETERMINATE';CommandId=$command.CommandId;Disposition='INDETERMINATE'}
            }
        }
        if($null -eq $existing){
            $receipt=[pscustomobject][ordered]@{CommandId=$command.CommandId;CommandHash=$commandHash;RunId=$command.RunId;Action=$command.Action;PhaseName=if($null-ne$command.Phase){$command.Phase.Name}else{''};PhaseEpoch=if($null-ne$command.Phase){$command.Phase.Epoch}else{0};State='CLAIMED';Disposition='NOT_EXECUTED';ConfigHash=$inventory.ConfigHash;CreatedUtc=$started.ToString('o');EffectResult=$null;Status=$null}
            Write-BTReceipt $NodeRoot $receipt
            $faultAtClaim=Get-BTSimulationFault $NodeRoot $command.Action
            if($null-ne$faultAtClaim -and $faultAtClaim.Mode -eq 'CrashAfterClaim'){return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Boundary='AfterClaim'}}
        } else { $receipt=$existing }

        $details=$null
        switch($command.Action){
            'INVENTORY' { $details=[pscustomobject]@{Inventory=$inventory} }
            'STATE' {
                $fault=Get-BTSimulationFault $NodeRoot 'STATE'
                if($null-ne$fault -and $fault.Mode -in @('Exception','Timeout')){throw "Simulated STATE $($fault.Mode)."}
                $observed=Get-BTObservedState $NodeRoot $NodeConfig;$details=[pscustomobject]@{Components=$observed}
                $snapshot=[ordered]@{};foreach($componentState in $observed){$snapshot[$componentState.PhysicalIdentity]=$componentState.State}
                $snapshotPath=Join-Path (Join-Path $NodeRoot 'RunSnapshots') ($command.RunId+'.json');if(Test-Path -LiteralPath $snapshotPath){[IO.File]::Delete($snapshotPath)};Write-BTJsonAtomic $snapshot $snapshotPath|Out-Null
            }
            'PHASE_OPEN' {
                Assert-BT ($inventory.ConfigHash -eq $command.ExpectedNodeConfigHash) 'ConfigHash mismatch at PHASE_OPEN.' 'BrainTrace.ConfigHash.Mismatch'
                $details=Open-BTPhase $NodeRoot $command.RunId $command.Phase.Name $command.Phase.Epoch $command.Phase.Token $command.ExpectedNodeConfigHash
            }
            'PHASE_CLOSE' {
                $details=Close-BTPhase $NodeRoot $command.RunId $command.Phase.Name $command.Phase.Epoch $command.Phase.Token $command.ExpectedNodeConfigHash $NodeConfig
            }
            default {
                Assert-BT ($inventory.ConfigHash -eq $command.ExpectedNodeConfigHash) 'ConfigHash mismatch.' 'BrainTrace.ConfigHash.Mismatch'
                $phase=Get-BTPhaseRecord $NodeRoot $command.RunId $command.Phase.Name
                Assert-BT ($null-ne$phase -and $phase.State -eq 'Open' -and $phase.Epoch -eq $command.Phase.Epoch -and $phase.Token -eq $command.Phase.Token -and $phase.ConfigHash -eq $inventory.ConfigHash) 'Mutation is not authorized by an open phase.' 'BrainTrace.Phase.Closed'
                $receipt.State='AUTHORIZED';Write-BTReceipt $NodeRoot $receipt
                $boundaryFault=Get-BTSimulationFault $NodeRoot $command.Action
                if($null-ne$boundaryFault -and $boundaryFault.Mode -eq 'CrashAfterAuthorized'){return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Boundary='AfterAuthorized'}}
                $receipt.State='EXECUTING';Write-BTReceipt $NodeRoot $receipt
                if($null-ne$boundaryFault -and $boundaryFault.Mode -eq 'CrashBeforeEffect'){return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Boundary='BeforeEffect'}}
                $details=Invoke-BTSimulationMutation $command.Action $NodeConfig $NodeRoot $SimulationRoot $command
                $receipt.State='EFFECT_APPLIED';$receipt.Disposition='EXECUTED';$receipt.EffectResult=$details;Write-BTReceipt $NodeRoot $receipt
                if($null-ne$details.PSObject.Properties['Fault'] -and $null-ne$details.Fault -and $details.Fault.Mode -eq 'CrashAfterEffect'){
                    return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Disposition='EXECUTED_STATUS_LOST'}
                }
            }
        }
        $status=New-BTStatus $command $inventory 'SUCCESS' "$($command.Action) completed in simulation." $details $started
        $statusLost=$false
        if($null-ne$details -and $null-ne$details.PSObject.Properties['Fault'] -and $null-ne$details.Fault -and $details.Fault.Mode -eq 'StatusLost'){$statusLost=$true}
        if($statusLost){
            $receipt.State='EFFECT_APPLIED';$receipt.Disposition='EXECUTED_STATUS_LOST';$receipt.Status=$null;Write-BTReceipt $NodeRoot $receipt
            return [pscustomobject]@{Result='STATUS_LOST';CommandId=$command.CommandId;Status=$status}
        }
        $receipt.State='TERMINAL';$receipt.Disposition='EXECUTED';$receipt|Add-Member -NotePropertyName CompletedUtc -NotePropertyValue ((Get-BTUtcNow).ToString('o')) -Force;$receipt.Status=$status;Write-BTReceipt $NodeRoot $receipt
        $terminalFault=Get-BTSimulationFault $NodeRoot $command.Action
        if($null-ne$terminalFault -and $terminalFault.Mode -eq 'CrashAfterTerminalReceipt'){return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Boundary='AfterTerminalReceipt'}}
        Publish-BTStatus $NodeRoot $status|Out-Null
        if($null-ne$terminalFault -and $terminalFault.Mode -eq 'CrashAfterStatus'){return [pscustomobject]@{Result='CRASHED';CommandId=$command.CommandId;Boundary='AfterStatus'}}
        Move-BTProcessedMessage $NodeRoot $ProcessingPath
        [pscustomobject]@{Result=if($statusLost){'STATUS_LOST'}else{'SUCCESS'};CommandId=$command.CommandId;Status=$status}
    } catch {
        $id=if($null-ne$command){[string]$command.CommandId}else{[guid]::NewGuid().ToString()}
        $run=if($null-ne$command){[string]$command.RunId}else{'unknown'}
        $rejection=[pscustomobject][ordered]@{ProtocolVersion=1;RunId=$run;CommandId=$id;Node=$NodeConfig.Node.Name;Result='REJECTED';CompletedUtc=(Get-BTUtcNow).ToString('o');Message=$_.Exception.Message;Details=[pscustomobject]@{ErrorId=$_.FullyQualifiedErrorId;Diagnostic=$_.ScriptStackTrace}}
        Publish-BTStatus $NodeRoot $rejection|Out-Null
        if(Test-Path -LiteralPath $ProcessingPath){Move-BTProcessedMessage $NodeRoot $ProcessingPath -Rejected}
        [pscustomobject]@{Result='REJECTED';CommandId=$id;Error=$_.Exception.Message;Diagnostic=$_.ScriptStackTrace}
    }
}

function Invoke-BTWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$NodeRoot,[Parameter(Mandatory=$true)][string]$NodeConfigPath,[Parameter(Mandatory=$true)][string]$SimulationRoot,[int]$MaxCommands=20,[int]$MaxSeconds=45)
    Initialize-BTQueue $NodeRoot
    $config=Import-BTJsonFile $NodeConfigPath;[void](Test-BTNodeConfiguration $config)
    $results=@();$stopwatch=[Diagnostics.Stopwatch]::StartNew()
    try{
        while($results.Count-lt$MaxCommands -and $stopwatch.Elapsed.TotalSeconds-lt$MaxSeconds){
            # Control always wins. Only when no control is observable may stale Processing
            # work be recovered, followed by a fresh ordinary Inbox claim.
            $processing=Claim-BTMessage $NodeRoot -ControlOnly
            if($null-eq$processing){$processing=Get-ChildItem -LiteralPath (Join-Path $NodeRoot 'Processing') -File -Filter '*.json'|Sort-Object Name|Select-Object -First 1}
            if($null-eq$processing){$processing=Claim-BTMessage $NodeRoot}
            if($null-eq$processing){break}
            $processingPath=if($processing -is [IO.FileInfo]){$processing.FullName}else{[string]$processing}
            $results+=Invoke-BTWorkerCommand $processingPath $NodeRoot $config $SimulationRoot
            if($results[-1].Result -in @('CRASHED','INDETERMINATE')){break}
        }
    } finally {$stopwatch.Stop()}
    return $results
}
