[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$Environment,
    [string]$Manager=$env:COMPUTERNAME,
    [switch]$CreateScheduledTasks,
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

function Register-BrainTraceManagedTask {
    param([string]$ComputerName,[string]$WorkerRoot,[int]$Minutes)
    $taskCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $WorkerRoot 'Worker.ps1')+'"'
    $arguments=@('/Create','/S',$ComputerName,'/TN','BrainTrace-Worker','/TR',$taskCommand,'/SC','MINUTE','/MO',[string]$Minutes,'/RU','SYSTEM','/RL','HIGHEST','/F')
    $output=(& schtasks.exe @arguments 2>&1|Out-String).Trim()
    if($LASTEXITCODE-ne0){throw "Could not register the same-tier BrainTrace-Worker task on '$ComputerName': $output"}
}

$config=Get-BrainTraceEnvironmentConfig $Environment $repositoryRoot
$managerNode=Get-BrainTraceNode $config $Manager
if($null-eq$managerNode){throw "Deployment manager '$Manager' is not configured in '$($config.Environment)'."}
if($Manager-ine$env:COMPUTERNAME-and-not$WhatIfPreference){throw "Deployment for '$Manager' must run on that server. Current computer: $($env:COMPUTERNAME)."}
$selected=@($config.Nodes|Where-Object{$_.DeploymentManager-ieq$Manager})
if($selected.Count-eq0){throw "Deployment manager '$Manager' has no configured nodes."}

$installer=Join-Path $PSScriptRoot 'Install-Worker.ps1'
$results=@()
foreach($node in $selected){
    $isLocal=$node.Name-ieq$env:COMPUTERNAME
    $destination=if($isLocal){[string]$config.WorkerRoot}else{ConvertTo-BrainTraceAdminPath $node.Name ([string]$config.WorkerRoot)}
    $description=if($CreateScheduledTasks){"Install files at '$destination' and create its same-tier Scheduled Task"}else{"Update files at '$destination' without Scheduled Task access"}
    if(-not$PSCmdlet.ShouldProcess($node.Name,$description)){
        $results+=[pscustomobject]@{Node=$node.Name;Success=$true;Result='Planned only (-WhatIf)'}
        continue
    }
    try{
        if($isLocal-and$CreateScheduledTasks){
            & $installer -Environment $Environment -Node $node.Name -Destination $destination -CreateScheduledTask -IntervalMinutes $IntervalMinutes
        }else{
            & $installer -Environment $Environment -Node $node.Name -Destination $destination
            if($CreateScheduledTasks){[void](Register-BrainTraceManagedTask $node.Name ([string]$config.WorkerRoot) $IntervalMinutes)}
        }
        $result=if($CreateScheduledTasks){'Files and same-tier task installed'}else{'Files updated; task unchanged'}
        $results+=[pscustomobject]@{Node=$node.Name;Success=$true;Result=$result}
    }catch{
        $results+=[pscustomobject]@{Node=$node.Name;Success=$false;Result=$_.Exception.Message}
    }
}

$results|Format-Table -AutoSize
if(@($results|Where-Object{-not$_.Success}).Count){throw 'One or more BrainTrace deployments failed. Review the results above.'}
