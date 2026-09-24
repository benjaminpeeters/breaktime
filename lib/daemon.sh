#!/bin/bash

# daemon.sh - Background daemon for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

daemon_run() {
    echo "Starting breaktime daemon..." | logger -t breaktime

    # Initialize snooze system and log directory
    snooze_init
    mkdir -p "${DEBUG_LOG_DIR}"
    
    # Ensure configuration exists
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "No configuration found, creating default..." | logger -t breaktime
        mkdir -p "${CONFIG_DIR}"
        cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
    fi
    
    # Monitor configuration file for changes (also performs the initial cron setup)
    daemon_monitor_config &
    local monitor_pid=$!
    trap 'kill "$monitor_pid" 2>/dev/null; exit 0' TERM INT
    
    local last_cleanup=0 now
    while true; do
        # Restart the config monitor if it died for any reason
        if ! kill -0 "$monitor_pid" 2>/dev/null; then
            echo "Config monitor stopped, restarting it" | logger -t breaktime
            daemon_monitor_config &
            monitor_pid=$!
        fi

        # Check for pending snooze jobs
        snooze_check_pending

        # Clean up old completed jobs once per hour
        now=$(date +%s)
        if [[ $((now - last_cleanup)) -ge 3600 ]]; then
            snooze_cleanup_completed
            last_cleanup=$now
        fi

        # Short sleeps in the background keep the TERM trap responsive
        sleep 30 &
        wait $! || true
    done
}

daemon_monitor_config() {
    local last_modified=""
    
    while true; do
        if [[ -f "${CONFIG_FILE}" ]]; then
            local current_modified
            current_modified=$(stat -c %Y "${CONFIG_FILE}" 2>/dev/null || echo "0")

            if [[ "$current_modified" != "$last_modified" ]]; then
                [[ -n "$last_modified" ]] && sleep 2  # Wait for file write to complete

                if config_validate 2> >(logger -t breaktime); then
                    if cron_update_from_config >/dev/null; then
                        echo "Configuration loaded, cron jobs updated" | logger -t breaktime
                    else
                        echo "Failed to update cron jobs" | logger -t breaktime
                    fi
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

# Handle immediate sleep request
daemon_handle_sleep_now() {
    local alarm_name="$1"
    local action="$2"
    
    debug_log "daemon" "INFO" "daemon_handle_sleep_now called with alarm=$alarm_name action=$action"
    
    # Reset snooze count since we're executing now
    snooze_reset_count "$alarm_name"
    
    # Clean up any pending snooze jobs (but keep original cron schedule)
    snooze_cleanup_jobs "$alarm_name"
    
    debug_log "daemon" "INFO" "About to execute action $action"
    
    # Execute the system action directly
    cron_execute_system_action "$action"
    
    debug_log "daemon" "INFO" "Finished executing action $action"
}

# Handle snooze request from suspend dialog
daemon_handle_snooze_suspend() {
    local alarm_name="$1"
    
    debug_log "daemon" "INFO" "daemon_handle_snooze_suspend called with alarm=$alarm_name"
    
    # Check if snoozing is still allowed
    if [[ $(snooze_is_allowed "$alarm_name") != "true" ]]; then
        logger -t breaktime "Snooze limit reached for $alarm_name, ignoring snooze request"
        return 1
    fi
    
    # Increment snooze count
    local new_count
    new_count=$(snooze_increment_count "$alarm_name")
    local max_snoozes
    max_snoozes=$(snooze_get_max)
    local snooze_duration
    snooze_duration=$(snooze_get_duration)
    
    debug_log "daemon" "INFO" "Incremented snooze count to $new_count/$max_snoozes"
    
    # Calculate target execution time (current time + snooze duration)
    local current_time
    current_time=$(date +%s)
    local target_time=$((current_time + snooze_duration * 60))
    
    # Get action for this alarm
    local action
    action=$(config_get_alarm_action "$alarm_name")
    
    # Schedule via a job file that the daemon picks up
    local job_file
    job_file=$(snooze_schedule_job "$alarm_name" "$target_time" "$action" "$new_count")
    
    logger -t breaktime "Snooze $new_count/$max_snoozes: scheduled file-based job $(basename "$job_file") for $(date -d "@$target_time" '+%H:%M:%S')"
}

