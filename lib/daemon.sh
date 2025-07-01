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
        
        # Check for pending snooze jobs (NEW file-based system)
        snooze_check_pending
        
        # Clean up old completed jobs periodically
        if [[ $(($(date +%s) % 3600)) -lt 30 ]]; then  # Once per hour
            snooze_cleanup_completed
        fi
        
        sleep 30  # Check every 30 seconds for better responsiveness
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
    debug_log "daemon" "INFO" "=== DAEMON COMMAND START ==="
    debug_log "daemon" "INFO" "Handling command: $*"
    debug_log_environment "daemon"
    
    case "${1:-}" in
        --warn)
            debug_log "daemon" "INFO" "Calling cron_execute_warning with alarm='$2' minutes='$3'"
            cron_execute_warning "$2" "$3"
            ;;
        --execute)
            debug_log "daemon" "INFO" "Calling cron_execute_action with alarm='$2' action='$3' snoozed='${4:-false}'"
            cron_execute_action "$2" "$3" "${4:-false}"
            ;;
        --snooze)
            debug_log "daemon" "INFO" "Calling daemon_handle_snooze with alarm='$2' time='$3'"
            daemon_handle_snooze "$2" "$3"
            ;;
        --snooze-suspend)
            debug_log "daemon" "INFO" "Calling daemon_handle_snooze_suspend with alarm='$2'"
            daemon_handle_snooze_suspend "$2"
            ;;
        --sleep-now)
            debug_log "daemon" "INFO" "Calling daemon_handle_sleep_now with alarm='$2' action='$3'"
            daemon_handle_sleep_now "$2" "$3"
            ;;
        --test-notifications)
            debug_log "daemon" "INFO" "Running notification test"
            notify_test
            ;;
        *)
            debug_log "daemon" "ERROR" "Unknown daemon command: ${1:-}"
            echo "Unknown daemon command: ${1:-}" >&2
            exit 1
            ;;
    esac
    
    debug_log "daemon" "INFO" "=== DAEMON COMMAND END ==="
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
    # SCRIPT_DIR must be expanded when creating the command
    local breaktime_path="${SCRIPT_DIR:-/home/bpeeters/MEGA/repo/bash/breaktime}/breaktime.sh"
    logger -t breaktime "DEBUG: Using breaktime path: $breaktime_path"
    
    # Schedule warning
    local at_output
    at_output=$(echo "DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME ${breaktime_path} --warn \"${alarm_name}\" \"2\"" | at "${warn_hour}:${warn_minute}" 2>&1)
    if [[ $? -eq 0 ]]; then
        logger -t breaktime "Scheduled warning at ${warn_hour}:${warn_minute}: $at_output"
    else
        logger -t breaktime "ERROR: Failed to schedule warning at ${warn_hour}:${warn_minute}: $at_output"
    fi
    
    # Schedule suspend
    at_output=$(echo "DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME ${breaktime_path} --execute \"${alarm_name}\" \"${action}\"" | at "${new_hour}:${new_minute}" 2>&1)
    if [[ $? -eq 0 ]]; then
        logger -t breaktime "Scheduled suspend at ${new_hour}:${new_minute}: $at_output"
    else
        logger -t breaktime "ERROR: Failed to schedule suspend at ${new_hour}:${new_minute}: $at_output"
    fi
    
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
    
    # Calculate target execution time (current time + snooze duration)
    local current_time=$(date +%s)
    local target_time=$((current_time + snooze_duration * 60))
    
    # Get action for this alarm
    local action=$(config_get_alarm_action "$alarm_name")
    
    # Use NEW file-based scheduling (much more reliable than 'at' commands)
    local job_file=$(snooze_schedule_job "$alarm_name" "$target_time" "$action" "$new_count")
    
    logger -t breaktime "Snooze $new_count/$max_snoozes: scheduled file-based job $(basename "$job_file") for $(date -d "@$target_time" '+%H:%M:%S')"
}

