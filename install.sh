#!/bin/bash

# install.sh - Installation script for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly CONFIG_DIR="${HOME}/.config/breaktime"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

usage() {
    echo -e "${BOLD}Breaktime Installation Script${NC}"
    echo ""
    echo -e "${BOLD}USAGE:${NC}"
    echo "    ./install.sh [OPTIONS]"
    echo ""
    echo -e "${BOLD}OPTIONS:${NC}"
    echo "    --uninstall, -u     Uninstall breaktime"
    echo "    --help, -h          Show this help message"
    echo ""
    echo -e "${BOLD}DESCRIPTION:${NC}"
    echo "    Installs breaktime automated break scheduling system:"
    echo "    - Creates symlink in ~/.local/bin/"
    echo "    - Sets up systemd user service"
    echo "    - Creates default configuration"
    echo "    - Enables auto-start on login"
    echo ""
    echo -e "${BOLD}REQUIREMENTS:${NC}"
    echo "    - systemd (for background service)"
    echo "    - notify-send (for desktop notifications)"
    echo "    - cron (for scheduling)"
}

check_requirements() {
    echo -e "${BOLD}🔍 Checking Requirements${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local missing_requirements=()
    
    # Check systemd
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "✅ systemd: ${GREEN}Available${NC}"
    else
        echo -e "❌ systemd: ${RED}Not available${NC}"
        missing_requirements+=("systemd")
    fi
    
    # Check cron
    if command -v crontab >/dev/null 2>&1; then
        echo -e "✅ cron: ${GREEN}Available${NC}"
    else
        echo -e "❌ cron: ${RED}Not available${NC}"
        missing_requirements+=("cron")
    fi
    
    # Check and install 'at' command (for snooze functionality)
    if command -v at >/dev/null 2>&1; then
        echo -e "✅ at: ${GREEN}Available${NC}"
    else
        echo -e "⚠️  at: ${YELLOW}Not available - installing...${NC}"
        if sudo apt update && sudo apt install -y at; then
            echo -e "✅ at: ${GREEN}Installed successfully${NC}"
            # Enable atd service
            sudo systemctl enable atd
            sudo systemctl start atd
        else
            echo -e "❌ at: ${RED}Failed to install${NC}"
            missing_requirements+=("at")
        fi
    fi
    
    # Check and install YAD (preferred notification system)
    if command -v yad >/dev/null 2>&1; then
        echo -e "✅ yad: ${GREEN}Available${NC}"
    else
        echo -e "⚠️  yad: ${YELLOW}Not available - installing...${NC}"
        if sudo apt update && sudo apt install -y yad; then
            echo -e "✅ yad: ${GREEN}Installed successfully${NC}"
        else
            echo -e "❌ yad: ${RED}Failed to install${NC}"
            missing_requirements+=("yad")
        fi
    fi
    
    # Check zenity (fallback notification system)
    if command -v zenity >/dev/null 2>&1; then
        echo -e "✅ zenity: ${GREEN}Available${NC}"
    else
        echo -e "⚠️  zenity: ${YELLOW}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install zenity${NC}"
    fi
    
    # Check notify-send (secondary fallback)
    if command -v notify-send >/dev/null 2>&1; then
        echo -e "✅ notify-send: ${GREEN}Available${NC}"
    else
        echo -e "⚠️  notify-send: ${YELLOW}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install libnotify-bin${NC}"
    fi
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
        echo -e "✅ ~/.local/bin in PATH: ${GREEN}Yes${NC}"
    else
        echo -e "⚠️  ~/.local/bin in PATH: ${YELLOW}No${NC}"
        echo -e "   Add to your shell profile: ${BOLD}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    fi
    
    if [[ ${#missing_requirements[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}❌ Missing required dependencies:${NC}"
        printf '   - %s\n' "${missing_requirements[@]}"
        echo ""
        echo -e "${YELLOW}Install missing dependencies and run again.${NC}"
        exit 1
    fi
    
    echo ""
}

install_breaktime() {
    echo -e "${BOLD}🚀 Installing Breaktime${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Create ~/.local/bin directory if it doesn't exist
    mkdir -p "${INSTALL_DIR}"
    
    # Create symlink to breaktime.sh
    local breaktime_link="${INSTALL_DIR}/breaktime"
    if [[ -L "$breaktime_link" ]] || [[ -f "$breaktime_link" ]]; then
        echo -e "🔄 Removing existing breaktime link..."
        rm -f "$breaktime_link"
    fi
    
    ln -s "${SCRIPT_DIR}/breaktime.sh" "$breaktime_link"
    echo -e "✅ Created symlink: ${BLUE}${breaktime_link}${NC}"
    
    # Create configuration directory
    mkdir -p "${CONFIG_DIR}"
    
    # Copy default configuration if it doesn't exist
    local config_file="${CONFIG_DIR}/config.yaml"
    if [[ ! -f "$config_file" ]]; then
        cp "${SCRIPT_DIR}/config/default.yaml" "$config_file"
        echo -e "✅ Created configuration: ${BLUE}${config_file}${NC}"
    else
        echo -e "📄 Configuration exists: ${BLUE}${config_file}${NC}"
    fi
    
    # Install systemd service
    local service_dir="${HOME}/.config/systemd/user"
    local service_file="${service_dir}/breaktime.service"
    
    mkdir -p "$service_dir"
    cp "${SCRIPT_DIR}/systemd/breaktime.service" "$service_file"
    
    # Update service file with correct script path
    sed -i "s|SCRIPT_PATH|${SCRIPT_DIR}/breaktime.sh|g" "$service_file"
    
    echo -e "✅ Installed systemd service: ${BLUE}${service_file}${NC}"
    
    # Reload systemd and enable service
    systemctl --user daemon-reload
    systemctl --user enable breaktime.service
    systemctl --user start breaktime.service
    
    echo -e "✅ Enabled and started breaktime service"
    
    echo ""
    echo -e "${BOLD}🎉 Installation Complete!${NC}"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "1. Configure your break schedules:"
    echo -e "   ${BLUE}breaktime --config${NC}"
    echo ""
    echo "2. Check the status:"
    echo -e "   ${BLUE}breaktime --status${NC}"
    echo ""
    echo "3. Test notifications:"
    echo -e "   ${BLUE}breaktime --test-notifications${NC}"
    echo ""
    echo -e "${BOLD}Important Notes:${NC}"
    echo "• Service auto-starts on login"
    echo -e "• Configuration: ${BLUE}${config_file}${NC}"
    echo -e "• Logs: ${BLUE}journalctl --user -u breaktime${NC}"
    
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo ""
        echo -e "${YELLOW}⚠️  Add ~/.local/bin to your PATH:${NC}"
        echo -e "   ${BOLD}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc${NC}"
        echo -e "   ${BOLD}source ~/.bashrc${NC}"
    fi
}

uninstall_breaktime() {
    echo -e "${BOLD}🗑️  Uninstalling Breaktime${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Stop and disable service
    if systemctl --user is-active breaktime.service >/dev/null 2>&1; then
        systemctl --user stop breaktime.service
        echo -e "🛑 Stopped breaktime service"
    fi
    
    if systemctl --user is-enabled breaktime.service >/dev/null 2>&1; then
        systemctl --user disable breaktime.service
        echo -e "🔄 Disabled breaktime service"
    fi
    
    # Remove service file
    local service_file="${HOME}/.config/systemd/user/breaktime.service"
    if [[ -f "$service_file" ]]; then
        rm -f "$service_file"
        systemctl --user daemon-reload
        echo -e "🗑️  Removed systemd service"
    fi
    
    # Remove symlink
    local breaktime_link="${INSTALL_DIR}/breaktime"
    if [[ -L "$breaktime_link" ]]; then
        rm -f "$breaktime_link"
        echo -e "🗑️  Removed symlink: ${breaktime_link}"
    fi
    
    # Remove cron jobs
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "breaktime-managed"; then
            crontab -l 2>/dev/null | grep -v "breaktime-managed" | crontab - 2>/dev/null || true
            echo -e "🗑️  Removed cron jobs"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}✅ Uninstallation complete!${NC}"
    echo ""
    echo -e "${YELLOW}Configuration preserved:${NC}"
    echo -e "• ${CONFIG_DIR}/"
    echo ""
    echo -e "Remove manually if desired:"
    echo -e "  ${BOLD}rm -rf ${CONFIG_DIR}${NC}"
}

main() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        --uninstall|-u)
            uninstall_breaktime
            exit 0
            ;;
        "")
            check_requirements
            install_breaktime
            ;;
        *)
            echo -e "${RED}Error:${NC} Unknown option '${1}'" >&2
            echo -e "Use ${BOLD}./install.sh --help${NC} for usage information." >&2
            exit 1
            ;;
    esac
}

main "$@"