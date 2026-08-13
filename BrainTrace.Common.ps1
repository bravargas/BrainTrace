Set-StrictMode -Version 2.0

function Read-BrainTraceJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Write-BrainTraceJsonAtomic {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string]$Path)
    $directory=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force|Out-Null }
    $temporary=Join-Path $directory ((Split-Path -Leaf $Path)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    $encoding=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 20),$encoding)
    [IO.File]::Move($temporary,$Path)
}

function Get-BrainTraceProperty {
    param($Object,[string]$Name,$Default=$null)
    if ($null-ne$Object -and $null-ne$Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Test-BrainTraceEnvironment {
    param([Parameter(Mandatory=$true)]$Config)
    if ([string]::IsNullOrWhiteSpace([string]$Config.Environment)) { throw 'Environment is required.' }
    $nodes=@($Config.Nodes);if($nodes.Count-eq0){throw 'At least one node is required.'}
    $seen=@{}
    foreach($node in $nodes){
        if([string]::IsNullOrWhiteSpace([string]$node.Name)){throw 'Every node requires Name.'}
        $key=([string]$node.Name).ToUpperInvariant();if($seen.ContainsKey($key)){throw "Duplicate node '$($node.Name)'."};$seen[$key]=$true
        foreach($role in @($node.Roles)){if($role -notin @('TP','APP','WEB')){throw "Invalid role '$role' on '$($node.Name)'."}}
        $paths=@{}
        foreach($log in @($node.Logs)){
            if([string]::IsNullOrWhiteSpace([string]$log.Id)){throw "Log Id is required on '$($node.Name)'."}
            if(-not[IO.Path]::IsPathRooted([string]$log.LocalPath)){throw "LocalPath must be absolute on '$($node.Name)'."}
            if(-not([string]$log.UNCPath).StartsWith('\\')){throw "UNCPath must be UNC on '$($node.Name)'."}
            $pathKey=([IO.Path]::GetFullPath([string]$log.LocalPath)).TrimEnd('\').ToUpperInvariant()
            if($paths.ContainsKey($pathKey)){throw "Duplicate local log path on '$($node.Name)': $($log.LocalPath)"};$paths[$pathKey]=$true
        }
        $componentSeen=@{}
        foreach($value in @($node.Components.Services)+@($node.Components.AppPools)){
            $componentKey=([string]$value).ToUpperInvariant();if($componentSeen.ContainsKey($componentKey)){throw "Duplicate component '$value' on '$($node.Name)'."};$componentSeen[$componentKey]=$true
        }
    }
    foreach($required in @([string]$Config.Controller,[string]$Config.Aggregator)){if(-not$seen.ContainsKey($required.ToUpperInvariant())){throw "Unknown configured node '$required'."}}
    foreach($node in $nodes){
        if($node.CommandAccess -notin @('Direct','Via')){throw "CommandAccess must be Direct or Via on '$($node.Name)'."}
        if($node.CommandAccess-eq'Via' -and (-not$seen.ContainsKey(([string]$node.CommandVia).ToUpperInvariant()))){throw "Unknown CommandVia on '$($node.Name)'."}
        if(-not$seen.ContainsKey(([string]$node.CollectBy).ToUpperInvariant())){throw "Unknown CollectBy on '$($node.Name)'."}
    }
    return $true
}

function Get-BrainTraceEnvironmentConfig {
    param([string]$Environment,[string]$RepositoryRoot)
    $path=if(Test-Path -LiteralPath $Environment -PathType Leaf){$Environment}else{Join-Path (Join-Path $RepositoryRoot 'config') ($Environment+'.json')}
    $config=Read-BrainTraceJson $path;[void](Test-BrainTraceEnvironment $config);return $config
}

function Get-BrainTraceNode { param($Config,[string]$Name) @($Config.Nodes|Where-Object{$_.Name-ieq$Name})[0] }

function ConvertTo-BrainTraceSafeName {
    param([Parameter(Mandatory=$true)][string]$Name)
    $safe=($Name -replace '[^A-Za-z0-9._-]','_').Trim('.','_')
    if([string]::IsNullOrWhiteSpace($safe)){throw 'Name does not contain usable filename characters.'}
    if($safe.Length-gt60){$safe=$safe.Substring(0,60)}
    return $safe
}

function Get-BrainTraceRobocopyResult {
    param([int]$ExitCode)
    [pscustomobject]@{ExitCode=$ExitCode;Success=($ExitCode-ge0-and$ExitCode-lt8);Warning=($ExitCode-gt0-and$ExitCode-lt8)}
}

function Write-BrainTraceLog {
    param([string]$Path,[string]$RunId,[string]$Environment,[string]$Node,[string]$Action,[bool]$Success,[string]$Message)
    $directory=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $record=[ordered]@{TimestampUtc=[datetime]::UtcNow.ToString('o');RunId=$RunId;Environment=$Environment;Node=$Node;Action=$Action;Success=$Success;Message=$Message}
    [IO.File]::AppendAllText($Path,($record|ConvertTo-Json -Compress)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-BrainTracePreparePolicy {
    param([Parameter(Mandatory=$true)][scriptblock]$ActionInvoker)
    $stop=@(& $ActionInvoker 'STOP')
    if(@($stop|Where-Object{-not$_.Success}).Count){
        $start=@(& $ActionInvoker 'START')
        return [pscustomobject]@{Success=$false;Stop=$stop;Clean=@();Start=$start;CleanExecuted=$false}
    }
    $clean=@(& $ActionInvoker 'CLEAN')
    $start=@(& $ActionInvoker 'START')
    [pscustomobject]@{Success=(@($clean+$start|Where-Object{-not$_.Success}).Count-eq0);Stop=$stop;Clean=$clean;Start=$start;CleanExecuted=$true}
}
