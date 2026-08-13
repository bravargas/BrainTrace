function Write-BTLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Event, [hashtable]$Data = @{})
    $record = [ordered]@{ TimestampUtc = (Get-BTUtcNow).ToString('o'); Event = $Event }
    foreach ($key in @($Data.Keys | Sort-Object)) {
        if ($key -match '(Credential|Password|Secret|Token)$') { continue }
        $record[$key] = $Data[$key]
    }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $line = $record | ConvertTo-Json -Compress -Depth 20
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
