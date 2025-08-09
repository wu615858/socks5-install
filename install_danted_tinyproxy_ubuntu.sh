#!/usr/bin/env bash
# install_danted_tinyproxy_ubuntu.sh
# Ubuntu 22.04 LTS: One-click install & configure Dante (SOCKS5) + TinyProxy (HTTP)
# Defaults: USER=123456 PASS=654321 SOCKS_PORT=5555 HTTP_PORT=4444
set -euo pipefail

# ---- Params (overridable by flags or env) ----
AUTH_USER="${AUTH_USER:-123456}"
AUTH_PASS="${AUTH_PASS:-654321}"
SOCKS_PORT="${SOCKS_PORT:-5555}"
HTTP_PORT="${HTTP_PORT:-4444}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AUTH_USER="$2"; shift 2 ;;
    --pass) AUTH_PASS="$2"; shift 2 ;;
    --socks) SOCKS_PORT="$2"; shift 2 ;;
    --http) HTTP_PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

. /etc/lsb-release || true
if [[ "${DISTRIB_ID:-}" != "Ubuntu" || "${DISTRIB_RELEASE:-}" != "22.04" ]]; then
  echo "Warning: this script is tailored for Ubuntu 22.04 LTS, continuing anyway..."
fi

echo "[*] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y dante-server tinyproxy curl

# ---- Detect default route interface (bind by iface, not IP, to survive IP changes) ----
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
IFACE="${IFACE:-eth0}"

# ---- Configure Dante ----
DANTECONF="/etc/danted.conf"
echo "[*] Writing $DANTECONF"
cat >"$DANTECONF" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${IFACE}

user.privileged: root
user.notprivileged: nobody

# Global auth method
method: username

# Allow all clients to connect to proxy server (tighten if needed)
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

# Allow proxying TCP/UDP with username auth
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect
}
EOF

# ---- Ensure auth user (allow numeric usernames) ----
if id -u "$AUTH_USER" >/dev/null 2>&1; then
  echo "[*] User $AUTH_USER exists, updating password"
else
  echo "[*] Creating user $AUTH_USER"
  useradd -M --badname "$AUTH_USER" || true
fi
echo "${AUTH_USER}:${AUTH_PASS}" | chpasswd

# ---- Auto-refresh external iface before each start (handles future IP/iface changes) ----
install -m 0755 -d /usr/local/sbin >/dev/null 2>&1 || true
cat >/usr/local/sbin/update-danted-iface.sh <<'EOS'
#!/usr/bin/env bash
set -e
CONF="/etc/danted.conf"
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
IFACE="${IFACE:-eth0}"
if grep -qE '^external:' "$CONF"; then
  sed -ri "s|^external:.*|external: ${IFACE}|" "$CONF"
else
  sed -ri "/^internal:/a external: ${IFACE}" "$CONF"
fi
EOS
chmod +x /usr/local/sbin/update-danted-iface.sh

mkdir -p /etc/systemd/system/danted.service.d
cat >/etc/systemd/system/danted.service.d/override.conf <<EOF
[Service]
ExecStartPre=/usr/local/sbin/update-danted-iface.sh
EOF

# ---- Configure TinyProxy ----
echo "[*] Configuring TinyProxy (HTTP ${HTTP_PORT})"
install -d -o tinyproxy -g tinyproxy /var/log/tinyproxy
TINYCONF="/etc/tinyproxy/tinyproxy.conf"
cat >"$TINYCONF" <<EOF
User tinyproxy
Group tinyproxy
Port ${HTTP_PORT}
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
PidFile "/run/tinyproxy/tinyproxy.pid"
BasicAuth ${AUTH_USER} ${AUTH_PASS}
Allow 0.0.0.0/0
MaxClients 100
StartServers 5
ViaProxyName "tinyproxy"
DisableViaHeader Yes
ConnectPort 443
ConnectPort 563
EOF

# ---- Enable & start services ----
systemctl daemon-reload
systemctl enable --now danted tinyproxy || true

# ---- Optional: open firewall if ufw exists ----
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SOCKS_PORT}"/tcp || true
  ufw allow "${HTTP_PORT}"/tcp || true
fi

# ---- Show results ----
PUB_IP="$(curl -s --max-time 3 https://ifconfig.me || hostname -I | awk '{print $1; exit}')"
echo
echo "✅ Done on Ubuntu 22.04"
echo "SOCKS5: socks5://${AUTH_USER}:${AUTH_PASS}@${PUB_IP}:${SOCKS_PORT}"
echo "HTTP  : http://${AUTH_USER}:${AUTH_PASS}@${PUB_IP}:${HTTP_PORT}"
echo
echo "---- danted status (first lines) ----"
systemctl --no-pager -l status danted | sed -n '1,12p' || true
echo "---- tinyproxy status (first lines) ----"
systemctl --no-pager -l status tinyproxy | sed -n '1,12p' || true
echo
echo "Tip: open TCP ${SOCKS_PORT} and ${HTTP_PORT} in your cloud security group."
