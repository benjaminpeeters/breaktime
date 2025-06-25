#!/bin/bash

# daemon.sh - Background daemon for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

daemon_run() {
    echo "Starting breaktime daemon..." | logger -t breaktime
    
    # Ensure configuration exists
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "No configuration found, creating default..." | logger -t breaktime
        mkdir -p "${CONFIG_DIR}"
        cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
    fi
    
    # Initial setup of cron jobs
    if [[ $(config_get_enabled) == "true" ]]; then
        cron_update_from_config
        echo "Cron jobs updated from configuration" | logger -t breaktime
    else
        echo "Breaktime disabled in configuration" | logger -t breaktime
    fi
    
    # Monitor configuration file for changes
    daemon_monitor_config &
    
    # Keep daemon running
    while true; do
        # Check if breaktime is still enabled
        if [[ $(config_get_enabled) != "true" ]]; then
            echo "Breaktime disabled, cleaning up cron jobs..." | logger -t breaktime
            cron_remove_all
        fi
        
        sleep 60  # Check every minute
    done
}

daemon_monitor_config() {
    local last_modified=""
    
    while true; do
        if [[ -f "${CONFIG_FILE}" ]]; then
            local current_modified=$(stat -c %Y "${CONFIG_FILE}" 2>/dev/null || echo "0")
            
            if [[ "$current_modified" != "$last_modified" ]]; then
                echo "Configuration file changed, updating cron jobs..." | logger -t breaktime
                sleep 2  # Wait for file write to complete
                
                if config_validate; then
                    cron_update_from_config
                    echo "Configuration reloaded successfully" | logger -t breaktime
                else
                    echo "Configuration validation failed, keeping existing setup" | logger -t breaktime
                fi
                
                last_modified="$current_modified"
            fi
        fi
        
        sleep 5  # Check every 5 seconds
    done
}

# Handle special daemon commands
daemon_handle_command() {
    case "${1:-}" in
        --warn)
            cron_execute_warning "$2" "$3"
            ;;
        --execute)
            cron_execute_action "$2" "$3"
            ;;
        --test-notifications)
            notify_test
            ;;
        *)
            echo "Unknown daemon command: ${1:-}" >&2
            exit 1
            ;;
    esac
}

