#!/bin/bash

# breaktime - Automated break scheduling system
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly CONFIG_DIR="${HOME}/.config/breaktime"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/config/default.yaml"

# Load library modules
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cron.sh"
source "${LIB_DIR}/notify.sh"
source "${LIB_DIR}/daemon.sh"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

usage() {
    echo -e "${BOLD}breaktime${NC} - Automated break scheduling system"
    echo ""
    echo -e "${BOLD}USAGE:${NC}"
    echo "    breaktime [COMMAND]"
    echo ""
    echo -e "${BOLD}COMMANDS:${NC}"
    echo "    --help, -h          Show this help message"
    echo "    --config, -c        Edit configuration file"
    echo "    --status, -s        Show current status and next scheduled breaks"
    echo "    --daemon, -d        Run as background daemon (used by systemd)"
    echo "    --install           Install systemd service and setup"
    echo "    --uninstall         Remove systemd service and cleanup"
    echo ""
    echo -e "${BOLD}CONFIGURATION:${NC}"
    echo "    Configuration file: ${CONFIG_FILE}"
    echo "    Default template:   ${DEFAULT_CONFIG}"
    echo ""
    echo -e "${BOLD}EXAMPLES:${NC}"
    echo "    breaktime --config      # Edit break schedules"
    echo "    breaktime --status      # Check upcoming breaks"
    echo "    breaktime --install     # Set up automatic scheduling"
    echo ""
    echo -e "${BOLD}BREAK TYPES:${NC}"
    echo "    - bedtime: Evening shutdown/suspend"
    echo "    - lunch_break: Midday break"
    echo "    - afternoon_nap: Weekend rest"
    echo "    - focus_break: Work session breaks"
    echo ""
    echo "For more information, see: https://github.com/benjaminpeeters/breaktime"
}

main() {
    case "${1:-}" in
        --help|-h)
            usage
            ;;
        --config|-c)
            config_edit
            ;;
        --status|-s)
            show_status
            ;;
        --daemon|-d)
            daemon_run
            ;;
        --install)
            install_service
            ;;
        --uninstall)
            uninstall_service
            ;;
        "")
            show_status
            ;;
        *)
            echo -e "${RED}Error:${NC} Unknown command '${1}'" >&2
            echo "Use ${BOLD}breaktime --help${NC} for usage information." >&2
            exit 1
            ;;
    esac
}

show_status() {
    echo -e "${BOLD}🕒 Breaktime Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${YELLOW}⚠️  No configuration found${NC}"
        echo -e "Run ${BOLD}breaktime --config${NC} to set up your break schedules"
        return 0
    fi
    
    echo -e "📁 Config: ${BLUE}${CONFIG_FILE}${NC}"
    
    if systemctl --user is-active breaktime.service >/dev/null 2>&1; then
        echo -e "🟢 Service: ${GREEN}Active${NC}"
    else
        echo -e "🔴 Service: ${RED}Inactive${NC}"
        echo -e "Run ${BOLD}breaktime --install${NC} to enable automatic scheduling"
    fi
    
    echo ""
    echo -e "${BOLD}⏰ Next Scheduled Breaks:${NC}"
    cron_show_next
}

install_service() {
    echo -e "${BOLD}🚀 Installing Breaktime Service${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Create config directory and default config
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
        echo -e "✅ Created default configuration"
    fi
    
    # Install systemd service
    local service_file="${HOME}/.config/systemd/user/breaktime.service"
    mkdir -p "$(dirname "${service_file}")"
    cp "${SCRIPT_DIR}/systemd/breaktime.service" "${service_file}"
    
    # Update service file with correct path
    sed -i "s|SCRIPT_PATH|${SCRIPT_DIR}/breaktime.sh|g" "${service_file}"
    
    # Enable and start service
    systemctl --user daemon-reload
    systemctl --user enable breaktime.service
    systemctl --user start breaktime.service
    
    echo -e "✅ Systemd service installed and started"
    echo -e "✅ Service will auto-start on login"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "1. Run ${BOLD}breaktime --config${NC} to customize your break schedules"
    echo "2. Run ${BOLD}breaktime --status${NC} to verify everything is working"
}

uninstall_service() {
    echo -e "${BOLD}🗑️  Uninstalling Breaktime Service${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Stop and disable service
    systemctl --user stop breaktime.service 2>/dev/null || true
    systemctl --user disable breaktime.service 2>/dev/null || true
    
    # Remove service file
    rm -f "${HOME}/.config/systemd/user/breaktime.service"
    systemctl --user daemon-reload
    
    # Remove cron jobs
    cron_remove_all
    
    echo -e "✅ Service stopped and disabled"
    echo -e "✅ Cron jobs removed"
    echo ""
    echo -e "${YELLOW}Note:${NC} Configuration files preserved in ${CONFIG_DIR}"
    echo -e "Remove manually if desired: ${BOLD}rm -rf ${CONFIG_DIR}${NC}"
}

# Ensure required directories exist
[[ -d "${LIB_DIR}" ]] || { echo "Error: Library directory not found: ${LIB_DIR}" >&2; exit 1; }

# Check if we're being called with special daemon commands
if [[ "${1:-}" =~ ^--(warn|execute|test-notifications)$ ]]; then
    daemon_handle_command "$@"
    exit 0
fi

# Run main function with all arguments
main "$@"