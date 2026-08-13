function Import-BTJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $text = [System.IO.File]::ReadAllText($resolved.Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON file is empty: $Path" }
    Assert-BTNoDuplicateJsonProperties $text
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Assert-BTNoDuplicateJsonProperties {
    param([Parameter(Mandatory = $true)][string]$Text)
    $stack=New-Object System.Collections.Stack
    for($index=0;$index-lt$Text.Length;$index++){
        $character=$Text[$index]
        if($character-eq'"'){
            $start=$index;$index++
            while($index-lt$Text.Length){
                if($Text[$index]-eq'"'){
                    $slashes=0;$scan=$index-1
                    while($scan-gt$start-and$Text[$scan]-eq'\'){$slashes++;$scan--}
                    if(($slashes%2)-eq0){break}
                }
                $index++
            }
            if($index-ge$Text.Length){return}
            $look=$index+1;while($look-lt$Text.Length-and[char]::IsWhiteSpace($Text[$look])){$look++}
            if($look-lt$Text.Length-and$Text[$look]-eq':'-and$stack.Count-gt0-and$stack.Peek().Type-eq'Object'){
                $literal=$Text.Substring($start,$index-$start+1);$name=[string]($literal|ConvertFrom-Json)
                if(-not$stack.Peek().Keys.Add($name)){throw "Duplicate JSON property '$name'."}
            }
            continue
        }
        if($character-eq'{'){$stack.Push([pscustomobject]@{Type='Object';Keys=(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))})}
        elseif($character-eq'['){$stack.Push([pscustomobject]@{Type='Array';Keys=$null})}
        elseif($character-eq'}'-or$character-eq']'){if($stack.Count-gt0){[void]$stack.Pop()}}
    }
}

function ConvertTo-BTHashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [char] -or $InputObject -is [bool] -or
        $InputObject -is [byte] -or $InputObject -is [int16] -or $InputObject -is [int32] -or
        $InputObject -is [int64] -or $InputObject -is [uint16] -or $InputObject -is [uint32] -or
        $InputObject -is [uint64]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $table[[string]$key] = ConvertTo-BTHashtable $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $table[$property.Name] = ConvertTo-BTHashtable $property.Value }
        return $table
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @($InputObject | ForEach-Object { ConvertTo-BTHashtable $_ })
        return ,$items
    }
    return $InputObject
}

function ConvertTo-BTCanonicalJsonValue {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string] -or $Value -is [char]) {
        $normalized = ([string]$Value).Normalize([Text.NormalizationForm]::FormC)
        return ($normalized | ConvertTo-Json -Compress)
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $table = ConvertTo-BTHashtable $Value
        [string[]]$keys = @($table.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $parts = foreach ($key in $keys) {
            (ConvertTo-BTCanonicalJsonValue ([string]$key)) + ':' + (ConvertTo-BTCanonicalJsonValue $table[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $parts = @($Value | ForEach-Object { ConvertTo-BTCanonicalJsonValue $_ })
        return '[' + ($parts -join ',') + ']'
    }
    throw "Unsupported canonical JSON value type: $($Value.GetType().FullName)"
}

function Get-BTSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Write-BTJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$InputObject, [Parameter(Mandatory = $true)][string]$Path, [int]$Depth = 30)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory (([IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $stream = New-Object System.IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $Path)
    return $Path
}
