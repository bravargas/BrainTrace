BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\..\BrainTrace.psd1') -Force }

Describe 'Explicit relay simulation' {
    BeforeEach {
        $scenario=New-BTSimulationScenario QA (Join-Path $TestDrive ([guid]::NewGuid().ToString()));$env=Import-BTJsonFile $scenario.EnvironmentPath;$roots=@{}
        foreach($node in $env.Nodes){$config=Import-BTJsonFile (Join-Path $scenario.NodeConfigDirectory ($node.Name+'.json'));$roots[$node.Name]=$config.Node.WorkerRoot}
        $route=@($env.CommandRoutes|Where-Object Target -EQ WEB1)[0];$command=New-BTCommand QA ('relay-'+[guid]::NewGuid()) TP1 WEB1 INVENTORY -Route ([pscustomobject]@{Hops=@($route.Hops);NextHopIndex=1})
    }
    It 'forwards only the configured route' {
        InModuleScope BrainTrace -Parameters @{c=$command;e=$env;r=$roots} {(Invoke-BTRelaySimulation $c $e $r).Result}|Should -Be SUCCESS
    }
    It 'makes duplicate delivery harmless' {
        InModuleScope BrainTrace -Parameters @{c=$command;e=$env;r=$roots} {Invoke-BTRelaySimulation $c $e $r|Out-Null;(Invoke-BTRelaySimulation $c $e $r).Result}|Should -Be SUCCESS
    }
    It 'simulates an unavailable relay' {
        InModuleScope BrainTrace -Parameters @{c=$command;e=$env;r=$roots} {(Invoke-BTRelaySimulation $c $e $r @{APP1='Unavailable'}).Result}|Should -Be FAILED
    }
    It 'simulates status return failure independently of command delivery' {
        InModuleScope BrainTrace -Parameters @{c=$command;e=$env;r=$roots} {$result=Invoke-BTRelaySimulation $c $e $r @{'StatusReturn:APP1'='Unavailable'};$result.Result}|Should -Be SUCCESS
        InModuleScope BrainTrace -Parameters @{c=$command;e=$env;r=$roots} {$result=Invoke-BTRelaySimulation $c $e $r @{'StatusReturn:APP1'='Unavailable'};$result.StatusReturn}|Should -Be FAILED
    }
}
