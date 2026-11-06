#!/usr/bin/env bash
# ==============================================================================
#  🐒 Chimp Home Server — Unified CLI & Service Lifecycle Manager
# ==============================================================================

# 1. Resolve true base directory even if called via symlink (e.g. /data/data/com.termux/files/usr/bin/chimp)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
BASE_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# Fallback to standard server directory if not found
if [ ! -d "$BASE_DIR/monitor" ] && [ -d "$HOME/server" ]; then
    BASE_DIR="$HOME/server"
fi

LOG_DIR="$BASE_DIR/logs"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$LOG_DIR" "$DATA_DIR/drop/files" "$DATA_DIR/photos" "$DATA_DIR/shared" "$DATA_DIR/cron" "$DATA_DIR/sites" "$HOME/ChimpDrive"

# ANSI Colors
GREEN='\033[38;5;49m'
BLUE='\033[38;5;39m'
PURPLE='\033[38;5;141m'
YELLOW='\033[38;5;220m'
RED='\033[38;5;203m'
DIM='\033[38;5;244m'
BOLD='\033[1m'
NC='\033[0m'

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

get_public_ssh() {
    python -c "
import urllib.request, json, sys
for port in [4040, 4041, 4042]:
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/tunnels', timeout=0.5) as r:
            data = json.load(r)
            for t in data.get('tunnels', []):
                if t.get('proto') == 'tcp':
                    url = t.get('public_url', '').replace('tcp://', '')
                    host, p = url.split(':')
                    print(f'ssh u0_a223@{host} -p {p}')
                    sys.exit(0)
    except Exception:
        pass
" 2>/dev/null
}

start_services() {
    echo -e "${BOLD}${GREEN}  🐒 Starting Chimp Home Server services...${NC}"

    # Ensure .env exists with default admin password if missing
    if [ ! -f "$BASE_DIR/.env" ]; then
        if [ -f "$BASE_DIR/.env.example" ]; then
            cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
        else
            echo "CHIMP_ADMIN_PASSWORD=banana" > "$BASE_DIR/.env"
            echo "ADMIN_PASSWORD=banana" >> "$BASE_DIR/.env"
        fi
        chmod 600 "$BASE_DIR/.env" 2>/dev/null || true
    fi

    # 0. SSH Daemon
    if which sshd > /dev/null 2>&1; then
        if ! pgrep -x sshd > /dev/null 2>&1; then
            sshd
            echo -e "  ${GREEN}[✓]${NC} SSH Daemon started (Port 8022)"
        else
            echo -e "  ${DIM}[-] SSH Daemon already running (Port 8022)${NC}"
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
    if which tmux > /dev/null 2>&1; then
        if ! tmux has-session -t chimp 2>/dev/null; then
            tmux new-session -d -s chimp -n gateway
        fi

        # Gateway (8080 - Nginx)
        if ! check_port 8080; then
            tmux send-keys -t chimp:gateway "while true; do nginx -g 'daemon off;'; sleep 2; done" C-m
            echo -e "  ${GREEN}[✓]${NC} Unified Gateway started on http://${IP}:8080/ (Nginx)"
        else
            echo -e "  ${DIM}[-] Unified Gateway already running (Port 8080)${NC}"
        fi

        # Monitor API (8090)
        if ! check_port 8090; then
            tmux new-window -t chimp:1 -n monitor 2>/dev/null || true
            tmux send-keys -t chimp:monitor "while true; do python $BASE_DIR/monitor/monitor.py; sleep 2; done" C-m
            echo -e "  ${GREEN}[✓]${NC} Monitor API started on http://${IP}:8080/api/status"
        else
            echo -e "  ${DIM}[-] Monitor API already running (Port 8090)${NC}"
        fi

        # ChimpDrive (8081)
        if is_service_enabled "files"; then
            if ! check_port 8081; then
                tmux new-window -t chimp:2 -n files 2>/dev/null || true
                tmux send-keys -t chimp:files "while true; do python $BASE_DIR/files/app.py; sleep 2; done" C-m
                echo -e "  ${GREEN}[✓]${NC} ChimpDrive started on http://${IP}:8080/files/"
            else
                echo -e "  ${DIM}[-] ChimpDrive already running (Port 8081)${NC}"
            fi
        else
            echo -e "  ${DIM}[-] ChimpDrive disabled in Control Panel (skipping)${NC}"
        fi

        # ChimpDrop (8082)
        if is_service_enabled "drop"; then
            if ! check_port 8082; then
                tmux new-window -t chimp:3 -n drop 2>/dev/null || true
                tmux send-keys -t chimp:drop "while true; do python $BASE_DIR/drop/app.py; sleep 2; done" C-m
                echo -e "  ${GREEN}[✓]${NC} ChimpDrop (Clipboard) started on http://${IP}:8080/drop/"
            else
                echo -e "  ${DIM}[-] ChimpDrop already running (Port 8082)${NC}"
            fi
        else
            echo -e "  ${DIM}[-] ChimpDrop disabled in Control Panel (skipping)${NC}"
        fi

        # ChimpCron (8083)
        if is_service_enabled "cron"; then
            if ! check_port 8083; then
                tmux new-window -t chimp:4 -n cron 2>/dev/null || true
                tmux send-keys -t chimp:cron "while true; do python $BASE_DIR/cron/app.py; sleep 2; done" C-m
                echo -e "  ${GREEN}[✓]${NC} ChimpCron started on http://${IP}:8080/cron/"
            else
                echo -e "  ${DIM}[-] ChimpCron already running (Port 8083)${NC}"
            fi
        else
            echo -e "  ${DIM}[-] ChimpCron disabled in Control Panel (skipping)${NC}"
        fi

        # ChimpPix (8091)
        if is_service_enabled "photos"; then
            if ! check_port 8091; then
                tmux new-window -t chimp:5 -n photos 2>/dev/null || true
                tmux send-keys -t chimp:photos "while true; do python $BASE_DIR/photos/app.py; sleep 2; done" C-m
                echo -e "  ${GREEN}[✓]${NC} ChimpPix started on http://${IP}:8080/photos/"
            else
                echo -e "  ${DIM}[-] ChimpPix already running (Port 8091)${NC}"
            fi
        else
            echo -e "  ${DIM}[-] ChimpPix disabled in Control Panel (skipping)${NC}"
        fi

        # ChimpAI Neural Engine (8092 - Optional Module)
        if [ -f "$BASE_DIR/run_llama.sh" ] || [ -f "$HOME/run_llama.sh" ]; then
            if is_service_enabled "ai"; then
                if ! check_port 8092; then
                    AI_SCRIPT="$BASE_DIR/run_llama.sh"
                    [ ! -f "$AI_SCRIPT" ] && AI_SCRIPT="$HOME/run_llama.sh"
                    tmux new-window -t chimp:4 -n ai 2>/dev/null || true
                    tmux send-keys -t chimp:ai "while true; do $AI_SCRIPT; sleep 3; done" C-m
                    echo -e "  ${GREEN}[✓]${NC} ChimpAI started on http://${IP}:8080/chimpai/"
                else
                    echo -e "  ${DIM}[-] ChimpAI already running (Port 8092)${NC}"
                fi
            else
                echo -e "  ${DIM}[-] ChimpAI disabled in Control Panel (skipping)${NC}"
            fi
        fi

        # Public Tunnels (Ngrok Web + SSH)
        if is_service_enabled "tunnel"; then
            TUNNEL_DOMAIN=""
            [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
            [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"

            # Web Tunnel (Port 8080)
            if [ -n "$TUNNEL_DOMAIN" ]; then
                if ! check_port 4040; then
                    tmux new-window -t chimp:6 -n ngrok-web 2>/dev/null || true
                    tmux send-keys -t chimp:ngrok-web "while true; do termux-chroot $HOME/ngrok http --url=https://${TUNNEL_DOMAIN} 8080; sleep 5; done" C-m
                    echo -e "  ${GREEN}[✓]${NC} Public Web Tunnel started on https://${TUNNEL_DOMAIN}/"
                else
                    echo -e "  ${DIM}[-] Public Web Tunnel already running (https://${TUNNEL_DOMAIN}/)${NC}"
                fi
            fi

            # Remote SSH Tunnel (Port 8022)
            if ! check_port 4041; then
                tmux new-window -t chimp:7 -n ngrok-ssh 2>/dev/null || true
                tmux send-keys -t chimp:ngrok-ssh "while true; do termux-chroot $HOME/ngrok tcp 8022; sleep 5; done" C-m
                echo -e "  ${GREEN}[✓]${NC} Public SSH Tunnel started"
            else
                echo -e "  ${DIM}[-] Public SSH Tunnel already running${NC}"
            fi
        else
            echo -e "  ${DIM}[-] Public Tunnel disabled in Control Panel (skipping)${NC}"
        fi
    fi

    echo ""
    echo -e "${DIM}  ==========================================================${NC}"
    echo -e "  ${BOLD}${GREEN}🎉 All services active! Connect from anywhere:${NC}"
    echo -e "  👉  ${BOLD}Local LAN Web:${NC}  ${BLUE}http://${IP}:8080/${NC}"
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if [ -n "$TUNNEL_DOMAIN" ] && check_port 4040; then
        echo -e "  👉  ${BOLD}Internet Web:${NC}   ${GREEN}https://${TUNNEL_DOMAIN}/${NC}"
    fi
    SSH_CMD=$(get_public_ssh)
    if [ -n "$SSH_CMD" ]; then
        echo -e "  👉  ${BOLD}Remote SSH:${NC}     ${YELLOW}$SSH_CMD${NC}"
    fi
    echo -e "${DIM}  ==========================================================${NC}"
    echo ""
}

stop_services() {
    echo -e "${BOLD}${RED}  🛑 Stopping all Chimp Home Server services...${NC}"
    tmux kill-session -t chimp 2>/dev/null || true
    nginx -s stop 2>/dev/null || pkill -9 -x nginx 2>/dev/null || true
    pkill -9 -f "server/files/app.py" 2>/dev/null || true
    pkill -9 -f "server/drop/app.py" 2>/dev/null || true
    pkill -9 -f "server/monitor/monitor.py" 2>/dev/null || true
    pkill -9 -f "server/photos/app.py" 2>/dev/null || true
    pkill -9 -f "server/cron/app.py" 2>/dev/null || true
    pkill -9 -f "llama-server" 2>/dev/null || true
    pkill -9 -f "termux-chroot" 2>/dev/null || true
    pkill -9 -x ngrok 2>/dev/null || true
    echo -e "  ${GREEN}[✓]${NC} All services stopped cleanly."
}

status_services() {
    echo ""
    echo -e "${BOLD}${GREEN}  🐒  CHIMP HOME SERVER STATUS${NC}"
    echo -e "${DIM}  ========================================================${NC}"

    local load=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//')
    local mem=$(free -m 2>/dev/null | awk '/Mem:/ {print $3 "MB / " $2 "MB"}')
    local disk=$(df -h "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

    [ -n "$load" ] && echo -e "  ${DIM}System Load:${NC}   $load"
    [ -n "$mem" ]  && echo -e "  ${DIM}Memory:${NC}        $mem"
    [ -n "$disk" ] && echo -e "  ${DIM}Disk Storage:${NC}  $disk"
    echo -e "${DIM}  --------------------------------------------------------${NC}"

    print_status_line() {
        local name="$1"
        local status="$2"
        local detail="$3"
        if [ "$status" = "RUNNING" ]; then
            printf "  %-24s ${GREEN}● RUNNING${NC}  ${DIM}%s${NC}\n" "$name" "$detail"
        else
            printf "  %-24s ${RED}○ STOPPED${NC}\n" "$name"
        fi
    }

    if pgrep -x sshd > /dev/null 2>&1; then
        print_status_line "SSH Server" "RUNNING" "PID $(pgrep -x sshd | head -n 1), Port 8022"
    else
        print_status_line "SSH Server" "STOPPED" ""
    fi

    check_port 8080 && print_status_line "Gateway (Dashboard)" "RUNNING" "Port 8080 (Nginx)" || print_status_line "Gateway (Dashboard)" "STOPPED" ""
    check_port 8090 && print_status_line "Monitor API" "RUNNING" "Port 8090" || print_status_line "Monitor API" "STOPPED" ""
    check_port 8081 && print_status_line "ChimpDrive (Files)" "RUNNING" "Port 8081" || print_status_line "ChimpDrive (Files)" "STOPPED" ""
    check_port 8082 && print_status_line "ChimpDrop (Clipboard)" "RUNNING" "Port 8082" || print_status_line "ChimpDrop (Clipboard)" "STOPPED" ""
    check_port 8083 && print_status_line "ChimpCron (Scheduler)" "RUNNING" "Port 8083" || print_status_line "ChimpCron (Scheduler)" "STOPPED" ""
    check_port 8091 && print_status_line "ChimpPix (Photos)" "RUNNING" "Port 8091" || print_status_line "ChimpPix (Photos)" "STOPPED" ""

    if [ -f "$BASE_DIR/run_llama.sh" ] || [ -f "$HOME/run_llama.sh" ] || check_port 8092; then
        check_port 8092 && print_status_line "ChimpAI (Neural Engine)" "RUNNING" "Port 8092" || print_status_line "ChimpAI (Neural Engine)" "STOPPED" ""
    fi

    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if check_port 4040; then
        print_status_line "Public Web Tunnel" "RUNNING" "https://${TUNNEL_DOMAIN}/"
    else
        print_status_line "Public Web Tunnel" "STOPPED" ""
    fi

    SSH_CMD=$(get_public_ssh)
    if [ -n "$SSH_CMD" ]; then
        print_status_line "Public SSH Tunnel" "RUNNING" "$SSH_CMD"
    else
        print_status_line "Public SSH Tunnel" "STOPPED" ""
    fi

    echo -e "${DIM}  ========================================================${NC}"
    echo -e "  ${BOLD}Active Endpoints:${NC}"
    echo -e "  👉 Local LAN Web:   ${BLUE}http://${IP}:8080/${NC}"
    if [ -f "$BASE_DIR/run_llama.sh" ] || [ -f "$HOME/run_llama.sh" ] || check_port 8092; then
        if check_port 8092; then
            echo -e "  👉 Local ChimpAI:   ${BLUE}http://${IP}:8080/chimpai/${NC}"
        fi
    fi
    [ -n "$TUNNEL_DOMAIN" ] && check_port 4040 && echo -e "  👉 Internet Web:    ${GREEN}https://${TUNNEL_DOMAIN}/${NC}"
    [ -n "$SSH_CMD" ] && echo -e "  👉 Remote SSH:      ${YELLOW}${SSH_CMD}${NC}"
    echo ""
}

logs_service() {
    local svc="$1"
    local follow="$2"
    if [ "$svc" = "-f" ] || [ "$svc" = "--follow" ]; then
        follow="-f"
        svc=""
    fi

    local target_win=""
    case "$svc" in
        gateway|nginx|web)       target_win="gateway" ;;
        monitor|api|mon)         target_win="monitor" ;;
        files|drive|file)        target_win="files" ;;
        drop|clipboard|clip)     target_win="drop" ;;
        cron|scheduler|tasks)    target_win="cron" ;;
        photos|pix|gallery)      target_win="photos" ;;
        ai|chimpai|llama)        target_win="ai" ;;
        tunnel|tunnels|ngrok)    target_win="ngrok-web" ;;
        ssh-tunnel|ngrok-ssh)    target_win="ngrok-ssh" ;;
        "")                      target_win="" ;;
        *)                       target_win="$svc" ;;
    esac

    if [ -n "$target_win" ]; then
        if tmux has-session -t chimp 2>/dev/null && tmux list-windows -t chimp -F "#{window_name}" | grep -q "^${target_win}$"; then
            if [ "$follow" = "-f" ] || [ "$follow" = "--follow" ]; then
                echo -e "${GREEN}=== Live streaming logs for: ${BOLD}${target_win}${NC}${GREEN} (Ctrl+C to exit) ===${NC}"
                while true; do
                    clear
                    echo -e "${GREEN}=== Live logs: ${BOLD}${target_win}${NC}${GREEN} ($(date +'%T')) ===${NC}"
                    tmux capture-pane -p -t "chimp:${target_win}" -S -40
                    sleep 1.5
                done
            else
                echo -e "${GREEN}=== Recent output for: ${BOLD}${target_win}${NC}${GREEN} ===${NC}"
                tmux capture-pane -p -t "chimp:${target_win}" -S -40
                echo ""
                echo -e "${DIM}Tip: Run 'chimp logs ${svc} -f' to stream live output in real-time.${NC}"
            fi
        elif [ -f "$LOG_DIR/${target_win}.log" ]; then
            echo -e "${GREEN}=== File logs for: ${BOLD}${target_win}.log${NC}${GREEN} ===${NC}"
            if [ "$follow" = "-f" ] || [ "$follow" = "--follow" ]; then
                tail -n 40 -f "$LOG_DIR/${target_win}.log"
            else
                tail -n 40 "$LOG_DIR/${target_win}.log"
            fi
        else
            echo -e "${RED}[!] No active tmux pane or log file found for '${svc}'.${NC}"
            echo -e "Available services: gateway, monitor, files, drop, cron, photos, ai, tunnel"
        fi
    else
        echo -e "${GREEN}=== 🐒 Chimp Home Server — Active Service Panes ===${NC}"
        echo -e "${DIM}Services: gateway, monitor, files, drop, cron, photos, ai, tunnel${NC}"
        echo ""
        if tmux has-session -t chimp 2>/dev/null; then
            for win in gateway monitor files drop cron photos ai ngrok-web; do
                if tmux list-windows -t chimp -F "#{window_name}" | grep -q "^${win}$"; then
                    echo -e "${BOLD}${BLUE}▶ [${win}]:${NC}"
                    tmux capture-pane -p -t "chimp:${win}" -S -4 | sed 's/^/  /'
                    echo ""
                fi
            done
        else
            echo -e "${RED}[!] Chimp server tmux session is not running.${NC}"
        fi
        echo -e "${DIM}Tip: View a specific service log with 'chimp logs <service>' (e.g. 'chimp logs monitor -f')${NC}"
    fi
}

attach_console() {
    if tmux has-session -t chimp 2>/dev/null; then
        echo -e "${GREEN}Attaching to Chimp tmux session...${NC}"
        echo -e "${DIM}Use [Ctrl+B] then [D] to detach without stopping services.${NC}"
        sleep 1
        tmux attach -t chimp
    else
        echo -e "${RED}[!] Chimp tmux session is not running.${NC}"
        echo -e "Start it first with: ${GREEN}chimp start${NC}"
    fi
}

show_urls() {
    echo ""
    echo -e "${BOLD}${GREEN}  🐒 Chimp Home Server Endpoints${NC}"
    echo -e "${DIM}  ========================================================${NC}"
    echo -e "  👉 Local LAN Web:   ${BLUE}http://${IP}:8080/${NC}"
    if [ -f "$BASE_DIR/run_llama.sh" ] || [ -f "$HOME/run_llama.sh" ] || check_port 8092; then
        if check_port 8092; then
            echo -e "  👉 Local ChimpAI:   ${BLUE}http://${IP}:8080/chimpai/${NC}"
        fi
    fi
    TUNNEL_DOMAIN=""
    [ -f "$DATA_DIR/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$DATA_DIR/tunnel.conf" | tr -d '\r\n')"
    [ -z "$TUNNEL_DOMAIN" ] && [ -f "$BASE_DIR/config/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$BASE_DIR/config/tunnel.conf" | tr -d '\r\n')"
    if [ -n "$TUNNEL_DOMAIN" ] && check_port 4040; then
        echo -e "  👉 Internet Web:    ${GREEN}https://${TUNNEL_DOMAIN}/${NC}"
    else
        echo -e "  👉 Internet Web:    ${DIM}(tunnel stopped)${NC}"
    fi
    SSH_CMD=$(get_public_ssh)
    if [ -n "$SSH_CMD" ]; then
        echo -e "  👉 Remote SSH:      ${YELLOW}${SSH_CMD}${NC}"
    else
        echo -e "  👉 Remote SSH:      ${DIM}(ssh tunnel stopped)${NC}"
    fi
    echo -e "${DIM}  ========================================================${NC}"
    echo ""
}

handle_ssh() {
    local action="$1"
    case "$action" in
        -off|--off|off|stop|disable|down)
            echo -e "${BOLD}${RED}  🛑 Taking Public Remote SSH Tunnel offline...${NC}"
            pkill -9 -f "ngrok tcp 8022" 2>/dev/null || true
            pkill -9 -f "ngrok tcp" 2>/dev/null || true
            if tmux has-session -t chimp 2>/dev/null; then
                for w in $(tmux list-windows -t chimp -F '#{window_id}:#{window_name}' 2>/dev/null | grep 'ngrok-ssh' | cut -d: -f1); do
                    tmux kill-window -t "$w" 2>/dev/null || true
                done
            fi
            echo -e "  ${GREEN}[✓]${NC} Public Remote SSH tunnel taken offline."
            echo -e "  ${DIM}Local LAN SSH is active: ${BLUE}ssh u0_a223@${IP} -p 8022${NC}"
            echo -e "  ${DIM}To turn public SSH back online: ${GREEN}chimp ssh -on${NC}"
            ;;
        -on|--on|on|start|enable|up)
            echo -e "${BOLD}${GREEN}  🚀 Starting Public Remote SSH Tunnel...${NC}"
            pkill -9 -f "ngrok tcp" 2>/dev/null || true
            if tmux has-session -t chimp 2>/dev/null; then
                for w in $(tmux list-windows -t chimp -F '#{window_id}:#{window_name}' 2>/dev/null | grep 'ngrok-ssh' | cut -d: -f1); do
                    tmux kill-window -t "$w" 2>/dev/null || true
                done
            fi
            sleep 0.5
            tmux new-window -t chimp:7 -n ngrok-ssh 2>/dev/null || tmux new-window -t chimp -n ngrok-ssh 2>/dev/null || true
            tmux send-keys -t chimp:ngrok-ssh "while true; do termux-chroot \$HOME/ngrok tcp 8022; sleep 5; done" C-m
            echo -e "  ${DIM}Connecting to tunnel broker...${NC}"
            sleep 2.5
            local ssh_cmd
            ssh_cmd=$(get_public_ssh)
            if [ -n "$ssh_cmd" ]; then
                echo -e "  ${GREEN}[✓]${NC} Public SSH tunnel is ${BOLD}${GREEN}ONLINE${NC}!"
                echo -e "  👉 Connect with: ${BOLD}${YELLOW}${ssh_cmd}${NC}"
            else
                echo -e "  ${GREEN}[✓]${NC} Public SSH tunnel launched. Check status with: ${GREEN}chimp ssh${NC}"
            fi
            ;;
        status|"")
            local ssh_cmd
            ssh_cmd=$(get_public_ssh)
            if [ -n "$ssh_cmd" ]; then
                echo -e "${BOLD}${GREEN}Public Remote SSH Tunnel is ONLINE:${NC}"
                echo -e "  👉 ${BOLD}${YELLOW}${ssh_cmd}${NC}"
                echo -e ""
                echo -e "  ${DIM}To turn offline: ${RED}chimp ssh -off${NC}"
            else
                echo -e "${RED}[!] Public Remote SSH tunnel is currently OFFLINE.${NC}"
                echo -e "  Local LAN SSH is active: ${BLUE}ssh u0_a223@${IP} -p 8022${NC}"
                echo -e ""
                echo -e "  ${DIM}To turn public SSH online: ${GREEN}chimp ssh -on${NC}"
            fi
            ;;
        *)
            echo -e "${RED}[!] Unknown ssh parameter: '${action}'${NC}"
            echo -e "Usage:"
            echo -e "  ${GREEN}chimp ssh${NC}           Show current remote SSH connection command"
            echo -e "  ${GREEN}chimp ssh -off${NC}      Take public SSH tunnel offline"
            echo -e "  ${GREEN}chimp ssh -on${NC}       Turn public SSH tunnel online"
            exit 1
            ;;
    esac
}

handle_ai() {
    local action="$1"
    local AI_SCRIPT="$BASE_DIR/run_llama.sh"
    [ ! -f "$AI_SCRIPT" ] && AI_SCRIPT="$HOME/run_llama.sh"

    case "$action" in
        start)
            if [ ! -f "$AI_SCRIPT" ]; then
                echo -e "${RED}[!] ChimpAI is not installed yet.${NC}"
                echo -e "Run: ${GREEN}./install_ai.sh${NC} to install it."
                return 1
            fi
            if check_port 8092; then
                echo -e "  ${DIM}[-] ChimpAI is already running (Port 8092)${NC}"
                return 0
            fi
            echo -e "${BOLD}${GREEN}  🧠 Starting ChimpAI Neural Engine...${NC}"
            if tmux has-session -t chimp 2>/dev/null; then
                tmux new-window -t chimp:4 -n ai 2>/dev/null || tmux new-window -t chimp -n ai 2>/dev/null || true
                tmux send-keys -t chimp:ai "while true; do $AI_SCRIPT; sleep 3; done" C-m
            else
                nohup "$AI_SCRIPT" > "$LOG_DIR/ai.log" 2>&1 &
            fi
            sleep 2
            if check_port 8092; then
                echo -e "  ${GREEN}[✓]${NC} ChimpAI running on http://${IP}:8080/chimpai/"
            else
                echo -e "  ${YELLOW}[~]${NC} ChimpAI launched (warming up weights). Check with: ${GREEN}chimp ai status${NC}"
            fi
            ;;
        stop)
            echo -e "${BOLD}${RED}  🛑 Stopping ChimpAI Neural Engine...${NC}"
            pkill -9 -f "llama-server" 2>/dev/null || true
            if tmux has-session -t chimp 2>/dev/null; then
                for w in $(tmux list-windows -t chimp -F '#{window_id}:#{window_name}' 2>/dev/null | grep 'ai' | cut -d: -f1); do
                    tmux kill-window -t "$w" 2>/dev/null || true
                done
            fi
            echo -e "  ${GREEN}[✓]${NC} ChimpAI stopped."
            ;;
        restart)
            handle_ai stop
            sleep 2
            handle_ai start
            ;;
        status|"")
            if check_port 8092; then
                echo -e "${BOLD}${GREEN}ChimpAI Neural Engine is ONLINE${NC} (Port 8092)"
                echo -e "  👉 Local Web: ${BLUE}http://${IP}:8080/chimpai/${NC}"
                local health_check
                health_check=$(curl -s http://127.0.0.1:8092/health 2>/dev/null || echo 'OK')
                echo -e "  👉 Engine:    ${GREEN}${health_check}${NC}"
            else
                echo -e "${RED}[!] ChimpAI Neural Engine is OFFLINE.${NC}"
                if [ -f "$AI_SCRIPT" ]; then
                    echo -e "  Start it with: ${GREEN}chimp ai start${NC}"
                else
                    echo -e "  Install it with: ${GREEN}./install_ai.sh${NC}"
                fi
            fi
            ;;
        logs)
            logs_service ai -f
            ;;
        *)
            echo -e "${RED}[!] Unknown ai parameter: '${action}'${NC}"
            echo -e "Usage: ${GREEN}chimp ai [start|stop|restart|status|logs]${NC}"
            exit 1
            ;;
    esac
}

update_server() {
    echo -e "${BOLD}${GREEN}Pulling latest updates from git repository...${NC}"
    if [ -d "$BASE_DIR/.git" ]; then
        cd "$BASE_DIR" && git pull
        echo -e "${GREEN}[✓] Git update complete. Restarting services...${NC}"
        stop_services
        sleep 2
        start_services
    else
        echo -e "${RED}[!] $BASE_DIR is not a git repository.${NC}"
        exit 1
    fi
}

show_help() {
    echo -e ""
    echo -e "${BOLD}${GREEN}  🐒 Chimp Home Server — Management CLI${NC}"
    echo -e "${DIM}  ====================================================${NC}"
    echo -e "  ${BOLD}Usage:${NC} chimp <command> [options]"
    echo -e ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${GREEN}start${NC}             Start all server services & background tunnels"
    echo -e "    ${GREEN}stop${NC}              Stop all running server services"
    echo -e "    ${GREEN}restart${NC}           Restart all server services"
    echo -e "    ${GREEN}status${NC}            Show real-time status of all services & system health"
    echo -e "    ${GREEN}logs${NC} [service]    View service logs (gateway, monitor, files, drop, cron, photos, ai)"
    echo -e "                        Add ${BOLD}-f${NC} to stream live logs (e.g. ${DIM}chimp logs monitor -f${NC})"
    echo -e "    ${GREEN}ai${NC} [cmd]          Manage ChimpAI on-device neural engine (start|stop|restart|status)"
    echo -e "    ${GREEN}console${NC}           Attach directly to the live tmux server terminal"
    echo -e "    ${GREEN}ssh${NC} [-off|-on]     Print dynamic Remote SSH command, or toggle tunnel (-off/-on)"
    echo -e "    ${GREEN}url${NC}               Print local LAN and public Internet URLs"
    echo -e "    ${GREEN}ip${NC}                Print device local IP address"
    echo -e "    ${GREEN}update${NC}            Pull latest git changes and restart server"
    echo -e "    ${GREEN}help${NC}              Display this help reference"
    echo -e ""
    echo -e "  ${DIM}Tip: You can run 'chimp <command>' from any directory!${NC}"
    echo ""
}

# 3. CLI Dispatcher
case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2
        start_services
        ;;
    status)
        status_services
        ;;
    ai|chimpai|llama)
        handle_ai "$2"
        ;;
    log|logs)
        shift
        logs_service "$@"
        ;;
    console|attach)
        attach_console
        ;;
    ssh)
        handle_ssh "$2"
        ;;
    url|urls)
        show_urls
        ;;
    ip)
        echo "$IP"
        ;;
    update)
        update_server
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo -e "${RED}[!] Unknown command: '$1'${NC}"
        show_help
        exit 1
        ;;
esac
