#!/bin/bash

# cron.sh - Cron job management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Cron job marker for easy identification
if [[ -z "${CRON_MARKER:-}" ]]; then
    readonly CRON_MARKER="# breaktime-managed"
fi

cron_update_from_config() {
    echo -e "${BOLD}🔄 Updating cron jobs from configuration...${NC}"
    
    if [[ $(config_get_enabled) != "true" ]]; then
        echo -e "${YELLOW}⚠️  Breaktime is disabled in configuration${NC}"
        cron_remove_all
        return 0
    fi
    
    # Remove existing breaktime cron jobs
    cron_remove_all
    
    # Clean up old snooze state files and reset counts for new day
    snooze_cleanup
    
    # Add new cron jobs for enabled alarms
    local alarm_count=0
    while read -r alarm_name; do
        if [[ -n "$alarm_name" ]] && [[ $(config_get_alarm_enabled "$alarm_name") == "true" ]]; then
            if cron_add_alarm "$alarm_name"; then
                ((alarm_count++))
            else
                echo -e "${RED}❌ Failed to add alarm: ${alarm_name}${NC}" >&2
            fi
        fi
    done < <(config_get_alarms)
    
    echo -e "${GREEN}✅ Updated ${alarm_count} cron jobs${NC}"
    return 0
}

cron_add_alarm() {
    local alarm_name="$1"
    local weekday_time=$(config_get_alarm_time "$alarm_name" "weekdays")
    local weekend_time=$(config_get_alarm_time "$alarm_name" "weekends")
    local action=$(config_get_alarm_action "$alarm_name")
    local new_jobs=""
    
    # Add weekday schedule if defined
    if [[ -n "$weekday_time" ]]; then
        local hour minute
        hour=$(echo "$weekday_time" | cut -d: -f1)
        minute=$(echo "$weekday_time" | cut -d: -f2)
        
        # Schedule warnings
        while read -r warning_minutes; do
            if [[ -n "$warning_minutes" ]]; then
                local warn_time=$(cron_calculate_warning_time "$hour" "$minute" "$warning_minutes")
                local warn_hour=$(echo "$warn_time" | cut -d: -f1)
                local warn_minute=$(echo "$warn_time" | cut -d: -f2)
                
                new_jobs="${new_jobs}${warn_minute} ${warn_hour} * * 1-5 ${SCRIPT_DIR}/breaktime.sh --warn \"${alarm_name}\" \"${warning_minutes}\" >> /tmp/breaktime/logs/cron-execution.log 2>&1 ${CRON_MARKER}\n"
            fi
        done < <(config_get_alarm_warnings "$alarm_name")
        
        # Schedule main action
        new_jobs="${new_jobs}${minute} ${hour} * * 1-5 ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\" >> /tmp/breaktime/logs/cron-execution.log 2>&1 ${CRON_MARKER}\n"
    fi
    
    # Add weekend schedule if defined
    if [[ -n "$weekend_time" ]]; then
        local hour minute
        hour=$(echo "$weekend_time" | cut -d: -f1)
        minute=$(echo "$weekend_time" | cut -d: -f2)
        
        # Schedule warnings
        while read -r warning_minutes; do
            if [[ -n "$warning_minutes" ]]; then
                local warn_time=$(cron_calculate_warning_time "$hour" "$minute" "$warning_minutes")
                local warn_hour=$(echo "$warn_time" | cut -d: -f1)
                local warn_minute=$(echo "$warn_time" | cut -d: -f2)
                
                new_jobs="${new_jobs}${warn_minute} ${warn_hour} * * 6,0 ${SCRIPT_DIR}/breaktime.sh --warn \"${alarm_name}\" \"${warning_minutes}\" >> /tmp/breaktime/logs/cron-execution.log 2>&1 ${CRON_MARKER}\n"
            fi
        done < <(config_get_alarm_warnings "$alarm_name")
        
        # Schedule main action
        new_jobs="${new_jobs}${minute} ${hour} * * 6,0 ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\" >> /tmp/breaktime/logs/cron-execution.log 2>&1 ${CRON_MARKER}\n"
    fi
    
    # Add all new jobs at once
    if [[ -n "$new_jobs" ]]; then
        {
            crontab -l 2>/dev/null || true
            echo -e "${new_jobs%\\n}"  # Remove trailing newline
        } | crontab - 2>/dev/null || true
    fi
}

cron_calculate_warning_time() {
    local hour="$1"
    local minute="$2"
    local warning_minutes="$3"
    
    # Convert to total minutes
    local total_minutes=$((hour * 60 + minute))
    
    # Subtract warning minutes
    total_minutes=$((total_minutes - warning_minutes))
    
    # Handle day rollover
    if [[ $total_minutes -lt 0 ]]; then
        total_minutes=$((total_minutes + 1440))  # Add 24 hours
    fi
    
    # Convert back to hour:minute
    local new_hour=$((total_minutes / 60))
    local new_minute=$((total_minutes % 60))
    
    printf "%02d:%02d" "$new_hour" "$new_minute"
}

cron_remove_all() {
    # Remove all breaktime-managed cron jobs
    local current_crontab=$(crontab -l 2>/dev/null || true)
    if [[ -n "$current_crontab" ]]; then
        echo "$current_crontab" | grep -v "${CRON_MARKER}" | crontab - 2>/dev/null || true
        echo -e "${GREEN}✅ Removed existing breaktime cron jobs${NC}"
    fi
}

cron_remove_alarm_jobs() {
    local alarm_name="$1"
    # Remove all cron jobs for a specific alarm (both regular and snooze jobs)
    local current_crontab=$(crontab -l 2>/dev/null || true)
    if [[ -n "$current_crontab" ]]; then
        echo "$current_crontab" | grep -v "breaktime-managed.*${alarm_name}" | grep -v "breaktime-managed-snooze-${alarm_name}" | crontab - 2>/dev/null || true
    fi
}

cron_show_next() {
    if ! crontab -l 2>/dev/null | grep -q "${CRON_MARKER}"; then
        echo -e "${YELLOW}   No scheduled breaks found${NC}"
        echo -e "   Configure breaks with: ${BOLD}breaktime --config${NC}"
        return 0
    fi
    
    # Show next few scheduled executions
    local current_time=$(date '+%Y-%m-%d %H:%M')
    echo -e "   Current time: ${BLUE}${current_time}${NC}"
    echo ""
    
    # Parse cron jobs and show upcoming ones
    while read -r line; do
        if [[ "$line" =~ ${CRON_MARKER} ]]; then
            local cron_time=$(echo "$line" | awk '{print $2":"$1}')
            local cron_days=$(echo "$line" | awk '{print $5}')
            local alarm_info=$(echo "$line" | grep -o '"[^"]*"' | tr -d '"')
            
            # Determine day type
            local day_type=""
            case "$cron_days" in
                "1-5") day_type="Weekdays" ;;
                "6,0") day_type="Weekends" ;;
                "*") day_type="Daily" ;;
            esac
            
            if [[ "$line" =~ --warn ]]; then
                echo -e "   ⚠️  ${alarm_info} warning at ${YELLOW}${cron_time}${NC} (${day_type})"
            elif [[ "$line" =~ --execute ]]; then
                echo -e "   🎯 ${alarm_info} at ${GREEN}${cron_time}${NC} (${day_type})"
            fi
        fi
    done < <(crontab -l 2>/dev/null | sort)
}

# Handle cron job execution
cron_execute_warning() {
    local alarm_name="$1"
    local warning_minutes="$2"
    
    debug_log "cron" "INFO" "=== WARNING EXECUTION START ==="
    debug_log "cron" "INFO" "Executing warning for alarm='$alarm_name' minutes='$warning_minutes'"
    debug_log_environment "cron"
    
    # Check if desktop notifications are enabled
    local desktop_notifications=$(config_get_desktop_notifications)
    debug_log "cron" "INFO" "Desktop notifications setting: $desktop_notifications"
    
    if [[ "$desktop_notifications" == "false" ]]; then
        # Just log, don't show notification
        debug_log "cron" "INFO" "Warning suppressed (notifications disabled): $alarm_name in $warning_minutes minutes"
        logger -t breaktime "Warning suppressed (notifications disabled): $alarm_name in $warning_minutes minutes"
    else
        local message=$(config_get_warning_message "$alarm_name" "$warning_minutes")
        debug_log "cron" "INFO" "Warning message: '$message'"
        debug_log "cron" "INFO" "Calling notify_send_warning..."
        notify_send_warning "$alarm_name" "$message" "$warning_minutes"
        debug_log "cron" "INFO" "notify_send_warning completed"
    fi
    
    debug_log "cron" "INFO" "=== WARNING EXECUTION END ==="
}

cron_execute_action() {
    local alarm_name="$1"
    local action="$2"
    local is_snoozed="${3:-false}"  # New parameter to indicate if this is from a snooze
    
    debug_log "cron" "INFO" "=== ACTION EXECUTION START ==="
    debug_log "cron" "INFO" "Executing action for alarm='$alarm_name' action='$action' is_snoozed='$is_snoozed'"
    debug_log_environment "cron"
    
    # Only reset snooze count if this is NOT a snoozed execution
    if [[ "$is_snoozed" != "true" ]]; then
        debug_log "cron" "INFO" "Resetting snooze count for $alarm_name (regular schedule)"
        logger -t breaktime "Resetting snooze count for $alarm_name (regular schedule)"
        snooze_reset_count "$alarm_name"
    else
        debug_log "cron" "INFO" "Preserving snooze count for $alarm_name (snoozed execution)"
        logger -t breaktime "Preserving snooze count for $alarm_name (snoozed execution)"
    fi
    
    # Clean up any pending snooze jobs
    debug_log "cron" "INFO" "Cleaning up pending snooze jobs for $alarm_name"
    snooze_cleanup_jobs "$alarm_name"
    
    # Check if desktop notifications are enabled
    local desktop_notifications=$(config_get_desktop_notifications)
    debug_log "cron" "INFO" "Desktop notifications setting: $desktop_notifications"
    
    if [[ "$desktop_notifications" == "false" ]]; then
        # Auto-execute without showing dialog
        debug_log "cron" "INFO" "Desktop notifications disabled, auto-executing $action for $alarm_name"
        logger -t breaktime "Desktop notifications disabled, auto-executing $action for $alarm_name"
        echo "⚡ Breaktime: Auto-executing $action for $alarm_name (notifications disabled)"
        
        # Wait a moment for user to see terminal message
        sleep 3
        
        # Execute the action directly
        debug_log "cron" "INFO" "Calling cron_execute_system_action with action='$action'"
        cron_execute_system_action "$action"
        debug_log "cron" "INFO" "cron_execute_system_action completed"
    else
        # Send final notification (this will handle user interaction)
        debug_log "cron" "INFO" "Showing final notification dialog"
        debug_log "cron" "INFO" "Calling notify_send_final with alarm='$alarm_name' action='$action'"
        notify_send_final "$alarm_name" "$action"
        debug_log "cron" "INFO" "notify_send_final completed"
    fi
    
    debug_log "cron" "INFO" "=== ACTION EXECUTION END ==="
    
    # Note: Action execution is now handled by notify_send_final through user interaction
    # This function only gets called for immediate execution (--sleep-now)
}

# Execute the actual system action (called when user clicks "Suspend Now")
cron_execute_system_action() {
    local action="$1"
    
    debug_log "cron" "INFO" "=== SYSTEM ACTION EXECUTION START ==="
    debug_log "cron" "INFO" "Executing system action: $action"
    logger -t breaktime "Executing system action: $action"
    
    case "$action" in
        "suspend")
            debug_log "cron" "INFO" "Attempting suspend via systemctl"
            # Try multiple suspend methods in order of preference
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl suspend; then
                    debug_log "cron" "INFO" "systemctl suspend succeeded"
                else
                    debug_log "cron" "ERROR" "systemctl suspend failed"
                    logger -t breaktime "systemctl suspend failed"
                fi
            elif command -v pm-suspend >/dev/null 2>&1; then
                debug_log "cron" "INFO" "Attempting suspend via pm-suspend"
                if pm-suspend; then
                    debug_log "cron" "INFO" "pm-suspend succeeded"
                else
                    debug_log "cron" "ERROR" "pm-suspend failed"
                    logger -t breaktime "pm-suspend failed"
                fi
            else
                debug_log "cron" "INFO" "Attempting suspend via dbus"
                # Use dbus as last resort
                if dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.Suspend boolean:true; then
                    debug_log "cron" "INFO" "dbus suspend succeeded"
                else
                    debug_log "cron" "ERROR" "dbus suspend failed"
                    logger -t breaktime "dbus suspend failed"
                fi
            fi
            ;;
        "shutdown")
            debug_log "cron" "INFO" "Attempting shutdown"
            systemctl poweroff || shutdown -h now
            ;;
        "hibernate")
            debug_log "cron" "INFO" "Attempting hibernate"
            systemctl hibernate
            ;;
        *)
            debug_log "cron" "ERROR" "Unknown action: $action"
            echo "Unknown action: $action" >&2
            exit 1
            ;;
    esac
    
    debug_log "cron" "INFO" "=== SYSTEM ACTION EXECUTION END ==="
}