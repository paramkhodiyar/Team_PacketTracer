#!/usr/bin/env bash
set -e

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
DNSMASQ_BIN="/opt/homebrew/sbin/dnsmasq"
NGINX_BIN="/opt/homebrew/bin/nginx"

if [ ! -x "$NGINX_BIN" ]; then
    NGINX_BIN="$(command -v nginx)"
fi

echo "[*] Configuring lo0 loopback aliases (127.0.0.11 - 127.0.0.14)..."
for ip in 127.0.0.11 127.0.0.12 127.0.0.13 127.0.0.14; do
    sudo ifconfig lo0 alias "$ip" 255.255.255.255
done

echo "[*] Stopping Homebrew default dnsmasq and nginx services..."
brew services stop dnsmasq 2>/dev/null || true
brew services stop nginx 2>/dev/null || true
sudo pkill -f 'dnsmasq' 2>/dev/null || true
sudo pkill -f 'nginx' 2>/dev/null || true

if [ ! -f /opt/homebrew/etc/nginx/server.crt ] || [ ! -f /opt/homebrew/etc/nginx/server.key ]; then
    echo "[*] Generating SSL certificates at /opt/homebrew/etc/nginx/..."
    sudo mkdir -p /opt/homebrew/etc/nginx
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /opt/homebrew/etc/nginx/server.key \
        -out /opt/homebrew/etc/nginx/server.crt \
        -subj "/CN=*.packettracers.test" 2>/dev/null
fi

echo "[*] Starting Backend A (127.0.0.13:3001) and Backend B (127.0.0.14:3001)..."
python3 "$SIM_DIR/backend.py" 127.0.0.13 A >/dev/null 2>&1 &
echo $! > /tmp/backend_a.pid
python3 "$SIM_DIR/backend.py" 127.0.0.14 B >/dev/null 2>&1 &
echo $! > /tmp/backend_b.pid

echo "[*] Starting Primary DNS (127.0.0.11) and Backup DNS (127.0.0.14)..."
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_primary.conf" -x /tmp/dns1.pid
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_backup.conf" -x /tmp/dns2.pid

echo "[*] Starting Primary Edge Proxy Nginx (127.0.0.12:443)..."
sudo "$NGINX_BIN" -c "$SIM_DIR/nginx_primary.conf"

sleep 1

echo "[*] Verifying topology reachability..."
echo " - DNS Primary: $(dig @127.0.0.11 app.packettracers.test +short)"
echo " - DNS Backup:  $(dig @127.0.0.14 app.packettracers.test +short)"
echo " - Backend A:   $(curl -s http://127.0.0.13:3001/api/status)"
echo " - Backend B:   $(curl -s http://127.0.0.14:3001/api/status)"
echo " - Primary Edge Proxy: $(curl -k -s --resolve app.packettracers.test:443:127.0.0.12 https://app.packettracers.test/api/status)"
echo "[+] Topology setup complete and verified."
