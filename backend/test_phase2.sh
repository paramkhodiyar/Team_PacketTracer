#!/usr/bin/env bash
set -e

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
DNSMASQ_BIN="/opt/homebrew/sbin/dnsmasq"
NGINX_BIN="/opt/homebrew/bin/nginx"

if [ ! -x "$NGINX_BIN" ]; then
    NGINX_BIN="$(command -v nginx)"
fi

echo "================================================================="
echo "=== Extension A: Primary and Backup DNS Resolution & Failover ==="
echo "================================================================="
echo "[+] Querying Primary DNS (127.0.0.11):"
dig @127.0.0.11 app.packettracers.test +short
echo "[+] Querying Backup DNS (127.0.0.14):"
dig @127.0.0.14 app.packettracers.test +short

echo "[+] Stopping Primary DNS..."
sudo kill "$(cat /tmp/dns1.pid)" && rm -f /tmp/dns1.pid
sleep 1

echo "[+] Verifying Backup DNS still resolves:"
dig @127.0.0.14 app.packettracers.test +short

echo "[+] Restarting Primary DNS for subsequent tests..."
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_primary.conf" -x /tmp/dns1.pid
sleep 1

echo ""
echo "================================================================="
echo "=== Extension B: DNS TTL Verification (30 Seconds) ============="
echo "================================================================="
dig @127.0.0.11 app.packettracers.test | grep -E "app\.packettracers\.test\.\s+[0-9]+\s+IN\s+A"

echo ""
echo "================================================================="
echo "=== Extension C: Packet Filter (pf) Firewall Rules =============="
echo "================================================================="
echo "[+] Backing up current pf rules to pf_backup.rules..."
sudo pfctl -sr > "$SIM_DIR/pf_backup.rules" 2>/dev/null || true

echo "[+] Creating and loading temporary pf rules for lo0..."
cat << 'EOF' > /tmp/phase2_pf.rules
block return in quick on lo0 proto tcp from 127.0.0.11 to any port 3001
pass in quick on lo0 proto tcp from 127.0.0.12 to any port 3001
pass quick on lo0 all
EOF

sudo pfctl -e -f /tmp/phase2_pf.rules 2>/dev/null || sudo pfctl -f /tmp/phase2_pf.rules

echo "[+] Testing direct access from 127.0.0.11 to Backend A (should be blocked):"
if curl --interface 127.0.0.11 --connect-timeout 2 -s http://127.0.0.13:3001/api/status; then
    echo "[-] Error: Direct request succeeded unexpectedly"
else
    echo "[+] Direct access successfully blocked by pf"
fi

echo "[+] Testing proxied access via Edge Proxy 127.0.0.12 (should be allowed):"
curl -k -s --resolve app.packettracers.test:443:127.0.0.12 https://app.packettracers.test/api/status
echo ""

echo "[+] Restoring pf rules from backup..."
if [ -s "$SIM_DIR/pf_backup.rules" ]; then
    sudo pfctl -f "$SIM_DIR/pf_backup.rules" 2>/dev/null || true
else
    sudo pfctl -d 2>/dev/null || true
fi
rm -f /tmp/phase2_pf.rules
echo "[+] pf rules restored."

echo ""
echo "================================================================="
echo "=== Extension D: Load Balancing and Backend Failover ============"
echo "================================================================="
echo "[+] Querying Edge Proxy 6 times to show A/B alternation:"
for i in {1..6}; do
    curl -k -s --resolve app.packettracers.test:443:127.0.0.12 https://app.packettracers.test/api/status
    echo ""
done

echo "[+] Stopping Backend A (127.0.0.13)..."
kill "$(cat /tmp/backend_a.pid)" && rm -f /tmp/backend_a.pid
sleep 1

echo "[+] Querying Edge Proxy 4 times (all traffic should route to Backend B):"
for i in {1..4}; do
    curl -k -s --resolve app.packettracers.test:443:127.0.0.12 https://app.packettracers.test/api/status
    echo ""
done

echo "[+] Restarting Backend A (127.0.0.13)..."
python3 "$SIM_DIR/backend.py" 127.0.0.13 A >/dev/null 2>&1 &
echo $! > /tmp/backend_a.pid
sleep 1

echo "[+] Verifying Backend A is back in rotation:"
for i in {1..4}; do
    curl -k -s --resolve app.packettracers.test:443:127.0.0.12 https://app.packettracers.test/api/status
    echo ""
done

echo ""
echo "================================================================="
echo "=== Extension E: Standby Edge Proxy Activation & DNS Migration =="
echo "================================================================="
echo "[+] Starting Standby Edge Proxy on 127.0.0.14:443..."
sudo "$NGINX_BIN" -c "$SIM_DIR/nginx_standby.conf"
sleep 1

echo "[+] Updating DNS configuration to point to Standby Edge (127.0.0.14)..."
sed -i '' 's/127.0.0.12/127.0.0.14/g' "$SIM_DIR/dns_primary.conf" "$SIM_DIR/dns_backup.conf"

echo "[+] Reloading dnsmasq instances..."
sudo kill "$(cat /tmp/dns1.pid)" 2>/dev/null || true
sudo kill "$(cat /tmp/dns2.pid)" 2>/dev/null || true
sleep 1
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_primary.conf" -x /tmp/dns1.pid
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_backup.conf" -x /tmp/dns2.pid
sleep 1

RESOLVED_IP=$(dig @127.0.0.11 app.packettracers.test +short)
echo "[+] DNS resolution now yields: $RESOLVED_IP"

echo "[+] Verifying curl connects to Standby Edge (127.0.0.14):"
curl -v -k --resolve "app.packettracers.test:443:$RESOLVED_IP" "https://app.packettracers.test/api/status" 2>&1 | grep -E "Connected to|X-Backend"

echo "[+] Reverting DNS configuration to Primary Edge (127.0.0.12)..."
sed -i '' 's/127.0.0.14/127.0.0.12/g' "$SIM_DIR/dns_primary.conf" "$SIM_DIR/dns_backup.conf"
sudo kill "$(cat /tmp/dns1.pid)" 2>/dev/null || true
sudo kill "$(cat /tmp/dns2.pid)" 2>/dev/null || true
sleep 1
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_primary.conf" -x /tmp/dns1.pid
sudo "$DNSMASQ_BIN" -C "$SIM_DIR/dns_backup.conf" -x /tmp/dns2.pid

echo "[+] Stopping Standby Edge Proxy..."
if [ -f /tmp/nginx_standby.pid ]; then
    sudo kill "$(cat /tmp/nginx_standby.pid)" && rm -f /tmp/nginx_standby.pid
fi

echo "[+] Extension E complete."
