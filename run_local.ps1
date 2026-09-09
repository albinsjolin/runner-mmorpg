# Launches one run server and N clients from this folder for local testing.
#
# Default (meta mode): needs a local SpacetimeDB with the "runner" module published.
#   .\run_local.ps1                     run server registered with SpacetimeDB + 2 town clients
#   .\run_local.ps1 -Clients 4          4 town clients: pick names, form a party, press RUN
#   .\run_local.ps1 --stdb http://1.2.3.4:3000   use another SpacetimeDB host
#
# Offline mode (no SpacetimeDB): clients join a zone directly, role cycles.
#   .\run_local.ps1 -Offline -Clients 2 --zone spine --speed 3
#
# Set $env:GODOT to your Godot 4 executable if it is not on PATH.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Clients = 2,
    [double]$Speed = 0,
    [string]$Zone = "forest",
    [string]$Stdb = "http://127.0.0.1:3000",
    [switch]$Offline,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

# Accept --speed 3, --speed=3, --zone spine, --clients 4, --stdb URL, --offline
for ($i = 0; $i -lt $Rest.Count; $i++) {
    $arg = $Rest[$i]
    $name = $null; $value = $null
    if ($arg -match '^--?offline$') { $Offline = $true; continue }
    if ($arg -match '^--?(\w+)=(.+)$') { $name = $Matches[1]; $value = $Matches[2] }
    elseif ($arg -match '^--?(\w+)$' -and $i + 1 -lt $Rest.Count) { $name = $Matches[1]; $value = $Rest[$i + 1]; $i++ }
    else { Write-Warning "Ignoring argument: $arg"; continue }
    switch ($name.ToLower()) {
        "speed"   { $Speed = [double]$value }
        "zone"    { $Zone = $value }
        "clients" { $Clients = [int]$value }
        "stdb"    { $Stdb = $value }
        default   { Write-Warning "Unknown option: $name" }
    }
}

$godot = if ($env:GODOT) { $env:GODOT } else { "godot" }
$roles = 0..3

$serverArgs = @("--headless", "--path", "$PSScriptRoot", "--", "--server")
if ($Speed -gt 0) { $serverArgs += "--speed=$Speed" }
if (-not $Offline) { $serverArgs += "--stdb=$Stdb"; $serverArgs += "--address=127.0.0.1:7777" }
Write-Host "Server: $($serverArgs -join ' ')"
Start-Process $godot -ArgumentList $serverArgs
Start-Sleep -Seconds 2

for ($i = 0; $i -lt $Clients; $i++) {
    $clientArgs = @("--path", "$PSScriptRoot", "--")
    if ($Offline) {
        $role = $roles[$i % $roles.Count]
        $clientArgs += @("--host=127.0.0.1", "--role=$role", "--zone=$Zone")
    } else {
        $clientArgs += @("--stdb=$Stdb", "--profile=client$($i + 1)")
    }
    Write-Host "Client $($i + 1): $($clientArgs -join ' ')"
    Start-Process $godot -ArgumentList $clientArgs
}
