#!/usr/bin/env bash
# ==============================================================================
#  Chimp Home Server — Service Lifecycle Manager
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$LOG_DIR" "$DATA_DIR/drop/files" "$DATA_DIR/photos" "$DATA_DIR/shared" "$DATA_DIR/cron" "$DATA_DIR/sites"

# Keep device awake if running inside Termux foreground session
# (Do not call termux-wake-lock automatically over SSH as Android kills background callers)

# Detect local IP
IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

is_service_enabled() {
    local svc="$1"
    local state_file="$BASE_DIR/data/services_state.json"
    if [ ! -f "$state_file" ]; then
        return 0
    fi
    python -c "
import json, sys
try:
    with open('$state_file') as f:
        d = json.load(f)
    if not d.get('$svc', {}).get('enabled', True):
        sys.exit(1)
except Exception:
    pass
sys.exit(0)
" 2>/dev/null
    return $?
}

start_services() {
    echo "Starting Chimp Home Server services..."

    # 0. SSH Daemon
    if which sshd > /dev/null 2>&1; then
        if ! pgrep -x sshd > /dev/null 2>&1; then
            sshd
            echo "[✓] SSH Daemon started"
        else
            echo "[-] SSH Daemon already running"
        fi
    fi

    # 1. Gateway & Dashboard (port 8080 - Nginx)
    pkill -9 -f "http.server 8080" 2>/dev/null || true
    NGINX_TARGET=""
    if [ -d "/data/data/com.termux/files/usr/etc/nginx" ]; then
        NGINX_TARGET="/data/data/com.termux/files/usr/etc/nginx/nginx.conf"
    elif [ -d "/etc/nginx" ]; then
        NGINX_TARGET="/etc/nginx/nginx.conf"
    fi
    if [ -n "$NGINX_TARGET" ] && [ -f "$BASE_DIR/config/nginx.conf" ]; then
        sed "s|__CHIMP_ROOT__|$BASE_DIR|g" "$BASE_DIR/config/nginx.conf" > "$NGINX_TARGET"
    fi

    if ! pgrep -f "nginx" > /dev/null; then
        nginx > "$LOG_DIR/gateway.log" 2>&1
        echo "[✓] Unified Gateway & Dashboard started on http://${IP}:8080/ (Nginx)"
    else
        nginx -s reload 2>/dev/null || true
        echo "[✓] Unified Gateway reloaded (Nginx)"
    fi

    # 2. ChimpDrive - Cloud Storage & Explorer (port 8081 - Flask)
    if is_service_enabled "files"; then
        if ! pgrep -f "files/app.py" > /dev/null; then
            nohup python "$BASE_DIR/files/app.py" > "$LOG_DIR/files.log" 2>&1 & disown
            echo "[✓] ChimpDrive started on http://${IP}:8080/files/ (PID $!)"
        else
            echo "[-] ChimpDrive already running"
        fi
    else
        echo "[-] ChimpDrive disabled in Control Panel (skipping)"
    fi

    # 3. ChimpDrop - Universal Clipboard (port 8082 - Flask)
    if is_service_enabled "drop"; then
        if ! pgrep -f "drop/app.py" > /dev/null; then
            nohup python "$BASE_DIR/drop/app.py" > "$LOG_DIR/drop.log" 2>&1 & disown
            echo "[✓] ChimpDrop (Clipboard) started on http://${IP}:8080/drop/ (PID $!)"
        else
            echo "[-] ChimpDrop already running"
        fi
    else
        echo "[-] ChimpDrop disabled in Control Panel (skipping)"
    fi

    # 4. Hardware Telemetry Monitor (port 8090)
    if ! pgrep -f "monitor/monitor.py" > /dev/null; then
        nohup python "$BASE_DIR/monitor/monitor.py" > "$LOG_DIR/monitor.log" 2>&1 & disown
        echo "[✓] Monitor API started on http://${IP}:8080/api/status (PID $!)"
    else
        echo "[-] Monitor API already running"
    fi

    # 5. ChimpPix - Photo Library & EXIF Gallery (port 8091)
    if is_service_enabled "photos"; then
        if ! pgrep -f "photos/app.py" > /dev/null; then
            nohup python "$BASE_DIR/photos/app.py" > "$LOG_DIR/photos.log" 2>&1 & disown
            echo "[✓] ChimpPix started on http://${IP}:8080/photos/ (PID $!)"
        else
            echo "[-] ChimpPix already running"
        fi
    else
        echo "[-] ChimpPix disabled in Control Panel (skipping)"
    fi

    # 6. ChimpCron - Scheduled Automation (port 8083)
    if is_service_enabled "cron"; then
        if ! pgrep -f "cron/app.py" > /dev/null; then
            nohup python "$BASE_DIR/cron/app.py" > "$LOG_DIR/cron.log" 2>&1 & disown
            echo "[✓] ChimpCron started on http://${IP}:8080/cron/ (PID $!)"
        else
            echo "[-] ChimpCron already running"
        fi
    else
        echo "[-] ChimpCron disabled in Control Panel (skipping)"
    fi

    # 7. Permanent Public Internet Tunnel (Ngrok)
    if is_service_enabled "tunnel"; then
        NGROK_BIN=""
        if [ -x "$HOME/ngrok" ]; then
            NGROK_BIN="$HOME/ngrok"
        elif which ngrok > /dev/null 2>&1; then
            NGROK_BIN="$(which ngrok)"
        fi

        TUNNEL_DOMAIN=""
        if [ -f "$DATA_DIR/tunnel.conf" ]; then
            TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
        elif [ -f "$BASE_DIR/config/tunnel.conf" ]; then
            TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
        fi

        if [ -n "$NGROK_BIN" ] && [ -n "$TUNNEL_DOMAIN" ]; then
            if ! pgrep -f "ngrok http" > /dev/null; then
                nohup termux-chroot "$NGROK_BIN" http --url="https://${TUNNEL_DOMAIN}" 8080 > "$LOG_DIR/ngrok.log" 2>&1 & disown
                echo "[✓] Public Tunnel started on https://${TUNNEL_DOMAIN} (PID $!)"
            else
                echo "[-] Public Tunnel already running (https://${TUNNEL_DOMAIN})"
            fi
        fi
    else
        echo "[-] Public Tunnel disabled in Control Panel (skipping)"
    fi

    echo ""
    echo "=========================================================="
    echo "  🎉 All services active! Open in your browser:"
    echo "  👉  Local LAN: http://${IP}:8080/"
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if [ -n "$TUNNEL_DOMAIN" ] && pgrep -f "ngrok http" > /dev/null 2>&1; then
        echo "  👉  Internet:  https://${TUNNEL_DOMAIN}/"
    fi
    echo "=========================================================="
}

stop_services() {
    echo "Stopping all Chimp Home Server services..."
    nginx -s stop 2>/dev/null || pkill -9 nginx 2>/dev/null && echo "[✓] Gateway (Nginx) stopped" || true
    pkill -9 -f "files/app.py" 2>/dev/null && echo "[✓] ChimpDrive stopped" || true
    pkill -9 -f "drop/app.py" 2>/dev/null && echo "[✓] ChimpDrop stopped" || true
    pkill -9 -f "monitor/monitor.py" 2>/dev/null && echo "[✓] Monitor API stopped" || true
    pkill -9 -f "photos/app.py" 2>/dev/null && echo "[✓] ChimpPix stopped" || true
    pkill -9 -f "cron/app.py" 2>/dev/null && echo "[✓] ChimpCron stopped" || true
    pkill -9 -f "ngrok http" 2>/dev/null && echo "[✓] Public Tunnel stopped" || true
    pkill -9 -f "cloudflared" 2>/dev/null || true
    pkill -9 -f "http.server 8080" 2>/dev/null || true
}

status_services() {
    echo "=== Chimp Home Server Status ==="
    echo -n "SSH Server:             "
    pgrep -x sshd > /dev/null 2>&1 && echo "RUNNING (PID $(pgrep -x sshd | head -n 1))" || echo "STOPPED"

    echo -n "Gateway (8080 - Nginx): "
    pgrep -f "nginx" > /dev/null && echo "RUNNING (PID $(pgrep -f "nginx" | head -n 1))" || echo "STOPPED"

    echo -n "ChimpDrive (8081):      "
    pgrep -f "files/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'files/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "ChimpDrop (8082):       "
    pgrep -f "drop/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'drop/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "ChimpCron (8083):       "
    pgrep -f "cron/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'cron/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "Monitor API (8090):     "
    pgrep -f "monitor/monitor.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'monitor/monitor.py' | head -n 1))" || echo "STOPPED"

    echo -n "ChimpPix (8091):        "
    pgrep -f "photos/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'photos/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "Public Tunnel (Ngrok):  "
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if pgrep -f "ngrok http" > /dev/null 2>&1; then
        echo "RUNNING (https://${TUNNEL_DOMAIN}/) (PID $(pgrep -f 'ngrok http' | head -n 1))"
    else
        echo "STOPPED"
    fi
}

case "$1" in
    start)   start_services ;;
    stop)    stop_services ;;
    restart) stop_services; sleep 1; start_services ;;
    status)  status_services ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
