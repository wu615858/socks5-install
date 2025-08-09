#!/usr/bin/env bash
# install_danted_dynamic.sh
# Debian/Ubuntu: Install & configure Dante SOCKS5 with dynamic IP support.
# Defaults: USER=123456 PASS=654321 PORT=5555 (can override via env or flags)
set -euo pipefail

# ---- Params ----
AUTH_USER="${AUTH_USER:-123456}"
AUTH_PASS="${AUTH_PASS:-654321}"
SOCKS_PORT="${SOCKS_PORT:-5555}"

# Flags: --user --pass --port
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AUTH_USER="$2"; shift 2 ;;
    --pass) AUTH_PASS="$2"; shift 2 ;;
    --port|--socks) SOCKS_PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "This script supports Debian/Ubuntu (apt required)."
  exit 1
fi

echo "[*] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y dante-server curl

# Detect default route interface (bind by iface, not IP).
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
IFACE="${IFACE:-eth0}"

CONF="/etc/danted.conf"
echo "[*] Writing $CONF"
cat >"$CONF" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${IFACE}

user.privileged: root
user.notprivileged: nobody

# Global auth method
method: username

# Allow all clients (tighten if needed)
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}

# Proxy rules
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect
}
EOF

# Ensure auth user exists (allow numeric)
if id -u "$AUTH_USER" >/dev/null 2>&1; then
  echo "[*] User $AUTH_USER exists, updating password"
else
  echo "[*] Creating user $AUTH_USER"
  useradd -M --badname "$AUTH_USER" || true
fi
echo "${AUTH_USER}:${AUTH_PASS}" | chpasswd

# Enable dynamic iface refresh on each start
mkdir -p /usr/local/sbin
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

systemctl daemon-reload
systemctl enable --now danted || true

echo "---- Listen check ----"
if ! ss -tlnp | grep -q ":${SOCKS_PORT}"; then
  echo "danted not listening on :${SOCKS_PORT}, recent logs:"
  journalctl -u danted -n 120 --no-pager || true
  exit 1
fi

PUB_IP="$(curl -s --max-time 3 https://ifconfig.me || hostname -I | awk '{print $1; exit}')"
echo
echo "✅ Done. SOCKS5 ready."
echo "socks5://${AUTH_USER}:${AUTH_PASS}@${PUB_IP}:${SOCKS_PORT}"
echo
echo "Tip: open TCP ${SOCKS_PORT} in your cloud security group if connecting from the Internet."
