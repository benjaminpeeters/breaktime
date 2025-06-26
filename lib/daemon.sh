#!/bin/bash

# daemon.sh - Background daemon for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

daemon_run() {
    echo "Starting breaktime daemon..." | logger -t breaktime
    
    # Initialize snooze system
    snooze_init
    
    # Ensure configuration exists
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "No configuration found, creating default..." | logger -t breaktime
        mkdir -p "${CONFIG_DIR}"
        cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
    fi
    
    # Initial setup of cron jobs
    if [[ $(config_get_enabled) == "true" ]]; then
        if cron_update_from_config; then
            echo "Cron jobs updated from configuration" | logger -t breaktime
        else
            echo "Failed to update cron jobs" | logger -t breaktime
        fi
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
            cron_execute_action "$2" "$3" "${4:-false}"
            ;;
        --snooze)
            daemon_handle_snooze "$2" "$3"
            ;;
        --snooze-suspend)
            daemon_handle_snooze_suspend "$2"
            ;;
        --sleep-now)
            daemon_handle_sleep_now "$2" "$3"
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

# Handle snooze request
daemon_handle_snooze() {
    local alarm_name="$1"
    local original_time="$2"  # HH:MM format
    
    logger -t breaktime "Snooze requested for $alarm_name at $original_time"
    
    # Increment snooze count
    local new_count=$(snooze_increment_count "$alarm_name")
    local max_snoozes=$(snooze_get_max)
    local snooze_duration=$(snooze_get_duration)
    
    # Calculate new time after snooze (from current time, not original time)
    local current_hour=$(date +%H)
    local current_minute=$(date +%M)
    local new_time=$(snooze_calculate_new_time "$current_hour" "$current_minute")
    local new_hour=$(echo "$new_time" | cut -d: -f1)
    local new_minute=$(echo "$new_time" | cut -d: -f2)
    
    # Calculate warning time (2 minutes before new suspend time)
    local warn_time=$(cron_calculate_warning_time "$new_hour" "$new_minute" "2")
    local warn_hour=$(echo "$warn_time" | cut -d: -f1)
    local warn_minute=$(echo "$warn_time" | cut -d: -f2)
    
    # Get action for this alarm
    local action=$(config_get_alarm_action "$alarm_name")
    
    # Use 'at' command to schedule one-time jobs (preserving original cron schedule)
    # Schedule warning
    echo "DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME ${SCRIPT_DIR}/breaktime.sh --warn \"${alarm_name}\" \"2\"" | at "${warn_hour}:${warn_minute}" 2>/dev/null || true
    
    # Schedule suspend
    echo "DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\"" | at "${new_hour}:${new_minute}" 2>/dev/null || true
    
    logger -t breaktime "Snooze $new_count/$max_snoozes: scheduled one-time jobs for $new_time (warning at $warn_time)"
    
    # Store snooze job info for potential cleanup
    snooze_store_job_info "$alarm_name" "$new_time" "$warn_time"
}

# Handle immediate sleep request
daemon_handle_sleep_now() {
    local alarm_name="$1"
    local action="$2"
    
    logger -t breaktime "DEBUG: daemon_handle_sleep_now called with alarm=$alarm_name action=$action"
    
    # Reset snooze count since we're executing now
    snooze_reset_count "$alarm_name"
    
    # Clean up any pending snooze jobs (but keep original cron schedule)
    snooze_cleanup_jobs "$alarm_name"
    
    logger -t breaktime "DEBUG: About to execute action $action"
    
    # Execute the system action directly
    cron_execute_system_action "$action"
    
    logger -t breaktime "DEBUG: Finished executing action $action"
}

# Handle snooze request from suspend dialog
daemon_handle_snooze_suspend() {
    local alarm_name="$1"
    
    logger -t breaktime "DEBUG: daemon_handle_snooze_suspend called with alarm=$alarm_name"
    
    # Check if snoozing is still allowed
    if [[ $(snooze_is_allowed "$alarm_name") != "true" ]]; then
        logger -t breaktime "Snooze limit reached for $alarm_name, ignoring snooze request"
        return 1
    fi
    
    # Increment snooze count
    local new_count=$(snooze_increment_count "$alarm_name")
    local max_snoozes=$(snooze_get_max)
    local snooze_duration=$(snooze_get_duration)
    
    logger -t breaktime "DEBUG: Incremented snooze count to $new_count/$max_snoozes"
    
    # Calculate new suspend time (from current time)
    local current_hour=$(date +%H)
    local current_minute=$(date +%M)
    local new_time=$(snooze_calculate_new_time "$current_hour" "$current_minute")
    local new_hour=$(echo "$new_time" | cut -d: -f1)
    local new_minute=$(echo "$new_time" | cut -d: -f2)
    
    # Get action for this alarm
    local action=$(config_get_alarm_action "$alarm_name")
    
    # Use 'at' command to schedule another suspend dialog (with snoozed flag)
    echo "DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\" \"true\"" | at "${new_hour}:${new_minute}" 2>/dev/null || true
    
    logger -t breaktime "Snooze $new_count/$max_snoozes: scheduled suspend dialog for $new_time"
    
    # Store snooze job info for potential cleanup
    snooze_store_job_info "$alarm_name" "$new_time" ""
}

