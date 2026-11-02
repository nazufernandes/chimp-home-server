# ==============================================================================
#  Chimp Home Server — Interactive Login Banner
# ==============================================================================

# Fix backspace behavior in raw terminal sessions
stty erase ^? 2>/dev/null

# Color definitions
C_RESET="\e[0m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_GREEN="\e[38;5;49m"
C_MINT="\e[38;5;42m"
C_EMERALD="\e[38;5;35m"
C_CYAN="\e[38;5;45m"
C_BLUE="\e[38;5;39m"
C_PURPLE="\e[38;5;141m"
C_WHITE="\e[38;5;255m"
C_GRAY="\e[38;5;244m"
C_DARK="\e[38;5;238m"

if [[ $- == *i* ]]; then
    clear

    # Chimp ASCII Art
    echo -e "${C_GREEN}"
    echo -e "                                ▒▓████▓▒"
    echo -e "                             ▓████████████▒"
    echo -e "                          ▒██████████████████▒"
    echo -e "                         █████████████████████▓"
    echo -e "                       ▒████████████████████████"
    echo -e "                      ▒██████████████████████████"
    echo -e "                    ▒▒░▓████▒░░░░░▒▓▓▒░░░░░░▓███▓░▒▒"
    echo -e "                   ▓█▓▓▓██▓░░██▓▓▓▒░░▒▓█▓▓█▒░▓██▓▒▓█▒"
    echo -e "                  ▓▓▒▓████▓░▒▓█▓▓███▓███▓▓▓▓░░████▓▒▒▓"
    echo -e "                  ▒▓░██████░░░▒▒░░▓▓▒▒░░▒▒░░░▓████▓░▒▒"
    echo -e "                   ▒▓░░▓████▒░░▒▒░░░░░░▒▒░░▒▓███▓▒▒█"
    echo -e "                     ▒▓███████▓░░▒█▒░▓▓░▒▓▓██████▓▒"
    echo -e "                       ▓██████░░░░░▒░░░░░░██████▒"
    echo -e "                       ▒█████▒░░░░░░░░░░░░░█████▒"
    echo -e "                        ▓████░▒▒▒▒▒▒▒▒▒▒▒▒░▓███▓"
    echo -e "                         ▒███▓░░▒▓▓▓▓▓▓▒░░▓███▒"
    echo -e "                           ▒███▓░░░░░░░▓▓███▓"
    echo -e "                             ▒████████████▓"
    echo -e "                               ▒▒▓████▓▒▒"
    echo -e "${C_RESET}"

    # Server Info Card
    IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //g' || uptime | awk '{print $3,$4}')
    MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
    MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
    DISK_USED=$(df -h ~ 2>/dev/null | awk 'NR==2 {print $3}')
    DISK_TOTAL=$(df -h ~ 2>/dev/null | awk 'NR==2 {print $2}')
    DISK_PCT=$(df -h ~ 2>/dev/null | awk 'NR==2 {print $5}')

    # Dynamic row formatter guaranteeing straight 67-column box alignment
    print_card_row() {
        local display_len="$1"
        local colored_text="$2"
        local pad=$(( 62 - display_len ))
        [ "$pad" -lt 0 ] && pad=0
        local spaces=""
        if [ "$pad" -gt 0 ]; then
            spaces=$(printf '%*s' "$pad" "")
        fi
        echo -e "${C_DARK}  │${C_RESET} ${colored_text}${spaces}${C_DARK}│${C_RESET}"
    }

    echo -e "${C_DARK}  ╭───────────────────────────────────────────────────────────────╮${C_RESET}"

    local_hdr="  🐒 CHIMP HOME SERVER · Personal Linux Lab"
    print_card_row $(( ${#local_hdr} + 1 )) "  ${C_BOLD}${C_GREEN}🐒 CHIMP HOME SERVER${C_RESET} ${C_GRAY}· Personal Linux Lab${C_RESET}"

    echo -e "${C_DARK}  ├───────────────────────────────────────────────────────────────┤${C_RESET}"

    local_dev="  System:  Linux Server (ARM32)        IP:   ${IP}"
    print_card_row ${#local_dev} "  ${C_CYAN}System:${C_RESET}  Linux Server (ARM32)        ${C_CYAN}IP:${C_RESET}   ${C_WHITE}${IP}${C_RESET}"

    local_upt="  Uptime:  ${UPTIME}"
    print_card_row ${#local_upt} "  ${C_CYAN}Uptime:${C_RESET}  ${UPTIME}"

    local_mem="  Memory:  ${MEM_USED}MB / ${MEM_TOTAL}MB             Disk: ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
    print_card_row ${#local_mem} "  ${C_CYAN}Memory:${C_RESET}  ${MEM_USED}MB / ${MEM_TOTAL}MB             ${C_CYAN}Disk:${C_RESET} ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"

    echo -e "${C_DARK}  ├───────────────────────────────────────────────────────────────┤${C_RESET}"

    local_svc_hdr="  ACTIVE SERVICES (Unified Gateway)"
    print_card_row ${#local_svc_hdr} "  ${C_BOLD}${C_WHITE}ACTIVE SERVICES${C_RESET} ${C_GRAY}(Unified Gateway)${C_RESET}"

    local_s1="  ● Dashboard:     http://${IP}:8080/"
    print_card_row ${#local_s1} "  ${C_MINT}●${C_RESET} Dashboard:     ${C_BLUE}http://${IP}:8080/${C_RESET}"

    local_s2="  ● File Manager:  http://${IP}:8080/files/"
    print_card_row ${#local_s2} "  ${C_MINT}●${C_RESET} File Manager:  ${C_BLUE}http://${IP}:8080/files/${C_RESET}"

    local_s3="  ● ChimpDrop:     http://${IP}:8080/drop/"
    print_card_row ${#local_s3} "  ${C_MINT}●${C_RESET} ChimpDrop:     ${C_BLUE}http://${IP}:8080/drop/${C_RESET}"

    local_s4="  ● Photos:        http://${IP}:8080/photos/"
    print_card_row ${#local_s4} "  ${C_MINT}●${C_RESET} Photos:        ${C_BLUE}http://${IP}:8080/photos/${C_RESET}"

    local_s5="  ● ChimpCron:     http://${IP}:8080/cron/"
    print_card_row ${#local_s5} "  ${C_MINT}●${C_RESET} ChimpCron:     ${C_BLUE}http://${IP}:8080/cron/${C_RESET}"

    local_s6="  ● Monitor API:   http://${IP}:8080/api/status"
    print_card_row ${#local_s6} "  ${C_MINT}●${C_RESET} Monitor API:   ${C_BLUE}http://${IP}:8080/api/status${C_RESET}"

    echo -e "${C_DARK}  ╰───────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""
fi

# Handy Server Aliases
alias server-status="~/server/manage.sh status"
alias server-restart="~/server/manage.sh restart"
alias server-start="~/server/manage.sh start"
alias server-stop="~/server/manage.sh stop"
alias server-logs="tail -n 30 -f ~/server/logs/*.log"
alias ll="ls -la --color=auto"

# Custom Shell Prompt
PS1='\[\e[38;5;49m\]chimp-server\[\e[0m\]:\[\e[38;5;39m\]\w\[\e[0m\]\$ '

# Auto-start server services if not running
[ -f ~/server/manage.sh ] && ~/server/manage.sh start > /dev/null 2>&1
