#!/usr/bin/env bash
# One-time setup of an Ubuntu 22.04/24.04 VPS as a Runner MMORPG run server.
# Run as root:  bash setup_vps.sh
#
# What it does: installs the few libraries the Godot binary wants, downloads Godot 4.7.2
# for Linux, creates a "runner" user and /opt/runner, opens UDP 7777, and installs a
# systemd service that runs the server headless. Deploy the project afterwards with
# deploy.ps1 from your PC.
#
# Optional: set WITH_SPACETIMEDB=1 to also install SpacetimeDB on this box (meta mode).
set -euo pipefail

GODOT_VERSION="4.7.2"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
PUBLIC_IP="$(curl -s -4 https://ifconfig.me || hostname -I | awk '{print $1}')"

echo "== packages"
# A fresh droplet runs unattended upgrades on first boot and holds the apt lock for a while.
while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
  echo "   waiting for the first-boot apt run to finish..."
  sleep 5
done
apt-get update -q
apt-get install -y -q unzip curl ufw libgl1 libxcursor1 libxinerama1 libxrandr2 libxi6 libx11-6 libasound2t64 2>/dev/null \
  || apt-get install -y -q unzip curl ufw libgl1 libxcursor1 libxinerama1 libxrandr2 libxi6 libx11-6 libasound2

echo "== godot ${GODOT_VERSION}"
mkdir -p /opt/godot
if [ ! -x /opt/godot/godot ]; then
  curl -L -o /tmp/godot.zip "$GODOT_URL"
  unzip -o -q /tmp/godot.zip -d /opt/godot
  mv /opt/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /opt/godot/godot
  chmod +x /opt/godot/godot
  rm /tmp/godot.zip
fi
/opt/godot/godot --version

echo "== swap (safety net on small droplets)"
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -m | sed 's/^/   /'

echo "== user and folders"
id -u runner >/dev/null 2>&1 || useradd --system --create-home --home-dir /opt/runner --shell /usr/sbin/nologin runner
mkdir -p /opt/runner/app
chown -R runner:runner /opt/runner

echo "== firewall (ssh + game UDP)"
ufw allow OpenSSH >/dev/null
ufw allow 7777/udp >/dev/null
if [ "${WITH_SPACETIMEDB:-0}" = "1" ]; then ufw allow 3000/tcp >/dev/null; fi
ufw --force enable >/dev/null
ufw status | sed 's/^/   /'

echo "== service"
cat > /etc/runner.env <<EOF
# Flags for the run server. Edit and: systemctl restart runner-server
# Offline mode (direct joins, latency testing):
RUNNER_ARGS=--server --address=${PUBLIC_IP}:7777
# Meta mode (SpacetimeDB on this box, clients use --stdb=http://${PUBLIC_IP}:3000):
# RUNNER_ARGS=--server --stdb=http://127.0.0.1:3000 --stdb-secret=dev-run-server-secret --address=${PUBLIC_IP}:7777
EOF
install -m 644 "$(dirname "$0")/runner-server.service" /etc/systemd/system/runner-server.service 2>/dev/null \
  || cat > /etc/systemd/system/runner-server.service <<'EOF'
[Unit]
Description=Runner MMORPG run server (Godot, ENet/UDP 7777)
After=network-online.target
Wants=network-online.target

[Service]
User=runner
Group=runner
WorkingDirectory=/opt/runner/app
EnvironmentFile=/etc/runner.env
Environment=HOME=/opt/runner
ExecStart=/opt/godot/godot --headless --path /opt/runner/app -- $RUNNER_ARGS
Restart=always
RestartSec=3
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable runner-server >/dev/null

if [ "${WITH_SPACETIMEDB:-0}" = "1" ]; then
  echo "== spacetimedb"
  if ! command -v spacetime >/dev/null 2>&1; then
    curl -sSf https://install.spacetimedb.com | sh -s -- --yes
    ln -sf /root/.local/bin/spacetime /usr/local/bin/spacetime 2>/dev/null || true
  fi
  cat > /etc/systemd/system/spacetimedb.service <<'EOF'
[Unit]
Description=SpacetimeDB
After=network-online.target

[Service]
ExecStart=/usr/local/bin/spacetime start --listen-addr 0.0.0.0:3000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now spacetimedb
  echo "   publish the module from your PC:"
  echo "   spacetime server add vps http://${PUBLIC_IP}:3000 && cd spacetimedb && spacetime publish runner --server vps --yes"
fi

echo
echo "Done. Public IP: ${PUBLIC_IP}"
echo "Next, from your PC:  .\\deploy\\deploy.ps1 -VpsHost root@${PUBLIC_IP}"
