function New-BTErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$ErrorId,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidData,
        [object]$TargetObject
    )
    $exception = New-Object System.InvalidOperationException($Message)
    New-Object System.Management.Automation.ErrorRecord($exception, $ErrorId, $Category, $TargetObject)
}

function Assert-BT {
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message, [string]$ErrorId = 'BrainTrace.Validation')
    if (-not $Condition) { throw (New-BTErrorRecord -Message $Message -ErrorId $ErrorId) }
}

