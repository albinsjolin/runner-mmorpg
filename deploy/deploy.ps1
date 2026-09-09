# Ships the project to the VPS and restarts the run server.
#
#   .\deploy\deploy.ps1 -VpsHost root@1.2.3.4
#
# Packs the project (without caches and build output), copies it with scp, unpacks it into
# /opt/runner/app, runs Godot's import once so the .godot cache exists, and restarts the
# service. First run deploy/setup_vps.sh on the VPS.
param(
    [Parameter(Mandatory = $true)][string]$VpsHost,
    [string]$RemoteDir = "/opt/runner/app"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$archive = Join-Path $env:TEMP "runner-app.tgz"

Write-Host "Packing $root"
Push-Location $root
try {
    # tar.exe ships with Windows 10/11. Excludes must come before the paths.
    & tar.exe -czf $archive `
        --exclude=.godot --exclude=export --exclude=.git `
        --exclude=spacetimedb/spacetimedb/target --exclude=spacetime_bindings/codegen_debug `
        --exclude=deploy --exclude=*.png `
        .
} finally { Pop-Location }
$size = [math]::Round((Get-Item $archive).Length / 1MB, 1)
Write-Host "Archive: $size MB"

Write-Host "Uploading to $VpsHost"
& scp -q $archive "${VpsHost}:/tmp/runner-app.tgz"

Write-Host "Installing and restarting"
$remote = @"
set -e
mkdir -p $RemoteDir
rm -rf $RemoteDir.new && mkdir -p $RemoteDir.new
tar -xzf /tmp/runner-app.tgz -C $RemoteDir.new
rm -rf $RemoteDir.old
[ -d $RemoteDir ] && mv $RemoteDir $RemoteDir.old || true
mv $RemoteDir.new $RemoteDir
chown -R runner:runner $RemoteDir
sudo -u runner HOME=/opt/runner /opt/godot/godot --headless --path $RemoteDir --import >/tmp/runner-import.log 2>&1 || true
systemctl restart runner-server
sleep 2
systemctl --no-pager --lines=8 status runner-server | sed 's/^/   /'
"@
& ssh $VpsHost $remote

Write-Host ""
Write-Host "Deployed. Join from your PC:"
$ip = $VpsHost.Split("@")[-1]
Write-Host "  godot --path . -- --host=$ip --zone=forest"
Write-Host "Logs: ssh $VpsHost journalctl -u runner-server -f"
