$script:BTTimeProvider = $null

function Get-BTUtcNow {
    [CmdletBinding()]
    param()

    if ($null -ne $script:BTTimeProvider -and $null -ne $script:BTTimeProvider.PSObject.Properties['UtcNow']) {
        return ([datetime](& $script:BTTimeProvider.UtcNow)).ToUniversalTime()
    }
    return [datetime]::UtcNow
}

function Invoke-BTDelay {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(0, 2147483647)][int]$Milliseconds)

    if ($Milliseconds -eq 0) { return }
    if ($null -ne $script:BTTimeProvider -and $null -ne $script:BTTimeProvider.PSObject.Properties['Delay']) {
        & $script:BTTimeProvider.Delay $Milliseconds
        return
    }
    Start-Sleep -Milliseconds $Milliseconds
}

function Set-BTTimeProvider {
    [CmdletBinding()]
    param($Provider)
    $script:BTTimeProvider = $Provider
}
