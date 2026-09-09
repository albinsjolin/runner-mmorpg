# Ships the project to the VPS and restarts the run server.
#
#   .\deploy\deploy.ps1 -VpsHost root@1.2.3.4
#
# Packs the project (without caches and build output), copies it with scp, unpacks it into
# /opt/runner/app, runs Godot's import once so the .godot cache exists, and restarts the
# service. First run deploy/setup_vps.sh on the VPS. The import runs the engine in editor
# mode and needs about 1 GB of RAM (plus swap); a 512 MB droplet gets it OOM-killed.
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
$remote = @'
set -e
mkdir -p __DIR__
rm -rf __DIR__.new && mkdir -p __DIR__.new
tar -xzf /tmp/runner-app.tgz -C __DIR__.new
rm -rf __DIR__.old
[ -d __DIR__ ] && mv __DIR__ __DIR__.old || true
mv __DIR__.new __DIR__
chown -R runner:runner __DIR__
echo "importing (builds the .godot cache and the class registry)..."
sudo -u runner HOME=/opt/runner /opt/godot/godot --headless --path __DIR__ --import >/tmp/runner-import.log 2>&1 || echo "import exited non-zero (can be harmless), see /tmp/runner-import.log"
if [ ! -f __DIR__/.godot/global_script_class_cache.cfg ]; then
  echo "IMPORT FAILED: no class cache. Last lines of /tmp/runner-import.log:"
  tail -30 /tmp/runner-import.log
  dmesg 2>/dev/null | grep -i "killed process" | tail -2
  exit 1
fi
echo "import ok: $(grep -c class_name __DIR__/.godot/global_script_class_cache.cfg) classes registered"
systemctl restart runner-server
sleep 2
systemctl --no-pager --lines=8 status runner-server | sed 's/^/   /'
'@
$remote = $remote -replace '__DIR__', $RemoteDir
& ssh $VpsHost $remote

Write-Host ""
Write-Host "Deployed. Join from your PC:"
$ip = $VpsHost.Split("@")[-1]
Write-Host "  godot --path . -- --host=$ip --zone=forest"
Write-Host "Logs: ssh $VpsHost journalctl -u runner-server -f"
