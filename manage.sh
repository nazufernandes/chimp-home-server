#!/usr/bin/env bash
# ==============================================================================
#  Chimp Home Server — Service Lifecycle Manager
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$LOG_DIR" "$DATA_DIR/drop/files" "$DATA_DIR/photos" "$DATA_DIR/shared" "$DATA_DIR/cron" "$DATA_DIR/sites"

# Keep device awake if running inside Termux
if which termux-wake-lock > /dev/null 2>&1; then
    termux-wake-lock
fi

# Detect local IP
IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

start_services() {
    echo "Starting Chimp Home Server services..."

    # Ensure wake lock is active
    which termux-wake-lock > /dev/null 2>&1 && termux-wake-lock

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

    if ! pgrep nginx > /dev/null; then
        nginx > "$LOG_DIR/gateway.log" 2>&1
        echo "[✓] Unified Gateway & Dashboard started on http://${IP}:8080/ (Nginx)"
    else
        nginx -s reload 2>/dev/null || true
        echo "[✓] Unified Gateway reloaded (Nginx)"
    fi

    # 2. Modern Web File Manager (port 8081 - Flask)
    if ! pgrep -f "files/app.py" > /dev/null; then
        nohup python "$BASE_DIR/files/app.py" > "$LOG_DIR/files.log" 2>&1 &
        echo "[✓] Web File Manager started on http://${IP}:8080/files/ (PID $!)"
    else
        echo "[-] File Manager already running"
    fi

    # 3. ChimpDrop - Universal Clipboard (port 8082 - Flask)
    if ! pgrep -f "drop/app.py" > /dev/null; then
        nohup python "$BASE_DIR/drop/app.py" > "$LOG_DIR/drop.log" 2>&1 &
        echo "[✓] ChimpDrop (Clipboard) started on http://${IP}:8080/drop/ (PID $!)"
    else
        echo "[-] ChimpDrop already running"
    fi

    # 4. Hardware Telemetry Monitor (port 8090)
    if ! pgrep -f "monitor/monitor.py" > /dev/null; then
        nohup python "$BASE_DIR/monitor/monitor.py" > "$LOG_DIR/monitor.log" 2>&1 &
        echo "[✓] Monitor API started on http://${IP}:8080/api/status (PID $!)"
    else
        echo "[-] Monitor API already running"
    fi

    # 5. Photos App (port 8091)
    if ! pgrep -f "photos/app.py" > /dev/null; then
        nohup python "$BASE_DIR/photos/app.py" > "$LOG_DIR/photos.log" 2>&1 &
        echo "[✓] Photo Library started on http://${IP}:8080/photos/ (PID $!)"
    else
        echo "[-] Photo Library already running"
    fi

    # 6. ChimpCron - Scheduled Automation (port 8083)
    if ! pgrep -f "cron/app.py" > /dev/null; then
        nohup python "$BASE_DIR/cron/app.py" > "$LOG_DIR/cron.log" 2>&1 &
        echo "[✓] ChimpCron started on http://${IP}:8080/cron/ (PID $!)"
    else
        echo "[-] ChimpCron already running"
    fi

    echo ""
    echo "=========================================================="
    echo "  🎉 All services active! Open in your browser:"
    echo "  👉  http://${IP}:8080/"
    echo "=========================================================="
}

stop_services() {
    echo "Stopping all Chimp Home Server services..."
    nginx -s stop 2>/dev/null || pkill -9 nginx 2>/dev/null && echo "[✓] Gateway (Nginx) stopped" || true
    pkill -9 -f "files/app.py" 2>/dev/null && echo "[✓] File Manager stopped" || true
    pkill -9 -f "drop/app.py" 2>/dev/null && echo "[✓] ChimpDrop stopped" || true
    pkill -9 -f "monitor/monitor.py" 2>/dev/null && echo "[✓] Monitor API stopped" || true
    pkill -9 -f "photos/app.py" 2>/dev/null && echo "[✓] Photo Library stopped" || true
    pkill -9 -f "cron/app.py" 2>/dev/null && echo "[✓] ChimpCron stopped" || true
    pkill -9 -f "http.server 8080" 2>/dev/null || true
}

status_services() {
    echo "=== Chimp Home Server Status ==="
    echo -n "SSH Server:             "
    pgrep -x sshd > /dev/null 2>&1 && echo "RUNNING (PID $(pgrep -x sshd | head -n 1))" || echo "STOPPED"

    echo -n "Gateway (8080 - Nginx): "
    pgrep nginx > /dev/null && echo "RUNNING (PID $(pgrep nginx | head -n 1))" || echo "STOPPED"

    echo -n "File Manager (8081):    "
    pgrep -f "files/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'files/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "ChimpDrop (8082):       "
    pgrep -f "drop/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'drop/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "ChimpCron (8083):       "
    pgrep -f "cron/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'cron/app.py' | head -n 1))" || echo "STOPPED"

    echo -n "Monitor API (8090):     "
    pgrep -f "monitor/monitor.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'monitor/monitor.py' | head -n 1))" || echo "STOPPED"

    echo -n "Photos App (8091):      "
    pgrep -f "photos/app.py" > /dev/null && echo "RUNNING (PID $(pgrep -f 'photos/app.py' | head -n 1))" || echo "STOPPED"
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
