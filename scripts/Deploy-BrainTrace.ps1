[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$Environment,
    [Parameter(Mandatory=$true)][ValidateSet('TP','APP','WEB')][string[]]$Role,
    [ValidateRange(1,1440)][int]$IntervalMinutes=1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $repositoryRoot 'src') 'BrainTrace.Common.ps1')

function ConvertTo-BrainTraceAdminPath {
    param([string]$ComputerName,[string]$LocalPath)
    $full=[IO.Path]::GetFullPath($LocalPath)
    if($full-notmatch '^([A-Za-z]):\\(.*)$'){throw "WorkerRoot must be a drive path for remote deployment: '$LocalPath'."}
    return "\\$ComputerName\$($matches[1])`$\$($matches[2])"
}

function Register-BrainTraceRemoteTask {
    param([string]$ComputerName,[string]$WorkerRoot,[int]$Minutes)
    $taskCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $WorkerRoot 'Worker.ps1')+'"'
    $arguments=@('/Create','/S',$ComputerName,'/TN','BrainTrace-Worker','/TR',$taskCommand,'/SC','MINUTE','/MO',[string]$Minutes,'/RU','SYSTEM','/RL','HIGHEST','/F')
    $output=(& schtasks.exe @arguments 2>&1|Out-String).Trim()
    if($LASTEXITCODE-ne0){throw "Could not register BrainTrace-Worker on '$ComputerName': $output"}
    return $output
}

$config=Get-BrainTraceEnvironmentConfig $Environment $repositoryRoot
$selected=@($config.Nodes|Where-Object{
    $nodeRoles=@($_.Roles)
    @($Role|Where-Object{$_ -in $nodeRoles}).Count-gt0
})
if($selected.Count-eq0){throw "No nodes in '$($config.Environment)' match role(s): $($Role-join', ')."}

$installer=Join-Path $PSScriptRoot 'Install-Worker.ps1'
$results=@()
foreach($node in $selected){
    $isLocal=$node.Name-ieq$env:COMPUTERNAME
    $destination=if($isLocal){[string]$config.WorkerRoot}else{ConvertTo-BrainTraceAdminPath $node.Name ([string]$config.WorkerRoot)}
    $description="Install/update files at '$destination' and register the SYSTEM task"
    if(-not$PSCmdlet.ShouldProcess($node.Name,$description)){
        $results+=[pscustomobject]@{Node=$node.Name;Success=$true;Result='Planned only (-WhatIf)'}
        continue
    }
    try{
        if($isLocal){
            & $installer -Environment $Environment -Node $node.Name -Destination $destination -CreateScheduledTask -IntervalMinutes $IntervalMinutes
        }else{
            & $installer -Environment $Environment -Node $node.Name -Destination $destination
            [void](Register-BrainTraceRemoteTask $node.Name ([string]$config.WorkerRoot) $IntervalMinutes)
        }
        $results+=[pscustomobject]@{Node=$node.Name;Success=$true;Result=if($isLocal){'Updated locally'}else{'Updated remotely'}}
    }catch{
        $results+=[pscustomobject]@{Node=$node.Name;Success=$false;Result=$_.Exception.Message}
    }
}

$results|Format-Table -AutoSize
if(@($results|Where-Object{-not$_.Success}).Count){throw 'One or more BrainTrace deployments failed. Review the results above.'}
