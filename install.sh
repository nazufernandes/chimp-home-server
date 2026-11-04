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
    echo "[1/6] Updating Termux packages and installing dependencies..."
    pkg update -y
    pkg install -y python python-pip nginx git curl openssh
elif which apt-get > /dev/null 2>&1; then
    echo "[1/6] Updating APT packages and installing dependencies..."
    sudo apt-get update -y
    sudo apt-get install -y python3 python3-pip nginx git curl openssh-server
else
    echo "[!] Unsupported package manager. Please ensure Python, pip, and Nginx are installed."
fi

# 2. Install Python Requirements
echo "[2/6] Installing Python dependencies (Flask, Pillow, Werkzeug)..."
pip install flask pillow werkzeug

# 3. Setup Server Directory Structure
CHIMP_DIR="$HOME/server"
echo "[3/6] Setting up server directory at $CHIMP_DIR..."

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

# 4. Admin Security & Password Configuration
echo ""
echo "[4/6] Configuring Admin Master Password..."
ADMIN_INPUT=""
if [ -t 0 ]; then
    read -r -p "  Enter Master Admin Password for Dashboard Control [default: admin]: " ADMIN_INPUT
elif [ -e /dev/tty ]; then
    read -r -p "  Enter Master Admin Password for Dashboard Control [default: admin]: " ADMIN_INPUT < /dev/tty 2>/dev/null || true
fi
ADMIN_PASS="${ADMIN_INPUT:-admin}"

ENV_FILE="$CHIMP_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    grep -v "^CHIMP_ADMIN_PASSWORD=" "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
    echo "CHIMP_ADMIN_PASSWORD=$ADMIN_PASS" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
    echo "  [✓] Admin password updated in $ENV_FILE"
else
    echo "# Chimp Home Server — Environment Configuration" > "$ENV_FILE"
    echo "CHIMP_ADMIN_PASSWORD=$ADMIN_PASS" >> "$ENV_FILE"
    echo "  [✓] Admin password saved to $ENV_FILE"
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true

# 5. Configure Nginx Gateway
echo ""
echo "[5/6] Configuring Nginx Reverse Proxy Gateway..."
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

# 6. Setup Login Shell Banner
echo "[6/6] Configuring startup banner in ~/.bashrc..."
if ! grep -q "CHIMP HOME SERVER" "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    cat "$CHIMP_DIR/bashrc_banner.sh" >> "$HOME/.bashrc"
    echo "[✓] Banner added to ~/.bashrc"
else
    echo "[-] Banner already present in ~/.bashrc"
fi

# 7. Remote Access Options (Optional)
echo ""
echo "----------------------------------------------------------"
echo "  🌐 Remote Internet Access (Optional)"
echo "----------------------------------------------------------"
echo "  By default, Chimp runs privately on your local home Wi-Fi."
echo "  You can optionally enable public web hosting and remote SSH via Ngrok."
echo ""

# Public Web Access (Ngrok)
ENABLE_NGROK="n"
if [ -t 0 ]; then
    read -r -p "  Enable Public Internet Access via Ngrok? (y/N): " ENABLE_NGROK
elif [ -e /dev/tty ]; then
    read -r -p "  Enable Public Internet Access via Ngrok? (y/N): " ENABLE_NGROK < /dev/tty 2>/dev/null || true
fi

if [[ "$ENABLE_NGROK" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  [*] Setting up Public Internet Access via Ngrok..."
    NGROK_TOKEN=""
    NGROK_DOMAIN=""
    if [ -t 0 ]; then
        read -r -p "  Enter your Ngrok Authtoken (from dashboard.ngrok.com): " NGROK_TOKEN
        read -r -p "  Enter your static domain (e.g. your-subdomain.ngrok-free.dev) [optional]: " NGROK_DOMAIN
    elif [ -e /dev/tty ]; then
        read -r -p "  Enter your Ngrok Authtoken (from dashboard.ngrok.com): " NGROK_TOKEN < /dev/tty 2>/dev/null || true
        read -r -p "  Enter your static domain (e.g. your-subdomain.ngrok-free.dev) [optional]: " NGROK_DOMAIN < /dev/tty 2>/dev/null || true
    fi

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

# 7. Start Services
echo ""
echo "🚀 Starting all Chimp Home Server services..."
"$CHIMP_DIR/manage.sh" restart

IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
TUNNEL_DOMAIN=""
[ -f "$CHIMP_DIR/data/tunnel.conf" ] && TUNNEL_DOMAIN="$(cat "$CHIMP_DIR/data/tunnel.conf" | tr -d '\r\n')"

echo ""
echo "=========================================================="
echo "  🎉 Chimp Home Server is now fully installed and LIVE!"
echo "  👉  Local LAN:   http://${IP}:8080/ (SSH: ssh u0_a223@${IP} -p 8022)"
if [ -n "$TUNNEL_DOMAIN" ]; then
    echo "  👉  Internet:    https://${TUNNEL_DOMAIN}/"
fi
echo "  🔒  Admin Panel: 7 rapid clicks on 🐒 logo"
echo "=========================================================="
echo ""
