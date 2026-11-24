#!/usr/bin/env bash

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[*] Stopping simulation processes..."
for pidfile in /tmp/dns1.pid /tmp/dns2.pid /tmp/nginx_primary.pid /tmp/nginx_standby.pid /tmp/backend_a.pid /tmp/backend_b.pid; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null)
        if [ -n "$pid" ]; then
            sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
done

echo "[*] Restoring pf firewall rules..."
if [ -s "$SIM_DIR/pf_backup.rules" ]; then
    sudo pfctl -f "$SIM_DIR/pf_backup.rules" 2>/dev/null || true
    rm -f "$SIM_DIR/pf_backup.rules"
else
    sudo pfctl -d 2>/dev/null || true
fi

echo "[*] Removing lo0 loopback aliases..."
for ip in 127.0.0.11 127.0.0.12 127.0.0.13 127.0.0.14; do
    sudo ifconfig lo0 -alias "$ip" 2>/dev/null || true
done

echo "[+] Cleanup complete."
