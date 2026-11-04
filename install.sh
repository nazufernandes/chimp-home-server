#!/usr/bin/env bash
# ==============================================================================
#  🐒 Chimp Home Server — One-Line Automated Installer
# ==============================================================================

set -e

echo ""
echo "  🐒  Installing Chimp Home Server..."
echo "  ====================================="
echo ""

# 1. Detect Environment & Install Packages
if which pkg > /dev/null 2>&1; then
    echo "[1/5] Updating Termux packages and installing dependencies..."
    pkg update -y
    pkg install -y python python-pip nginx git curl openssh
elif which apt-get > /dev/null 2>&1; then
    echo "[1/5] Updating APT packages and installing dependencies..."
    sudo apt-get update -y
    sudo apt-get install -y python3 python3-pip nginx git curl openssh-server
else
    echo "[!] Unsupported package manager. Please ensure Python, pip, and Nginx are installed."
fi

# 2. Install Python Requirements
echo "[2/5] Installing Python dependencies (Flask, Pillow, Werkzeug)..."
pip install flask pillow werkzeug

# 3. Setup Server Directory Structure
CHIMP_DIR="$HOME/server"
echo "[3/5] Setting up server directory at $CHIMP_DIR..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$SCRIPT_DIR" != "$CHIMP_DIR" ]; then
    mkdir -p "$CHIMP_DIR"
    cp -r "$SCRIPT_DIR/"* "$CHIMP_DIR/"
fi

mkdir -p "$CHIMP_DIR/logs" \
         "$CHIMP_DIR/data/drop/files" \
         "$CHIMP_DIR/data/photos" \
         "$CHIMP_DIR/data/shared" \
         "$CHIMP_DIR/data/cron" \
         "$CHIMP_DIR/data/sites" \
         "$CHIMP_DIR/photos/thumbnails"

chmod +x "$CHIMP_DIR/manage.sh"

# 4. Configure Nginx Gateway
echo "[4/5] Configuring Nginx Reverse Proxy Gateway..."
NGINX_CONF_TARGET=""

if [ -d "/data/data/com.termux/files/usr/etc/nginx" ]; then
    NGINX_CONF_TARGET="/data/data/com.termux/files/usr/etc/nginx/nginx.conf"
elif [ -d "/etc/nginx" ]; then
    NGINX_CONF_TARGET="/etc/nginx/nginx.conf"
fi

if [ -n "$NGINX_CONF_TARGET" ]; then
    sed "s|__CHIMP_ROOT__|$CHIMP_DIR|g" "$CHIMP_DIR/config/nginx.conf" > "$NGINX_CONF_TARGET"
    echo "[✓] Nginx config installed at $NGINX_CONF_TARGET"
fi

# 5. Setup Login Shell Banner
echo "[5/6] Configuring startup banner in ~/.bashrc..."
if ! grep -q "CHIMP HOME SERVER" "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    cat "$CHIMP_DIR/bashrc_banner.sh" >> "$HOME/.bashrc"
    echo "[✓] Banner added to ~/.bashrc"
else
    echo "[-] Banner already present in ~/.bashrc"
fi

# 6. Remote Access Options (Optional & Independent)
echo ""
echo "----------------------------------------------------------"
echo "  🌐 Remote Access Options (Optional)"
echo "----------------------------------------------------------"
echo "  By default, Chimp runs privately on your local home Wi-Fi."
echo "  You can independently enable public web hosting and/or remote SSH."
echo ""

# 6a. Public Web Access (Ngrok)
ENABLE_NGROK="n"
if [ -t 0 ]; then
    read -r -p "  [1/2] Enable Public Web Access via Ngrok (share sites/files with anyone)? (y/N): " ENABLE_NGROK
fi

if [[ "$ENABLE_NGROK" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  [*] Setting up Public Internet Access via Ngrok..."
    read -r -p "  Enter your Ngrok Authtoken (from dashboard.ngrok.com): " NGROK_TOKEN
    read -r -p "  Enter your free static domain (e.g. your-subdomain.ngrok-free.dev) [optional]: " NGROK_DOMAIN

    # Install prerequisites
    if which pkg > /dev/null 2>&1; then
        pkg install -y proot tar ca-certificates
    elif which apt-get > /dev/null 2>&1; then
        sudo apt-get install -y tar ca-certificates
    fi

    # Download ngrok binary if not already present
    if [ ! -f "$HOME/ngrok" ] && ! which ngrok > /dev/null 2>&1; then
        ARCH=$(uname -m)
        NGROK_URL=""
        case "$ARCH" in
            armv7*|armv8l|arm) NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm.tgz" ;;
            aarch64|arm64)      NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz" ;;
            x86_64|amd64)       NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz" ;;
            i*86|x86)           NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-386.tgz" ;;
        esac

        if [ -n "$NGROK_URL" ]; then
            echo "  [-] Downloading ngrok for $ARCH..."
            curl -fsSL "$NGROK_URL" -o "$HOME/ngrok.tgz"
            tar -xzf "$HOME/ngrok.tgz" -C "$HOME"
            rm -f "$HOME/ngrok.tgz"
            chmod +x "$HOME/ngrok"
        fi
    fi

    NGROK_BIN="$HOME/ngrok"
    [ ! -f "$NGROK_BIN" ] && which ngrok > /dev/null 2>&1 && NGROK_BIN="$(which ngrok)"

    if [ -f "$NGROK_BIN" ] && [ -n "$NGROK_TOKEN" ]; then
        if "$NGROK_BIN" version > /dev/null 2>&1; then
            "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN"
        elif which termux-chroot > /dev/null 2>&1; then
            termux-chroot "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN"
        else
            "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN"
        fi
        [ -n "$NGROK_DOMAIN" ] && echo "$NGROK_DOMAIN" > "$CHIMP_DIR/data/tunnel.conf"
        echo "  [✓] Ngrok public tunnel configured successfully!"
    fi
fi

# 6b. Remote SSH & Private Admin Mesh (Tailscale)
echo ""
ENABLE_TAILSCALE="n"
if [ -t 0 ]; then
    read -r -p "  [2/2] Enable Secure Remote SSH via Tailscale (remote terminal for admin)? (y/N): " ENABLE_TAILSCALE
fi

if [[ "$ENABLE_TAILSCALE" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  [*] Configuring Remote SSH via Tailscale..."
    if which apt-get > /dev/null 2>&1; then
        echo "  [-] Installing Tailscale via official repository..."
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo tailscale up
    else
        echo ""
        echo "  📱 On Android / Termux:"
        echo "  1. Install the official Tailscale app from Google Play or F-Droid."
        echo "  2. Sign in and toggle Connect to ON."
        echo "  3. Your phone will receive an encrypted private IP (100.x.y.z)."
        echo "     Access your server at: http://100.x.y.z:8080/"
        echo "     SSH remotely via:      ssh -p 8022 u0_a223@100.x.y.z"
        echo ""
    fi
fi

# 7. Start Services
echo ""
echo "🚀 Starting all Chimp Home Server services..."
"$CHIMP_DIR/manage.sh" restart

IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
TUNNEL_DOMAIN=""
[ -f "$CHIMP_DIR/data/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$CHIMP_DIR/data/tunnel.conf" | tr -d '\r\n')"
TS_IP=$(ip -4 addr show tun0 2>/dev/null | grep -oP '(?<=inet\s)100\.\d+(\.\d+){2}' || which tailscale > /dev/null 2>&1 && tailscale ip -4 2>/dev/null || echo "")

echo ""
echo "=========================================================="
echo "  🎉 Chimp Home Server is now fully installed and LIVE!"
echo "  👉  Local LAN:   http://${IP}:8080/"
if [ -n "$TUNNEL_DOMAIN" ] && pgrep -f "ngrok http" > /dev/null 2>&1; then
    echo "  👉  Internet:    https://${TUNNEL_DOMAIN}/"
fi
if [ -n "$TS_IP" ]; then
    echo "  👉  Tailscale:   http://${TS_IP}:8080/ (SSH: ssh -p 8022 ${TS_IP})"
fi
echo "=========================================================="
echo ""
