BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force
    $scenario=New-BTSimulationScenario -Name FULL_AIO_SEPARATE_LOGS -RootPath (Join-Path $TestDrive 'hash')
    $path=Join-Path $scenario.NodeConfigDirectory 'FULLAIO1.json'
    $base=Import-BTJsonFile $path
}

Describe 'BrainTraceCanonicalNodeV1' {
    It 'matches the frozen BrainTraceCanonicalNodeV1 SHA-256 vector' {
        $vector=Import-BTJsonFile (Join-Path $PSScriptRoot '..\fixtures\canonical-node-v1.json')
        Get-BTNodeConfigHash $vector|Should -BeExactly '47f668780f14f6d03410edaa884a3dcefe2d4316d59c976ece4f371e025d04c6'
    }
    It 'normalizes Unicode NFC before hashing' {
        $vector=Import-BTJsonFile (Join-Path $PSScriptRoot '..\fixtures\canonical-node-v1.json');$expected=Get-BTNodeConfigHash $vector
        $vector.EnvironmentId="Cafe$([char]0x0301)"
        Get-BTNodeConfigHash $vector|Should -BeExactly $expected
    }
    It 'uses ordinal ordering independently of the current culture' {
        $vector=Import-BTJsonFile (Join-Path $PSScriptRoot '..\fixtures\canonical-node-v1.json');$expected=Get-BTNodeConfigHash $vector
        $original=[Threading.Thread]::CurrentThread.CurrentCulture
        try{[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]'tr-TR';Get-BTNodeConfigHash $vector|Should -BeExactly $expected}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$original}
    }
    It 'normalizes Windows path case, dot segments, and trailing separators' {
        $vector=Import-BTJsonFile (Join-Path $PSScriptRoot '..\fixtures\canonical-node-v1.json');$expected=Get-BTNodeConfigHash $vector
        $vector.Node.WorkerRoot='d:\BRAINTRACE\.'
        $vector.Node.AllowedCleanupRoots[0]='d:\logs\apps\sub\..\\'
        $vector.Node.LogSources[0].Path='d:\LOGS\APPS\MAIN'
        $vector.Node.CollectionAssignments[0].Read.AccessPath='d:\logs\apps\main\.'
        $vector.Node.CollectionAssignments[0].Write.PathTemplate='d:\braintrace\staging\{RUNID}\nodes\aio1\main\'
        Get-BTNodeConfigHash $vector|Should -BeExactly $expected
    }
    It 'expands the missing RequiredEndState default without changing identity' {
        $vector=Import-BTJsonFile (Join-Path $PSScriptRoot '..\fixtures\canonical-node-v1.json');$expected=Get-BTNodeConfigHash $vector
        $vector.Node.Components[1]|Add-Member -NotePropertyName RequiredEndState -NotePropertyValue Running
        Get-BTNodeConfigHash $vector|Should -BeExactly $expected
    }
    It 'produces the same hash for different JSON formatting and property order' {
        $json=$base|ConvertTo-Json -Depth 20 -Compress
        $roundTrip=$json|ConvertFrom-Json
        (Get-BTNodeConfigHash $roundTrip)|Should -Be (Get-BTNodeConfigHash $base)
    }
    It 'changes for a different LogSource path' {
        $copy=($base|ConvertTo-Json -Depth 20|ConvertFrom-Json);$copy.Node.LogSources[0].Path+='-changed'
        (Get-BTNodeConfigHash $copy)|Should -Not -Be (Get-BTNodeConfigHash $base)
    }
    It 'changes for a different component' {
        $copy=($base|ConvertTo-Json -Depth 20|ConvertFrom-Json);$copy.Node.Components[0].ResourceName+='Changed'
        (Get-BTNodeConfigHash $copy)|Should -Not -Be (Get-BTNodeConfigHash $base)
    }
    It 'changes for a different StopOrder' {
        $copy=($base|ConvertTo-Json -Depth 20|ConvertFrom-Json);$copy.Node.Components[0].StopOrder++
        (Get-BTNodeConfigHash $copy)|Should -Not -Be (Get-BTNodeConfigHash $base)
    }
    It 'changes for a different CollectionAssignment' {
        $copy=($base|ConvertTo-Json -Depth 20|ConvertFrom-Json);$copy.Node.CollectionAssignments[0].Write.PathTemplate+='Changed'
        (Get-BTNodeConfigHash $copy)|Should -Not -Be (Get-BTNodeConfigHash $base)
    }
    It 'changes for a different safety policy' {
        $copy=($base|ConvertTo-Json -Depth 20|ConvertFrom-Json);$copy.Node.AllowedCleanupRoots[0]+='Changed'
        (Get-BTNodeConfigHash $copy)|Should -Not -Be (Get-BTNodeConfigHash $base)
    }
}
