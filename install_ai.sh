#!/usr/bin/env bash
# ==============================================================================
#  🐒 Chimp Home Server — ChimpAI Neural Engine Modular Installer
# ==============================================================================
#  Installs and configures an on-device local Large Language Model (Qwen 2.5 0.5B)
#  powered by llama.cpp and accessible through the Chimp Gateway at /chimpai/.
# ==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}${GREEN}  🐒  ChimpAI Neural Engine — Modular Installer${NC}"
echo -e "${DIM}  ==============================================================${NC}"
echo -e "  This script installs an on-device AI assistant directly on your server."
echo -e "  • Model:       ${CYAN}Qwen 2.5 0.5B Instruct${NC} (4-bit quantized GGUF ~398MB)"
echo -e "  • Engine:      ${CYAN}llama.cpp server${NC} (streaming SSE, ultra low memory)"
echo -e "  • Interface:   ${CYAN}ChimpAI Web UI${NC} with voice read-aloud & archive"
echo -e "  • Gateway:     ${CYAN}http://<your-ip>:8080/chimpai/${NC}"
echo -e "${DIM}  ==============================================================${NC}"
echo ""

# 1. Locate Chimp Home Server directory
if [ -d "$HOME/server" ] && [ -f "$HOME/server/manage.sh" ]; then
    CHIMP_DIR="$HOME/server"
else
    CHIMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ ! -f "$CHIMP_DIR/manage.sh" ]; then
    echo -e "${RED}[!] Error: Could not locate Chimp Home Server at $CHIMP_DIR.${NC}"
    echo -e "Please ensure you are running this from your Chimp Server directory."
    exit 1
fi

echo -e "  ${GREEN}[✓]${NC} Server root: ${BOLD}$CHIMP_DIR${NC}"

# 2. Check System Resources & Cores
CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
[ "$CORES" -lt 1 ] && CORES=4
THREADS=$(( CORES > 6 ? 6 : CORES ))

RAM_MB=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "unknown")
echo -e "  ${GREEN}[✓]${NC} Detected ${BOLD}${CORES}${NC} CPU cores (using ${BOLD}${THREADS}${NC} compute threads, ${RAM_MB}MB RAM)"

# 3. Check Dependencies & Compiler Toolchain
echo ""
echo -e "${BOLD}[1/5] Checking dependencies & compiler toolchain...${NC}"

NEEDS_BUILD=false
LLAMA_BIN=""

# Check if llama-server already exists anywhere
if which llama-server >/dev/null 2>&1; then
    LLAMA_BIN="$(which llama-server)"
elif [ -x "$HOME/llama.cpp/build/bin/llama-server" ]; then
    LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-server"
elif [ -x "$HOME/llama.cpp/llama-server" ]; then
    LLAMA_BIN="$HOME/llama.cpp/llama-server"
elif [ -x "$CHIMP_DIR/llama.cpp/build/bin/llama-server" ]; then
    LLAMA_BIN="$CHIMP_DIR/llama.cpp/build/bin/llama-server"
fi

if [ -n "$LLAMA_BIN" ]; then
    echo -e "  ${GREEN}[✓]${NC} Found existing llama-server at: ${CYAN}$LLAMA_BIN${NC}"
else
    NEEDS_BUILD=true
    echo -e "  ${YELLOW}[-]${NC} llama-server binary not found. Preparing build environment..."
    if which pkg > /dev/null 2>&1; then
        echo -e "  ${DIM}Updating Termux packages and installing clang, cmake, git, make, curl...${NC}"
        pkg update -y
        pkg install -y clang cmake git make curl termux-tools
    elif which apt-get > /dev/null 2>&1; then
        echo -e "  ${DIM}Installing build tools via apt...${NC}"
        sudo apt-get update -y
        sudo apt-get install -y build-essential cmake git curl
    else
        echo -e "  ${YELLOW}[!] Unsupported package manager. Please ensure git, cmake, and clang/gcc are installed.${NC}"
    fi
fi

# 4. Build llama.cpp if needed
if [ "$NEEDS_BUILD" = true ]; then
    echo ""
    echo -e "${BOLD}[2/5] Building llama.cpp from source (one-time setup)...${NC}"
    LLAMA_DIR="$HOME/llama.cpp"
    if [ ! -d "$LLAMA_DIR" ]; then
        echo -e "  ${DIM}Cloning llama.cpp repository...${NC}"
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    fi
    cd "$LLAMA_DIR"
    echo -e "  ${DIM}Compiling llama-server with CMake (${CORES} threads)...${NC}"
    cmake -B build -DGGML_OPENMP=OFF
    cmake --build build --config Release -t llama-server -j "$CORES"
    
    if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
        LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"
        echo -e "  ${GREEN}[✓]${NC} Successfully compiled llama-server!"
    else
        echo -e "${RED}[!] Compilation failed. Please check build logs above.${NC}"
        exit 1
    fi
else
    echo ""
    echo -e "${BOLD}[2/5] llama-server engine ready.${NC}"
fi

# 5. Download Model Weights
echo ""
echo -e "${BOLD}[3/5] Setting up Qwen 2.5 0.5B Instruct GGUF model...${NC}"
MODELS_DIR="$HOME/models"
mkdir -p "$MODELS_DIR"
MODEL_FILE="$MODELS_DIR/qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"

if [ -f "$MODEL_FILE" ] && [ "$(wc -c < "$MODEL_FILE" 2>/dev/null || echo 0)" -gt 100000000 ]; then
    echo -e "  ${GREEN}[✓]${NC} Model already exists at: ${CYAN}$MODEL_FILE${NC}"
    echo -e "  ${DIM}Size: $(ls -lh "$MODEL_FILE" | awk '{print $5}')${NC}"
else
    echo -e "  ${YELLOW}[↓]${NC} Downloading Qwen 2.5 0.5B Instruct Q4_K_M (~398MB)..."
    echo -e "  ${DIM}Source: $MODEL_URL${NC}"
    curl -L --progress-bar "$MODEL_URL" -o "$MODEL_FILE.tmp"
    mv "$MODEL_FILE.tmp" "$MODEL_FILE"
    echo -e "  ${GREEN}[✓]${NC} Model downloaded successfully!"
fi

# 6. Generate run_llama.sh Script
echo ""
echo -e "${BOLD}[4/5] Generating launcher & configuring Nginx gateway...${NC}"

# Find LLAMA lib directory for LD_LIBRARY_PATH
LLAMA_LIB_DIR="$(dirname "$LLAMA_BIN")"

RUN_SCRIPT="$CHIMP_DIR/run_llama.sh"
cat << EOF > "$RUN_SCRIPT"
#!/usr/bin/env bash
# ChimpAI Neural Engine Runner
termux-wake-lock 2>/dev/null || true
export LD_LIBRARY_PATH="$LLAMA_LIB_DIR:\$LD_LIBRARY_PATH"
cd "$LLAMA_LIB_DIR" 2>/dev/null || true
exec "$LLAMA_BIN" \\
  -m "$MODEL_FILE" \\
  --host 127.0.0.1 \\
  --port 8092 \\
  -c 1024 \\
  -t $THREADS \\
  -tb $THREADS \\
  -b 128 \\
  --alias chimp-qwen
EOF

chmod +x "$RUN_SCRIPT"
# Also place symlink / copy in $HOME for backward compatibility
cp "$RUN_SCRIPT" "$HOME/run_llama.sh" 2>/dev/null || true
chmod +x "$HOME/run_llama.sh" 2>/dev/null || true
echo -e "  ${GREEN}[✓]${NC} Created launcher script at ${CYAN}$RUN_SCRIPT${NC}"

# Ensure web/chimpai/ directory exists
mkdir -p "$CHIMP_DIR/web/chimpai"

# Re-link Nginx config
NGINX_TARGET=""
if [ -d "/data/data/com.termux/files/usr/etc/nginx" ]; then
    NGINX_TARGET="/data/data/com.termux/files/usr/etc/nginx/nginx.conf"
elif [ -d "/etc/nginx" ]; then
    NGINX_TARGET="/etc/nginx/nginx.conf"
fi

if [ -n "$NGINX_TARGET" ] && [ -f "$CHIMP_DIR/config/nginx.conf" ]; then
    sed "s|__CHIMP_ROOT__|$CHIMP_DIR|g" "$CHIMP_DIR/config/nginx.conf" > "$NGINX_TARGET"
    echo -e "  ${GREEN}[✓]${NC} Nginx configuration synchronized at ${CYAN}$NGINX_TARGET${NC}"
    nginx -s reload 2>/dev/null || true
fi

# Enable ChimpAI in services_state.json if present
STATE_FILE="$CHIMP_DIR/data/services_state.json"
if [ -f "$STATE_FILE" ]; then
    python3 -c "
import json, os
p = '$STATE_FILE'
try:
    with open(p, 'r') as f:
        d = json.load(f)
    d['ai'] = {'enabled': True, 'show_dashboard': True}
    with open(p, 'w') as f:
        json.dump(d, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
fi

# 7. Start / Restart ChimpAI Service
echo ""
echo -e "${BOLD}[5/5] Launching ChimpAI Neural Engine...${NC}"
if [ -x "$CHIMP_DIR/manage.sh" ]; then
    "$CHIMP_DIR/manage.sh" ai restart
else
    nohup "$RUN_SCRIPT" > "$CHIMP_DIR/logs/ai.log" 2>&1 &
fi

sleep 3

IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

echo ""
echo -e "${DIM}  ==============================================================${NC}"
echo -e "  ${BOLD}${GREEN}🎉 ChimpAI Neural Engine is successfully installed & LIVE!${NC}"
echo -e "  👉  ${BOLD}Local LAN Web:${NC}     ${BLUE}http://${IP}:8080/chimpai/${NC}"
echo -e "  👉  ${BOLD}Direct API:${NC}        ${CYAN}http://${IP}:8080/ai/health${NC}"
echo -e "  👉  ${BOLD}Manage Service:${NC}    ${YELLOW}chimp ai [start|stop|restart|status|logs]${NC}"
echo -e "  👉  ${BOLD}Control Panel:${NC}     Visible in Master Dashboard at http://${IP}:8080/"
echo -e "${DIM}  ==============================================================${NC}"
echo ""
