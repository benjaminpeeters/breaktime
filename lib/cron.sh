#!/bin/bash

# cron.sh - Cron job management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Cron job marker for easy identification
readonly CRON_MARKER="# breaktime-managed"

cron_update_from_config() {
    echo -e "${BOLD}🔄 Updating cron jobs from configuration...${NC}"
    
    if [[ $(config_get_enabled) != "true" ]]; then
        echo -e "${YELLOW}⚠️  Breaktime is disabled in configuration${NC}"
        cron_remove_all
        return 0
    fi
    
    # Remove existing breaktime cron jobs
    cron_remove_all
    
    # Add new cron jobs for enabled alarms
    local alarm_count=0
    while read -r alarm_name; do
        if [[ -n "$alarm_name" ]] && [[ $(config_get_alarm_enabled "$alarm_name") == "true" ]]; then
            cron_add_alarm "$alarm_name"
            ((alarm_count++))
        fi
    done < <(config_get_alarms)
    
    echo -e "${GREEN}✅ Updated ${alarm_count} cron jobs${NC}"
}

cron_add_alarm() {
    local alarm_name="$1"
    local weekday_time=$(config_get_alarm_time "$alarm_name" "weekdays")
    local weekend_time=$(config_get_alarm_time "$alarm_name" "weekends")
    local action=$(config_get_alarm_action "$alarm_name")
    
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
                
                (crontab -l 2>/dev/null || true; echo "${warn_minute} ${warn_hour} * * 1-5 ${SCRIPT_DIR}/breaktime.sh --warn \"${alarm_name}\" \"${warning_minutes}\" ${CRON_MARKER}") | crontab -
            fi
        done < <(config_get_alarm_warnings "$alarm_name")
        
        # Schedule main action
        (crontab -l 2>/dev/null || true; echo "${minute} ${hour} * * 1-5 ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\" ${CRON_MARKER}") | crontab -
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
                
                (crontab -l 2>/dev/null || true; echo "${warn_minute} ${warn_hour} * * 6,0 ${SCRIPT_DIR}/breaktime.sh --warn \"${alarm_name}\" \"${warning_minutes}\" ${CRON_MARKER}") | crontab -
            fi
        done < <(config_get_alarm_warnings "$alarm_name")
        
        # Schedule main action
        (crontab -l 2>/dev/null || true; echo "${minute} ${hour} * * 6,0 ${SCRIPT_DIR}/breaktime.sh --execute \"${alarm_name}\" \"${action}\" ${CRON_MARKER}") | crontab -
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
    if crontab -l 2>/dev/null | grep -v "${CRON_MARKER}" | crontab - 2>/dev/null; then
        echo -e "${GREEN}✅ Removed existing breaktime cron jobs${NC}"
    fi
}

cron_show_next() {
    if ! crontab -l 2>/dev/null | grep -q "${CRON_MARKER}"; then
        echo -e "${YELLOW}   No scheduled breaks found${NC}"
        echo "   Configure breaks with: ${BOLD}breaktime --config${NC}"
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
    
    local message=$(config_get_warning_message "$alarm_name" "$warning_minutes")
    notify_send_warning "$alarm_name" "$message" "$warning_minutes"
}

cron_execute_action() {
    local alarm_name="$1"
    local action="$2"
    
    # Send final notification
    notify_send_final "$alarm_name" "$action"
    
    # Wait a moment for notification to show
    sleep 2
    
    # Execute the action
    case "$action" in
        "suspend")
            systemctl suspend
            ;;
        "shutdown")
            shutdown -h now
            ;;
        "hibernate")
            systemctl hibernate
            ;;
        *)
            echo "Unknown action: $action" >&2
            exit 1
            ;;
    esac
}