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
    pkg install -y python python-pip nginx git curl
elif which apt-get > /dev/null 2>&1; then
    echo "[1/5] Updating APT packages and installing dependencies..."
    sudo apt-get update -y
    sudo apt-get install -y python3 python3-pip nginx git curl
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
echo "[5/5] Configuring startup banner in ~/.bashrc..."
if ! grep -q "CHIMP HOME SERVER" "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    cat "$CHIMP_DIR/bashrc_banner.sh" >> "$HOME/.bashrc"
    echo "[✓] Banner added to ~/.bashrc"
else
    echo "[-] Banner already present in ~/.bashrc"
fi

# 6. Start Services
echo ""
echo "🚀 Starting all Chimp Home Server services..."
"$CHIMP_DIR/manage.sh" restart

IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

echo ""
echo "=========================================================="
echo "  🎉 Chimp Home Server is now fully installed and LIVE!"
echo "  👉  Open in your browser: http://${IP}:8080/"
echo "=========================================================="
echo ""
