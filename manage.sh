#!/usr/bin/env bash
# ==============================================================================
#  Chimp Home Server — Service Lifecycle Manager
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$LOG_DIR" "$DATA_DIR/drop/files" "$DATA_DIR/photos" "$DATA_DIR/shared" "$DATA_DIR/cron" "$DATA_DIR/sites"

# Keep device awake in Termux
termux-wake-lock 2>/dev/null || true

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

check_port() {
    local port="$1"
    python -c "import socket, sys; s=socket.socket(); s.settimeout(0.5); sys.exit(s.connect_ex(('127.0.0.1', $port)))" 2>/dev/null
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

    # 1. Update Nginx configuration
    NGINX_TARGET=""
    if [ -d "/data/data/com.termux/files/usr/etc/nginx" ]; then
        NGINX_TARGET="/data/data/com.termux/files/usr/etc/nginx/nginx.conf"
    elif [ -d "/etc/nginx" ]; then
        NGINX_TARGET="/etc/nginx/nginx.conf"
    fi
    if [ -n "$NGINX_TARGET" ] && [ -f "$BASE_DIR/config/nginx.conf" ]; then
        sed "s|__CHIMP_ROOT__|$BASE_DIR|g" "$BASE_DIR/config/nginx.conf" > "$NGINX_TARGET"
    fi

    # 2. TMUX Orchestration
    # Using tmux ensures services survive SSH disconnects and MIUI battery manager process reaping
    if which tmux > /dev/null 2>&1; then
        if ! tmux has-session -t chimp 2>/dev/null; then
            tmux new-session -d -s chimp -n gateway
        fi

        # Gateway (8080 - Nginx)
        if ! check_port 8080; then
            tmux send-keys -t chimp:gateway "while true; do nginx -g 'daemon off;'; sleep 2; done" C-m
            echo "[✓] Unified Gateway & Dashboard started on http://${IP}:8080/ (Nginx)"
        else
            echo "[-] Unified Gateway already running (port 8080)"
        fi

        # ChimpDrive (8081)
        if is_service_enabled "files"; then
            if ! check_port 8081; then
                tmux new-window -t chimp:1 -n files 2>/dev/null || true
                tmux send-keys -t chimp:files "while true; do python $BASE_DIR/files/app.py; sleep 2; done" C-m
                echo "[✓] ChimpDrive started on http://${IP}:8080/files/"
            else
                echo "[-] ChimpDrive already running (port 8081)"
            fi
        else
            echo "[-] ChimpDrive disabled in Control Panel (skipping)"
        fi

        # ChimpDrop (8082)
        if is_service_enabled "drop"; then
            if ! check_port 8082; then
                tmux new-window -t chimp:2 -n drop 2>/dev/null || true
                tmux send-keys -t chimp:drop "while true; do python $BASE_DIR/drop/app.py; sleep 2; done" C-m
                echo "[✓] ChimpDrop (Clipboard) started on http://${IP}:8080/drop/"
            else
                echo "[-] ChimpDrop already running (port 8082)"
            fi
        else
            echo "[-] ChimpDrop disabled in Control Panel (skipping)"
        fi

        # ChimpCron (8083)
        if is_service_enabled "cron"; then
            if ! check_port 8083; then
                tmux new-window -t chimp:3 -n cron 2>/dev/null || true
                tmux send-keys -t chimp:cron "while true; do python $BASE_DIR/cron/app.py; sleep 2; done" C-m
                echo "[✓] ChimpCron started on http://${IP}:8080/cron/"
            else
                echo "[-] ChimpCron already running (port 8083)"
            fi
        else
            echo "[-] ChimpCron disabled in Control Panel (skipping)"
        fi

        # Monitor API (8090)
        if ! check_port 8090; then
            tmux new-window -t chimp:4 -n monitor 2>/dev/null || true
            tmux send-keys -t chimp:monitor "while true; do python $BASE_DIR/monitor/monitor.py; sleep 2; done" C-m
            echo "[✓] Monitor API started on http://${IP}:8080/api/status"
        else
            echo "[-] Monitor API already running (port 8090)"
        fi

        # ChimpPix (8091)
        if is_service_enabled "photos"; then
            if ! check_port 8091; then
                tmux new-window -t chimp:5 -n photos 2>/dev/null || true
                tmux send-keys -t chimp:photos "while true; do python $BASE_DIR/photos/app.py; sleep 2; done" C-m
                echo "[✓] ChimpPix started on http://${IP}:8080/photos/"
            else
                echo "[-] ChimpPix already running (port 8091)"
            fi
        else
            echo "[-] ChimpPix disabled in Control Panel (skipping)"
        fi

        # Public Tunnel (Ngrok)
        if is_service_enabled "tunnel"; then
            TUNNEL_DOMAIN=""
            [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
            [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"

            if [ -n "$TUNNEL_DOMAIN" ]; then
                if ! check_port 4040; then
                    tmux new-window -t chimp:6 -n ngrok 2>/dev/null || true
                    tmux send-keys -t chimp:ngrok "while true; do termux-chroot $HOME/ngrok http --url=https://${TUNNEL_DOMAIN} 8080; sleep 5; done" C-m
                    echo "[✓] Public Tunnel started on https://${TUNNEL_DOMAIN}"
                else
                    echo "[-] Public Tunnel already running (https://${TUNNEL_DOMAIN})"
                fi
            fi
        else
            echo "[-] Public Tunnel disabled in Control Panel (skipping)"
        fi
    fi

    echo ""
    echo "=========================================================="
    echo "  🎉 All services active! Open in your browser:"
    echo "  👉  Local LAN: http://${IP}:8080/"
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if [ -n "$TUNNEL_DOMAIN" ] && check_port 4040; then
        echo "  👉  Internet:  https://${TUNNEL_DOMAIN}/"
    fi
    echo "=========================================================="
}

stop_services() {
    echo "Stopping all Chimp Home Server services..."
    tmux kill-session -t chimp 2>/dev/null || true
    nginx -s stop 2>/dev/null || pkill -9 -x nginx 2>/dev/null || true
    pkill -9 -f "server/files/app.py" 2>/dev/null || true
    pkill -9 -f "server/drop/app.py" 2>/dev/null || true
    pkill -9 -f "server/monitor/monitor.py" 2>/dev/null || true
    pkill -9 -f "server/photos/app.py" 2>/dev/null || true
    pkill -9 -f "server/cron/app.py" 2>/dev/null || true
    pkill -9 -f "termux-chroot" 2>/dev/null || true
    pkill -9 -x ngrok 2>/dev/null || true
    echo "[✓] All services stopped"
}

status_services() {
    echo "=== Chimp Home Server Status ==="
    echo -n "SSH Server:             "
    pgrep -x sshd > /dev/null 2>&1 && echo "RUNNING (PID $(pgrep -x sshd | head -n 1))" || echo "STOPPED"

    echo -n "Gateway (8080 - Nginx): "
    check_port 8080 && echo "RUNNING (Port 8080)" || echo "STOPPED"

    echo -n "ChimpDrive (8081):      "
    check_port 8081 && echo "RUNNING (Port 8081)" || echo "STOPPED"

    echo -n "ChimpDrop (8082):       "
    check_port 8082 && echo "RUNNING (Port 8082)" || echo "STOPPED"

    echo -n "ChimpCron (8083):       "
    check_port 8083 && echo "RUNNING (Port 8083)" || echo "STOPPED"

    echo -n "Monitor API (8090):     "
    check_port 8090 && echo "RUNNING (Port 8090)" || echo "STOPPED"

    echo -n "ChimpPix (8091):        "
    check_port 8091 && echo "RUNNING (Port 8091)" || echo "STOPPED"

    echo -n "Public Tunnel (Ngrok):  "
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if check_port 4040; then
        echo "RUNNING (https://${TUNNEL_DOMAIN}/) (Port 4040)"
    else
        echo "STOPPED"
    fi
}

case "$1" in
    start)   start_services ;;
    stop)    stop_services ;;
    restart) stop_services; sleep 2; start_services ;;
    status)  status_services ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
