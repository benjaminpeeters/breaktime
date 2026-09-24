#!/bin/bash

# cron.sh - Cron job management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Cron job marker for easy identification
if [[ -z "${CRON_MARKER:-}" ]]; then
    readonly CRON_MARKER="# breaktime-managed"
fi

readonly MINUTES_PER_DAY=1440
readonly MINUTES_PER_WEEK=10080

cron_update_from_config() {
    echo -e "${BOLD}🔄 Updating cron jobs from configuration...${NC}"

    if [[ $(config_get_enabled) != "true" ]]; then
        echo -e "${YELLOW}⚠️  Breaktime is disabled in configuration${NC}"
        cron_remove_all
        return 0
    fi

    mkdir -p "${DEBUG_LOG_DIR}"

    # Remove existing breaktime cron jobs
    cron_remove_all

    # Clean up old snooze state files and reset counts for new day
    snooze_cleanup

    # Add new cron jobs for enabled alarms
    local alarm_count=0 alarm_name
    while read -r alarm_name; do
        if [[ -n "$alarm_name" ]] && [[ $(config_get_alarm_enabled "$alarm_name") == "true" ]]; then
            if cron_add_alarm "$alarm_name"; then
                alarm_count=$((alarm_count + 1))
            else
                echo -e "${RED}❌ Failed to add alarm: ${alarm_name}${NC}" >&2
            fi
        fi
    done < <(config_get_alarms)

    echo -e "${GREEN}✅ Scheduled ${alarm_count} alarm(s)${NC}"
    return 0
}

# "HH:MM" -> minutes since midnight
cron_time_to_minutes() {
    local hour="${1%%:*}"
    local minute="${1##*:}"
    echo $((10#$hour * 60 + 10#$minute))
}

# Is day-of-week index (0 = Sunday, may be out of 0..6) a configured workday?
cron_is_workday() {
    local day=$(( ($1 % 7 + 7) % 7 ))
    local workdays=" ${2} "
    [[ "$workdays" == *" ${day} "* ]]
}

# Print "<minute-of-week>" for every occurrence of an alarm during the week.
# Minute-of-week 0 is Sunday 00:00, matching cron's day-of-week numbering.
#
# "evening" mode: each logical day d starts at `day_starts_at`. A night alarm
# (after `evening_starts_at` or before `day_starts_at`) uses the weekday time
# when the NEXT day is a workday, so a 00:30 bedtime belongs to the evening
# before. Daytime alarms use the weekday time when day d itself is a workday.
# "calendar" mode: the weekday time applies on workdays, by calendar date.
cron_alarm_occurrences() {
    local alarm_name="$1"
    local weekday_time weekend_time
    weekday_time=$(config_get_alarm_time "$alarm_name" "weekdays")
    weekend_time=$(config_get_alarm_time "$alarm_name" "weekends")

    local workdays mode day_start evening_start
    workdays=$(config_get_workday_indices)
    mode=$(config_get_schedule_value mode evening)
    day_start=$(cron_time_to_minutes "$(config_get_schedule_value day_starts_at "04:00")")
    evening_start=$(cron_time_to_minutes "$(config_get_schedule_value evening_starts_at "18:00")")

    # The alarm counts as a night alarm based on its weekday time (or weekend time if unset)
    local reference_time="${weekday_time:-$weekend_time}"
    [[ -n "$reference_time" ]] || return 0
    local reference_minutes is_night=false
    reference_minutes=$(cron_time_to_minutes "$reference_time")
    if [[ "$mode" == "evening" ]] && { [[ $reference_minutes -ge $evening_start ]] || [[ $reference_minutes -lt $day_start ]]; }; then
        is_night=true
    fi

    local day time minutes fire_day
    for day in 0 1 2 3 4 5 6; do
        local check_day=$day
        [[ "$is_night" == true ]] && check_day=$((day + 1))

        if cron_is_workday "$check_day" "$workdays"; then
            time="$weekday_time"
        else
            time="$weekend_time"
        fi
        [[ -n "$time" ]] || continue

        minutes=$(cron_time_to_minutes "$time")
        fire_day=$day
        # In evening mode, times before the start of the day belong to the evening before
        if [[ "$mode" == "evening" ]] && [[ $minutes -lt $day_start ]]; then
            fire_day=$((day + 1))
        fi
        echo $(( (fire_day * MINUTES_PER_DAY + minutes) % MINUTES_PER_WEEK ))
    done
}

# Build the cron lines for one alarm (warnings + main action), grouped by time
cron_build_alarm_jobs() {
    local alarm_name="$1"
    local action warnings
    action=$(config_get_alarm_action "$alarm_name")
    warnings=$(config_get_alarm_warnings "$alarm_name")

    local script="${SCRIPT_DIR}/breaktime.sh"
    local log="${DEBUG_LOG_DIR}/cron-execution.log"

    # key "<HH> <MM>|<command>" -> list of days
    local -A jobs=()
    local order=()
    local occurrence offset command week_minute key
    while read -r occurrence; do
        [[ -n "$occurrence" ]] || continue
        for offset in $warnings 0; do
            if [[ "$offset" == "0" ]]; then
                command="--execute \"${alarm_name}\" \"${action}\""
            else
                command="--warn \"${alarm_name}\" \"${offset}\""
            fi
            week_minute=$(( ((occurrence - offset) % MINUTES_PER_WEEK + MINUTES_PER_WEEK) % MINUTES_PER_WEEK ))
            local dow=$(( week_minute / MINUTES_PER_DAY ))
            local day_minutes=$(( week_minute % MINUTES_PER_DAY ))
            key="$(printf '%02d %02d' $((day_minutes % 60)) $((day_minutes / 60)))|${command}"
            if [[ -z "${jobs[$key]:-}" ]]; then
                order+=("$key")
                jobs[$key]="$dow"
            elif [[ " ${jobs[$key]//,/ } " != *" ${dow} "* ]]; then
                jobs[$key]="${jobs[$key]},${dow}"
            fi
        done
    done < <(cron_alarm_occurrences "$alarm_name")

    for key in "${order[@]}"; do
        local days
        days=$(echo "${jobs[$key]}" | tr ',' '\n' | sort -n | paste -sd, -)
        echo "${key%%|*} * * ${days} \"${script}\" ${key#*|} >> \"${log}\" 2>&1 ${CRON_MARKER}"
    done
}

cron_add_alarm() {
    local alarm_name="$1"
    local new_jobs
    new_jobs=$(cron_build_alarm_jobs "$alarm_name")

    if [[ -z "$new_jobs" ]]; then
        echo -e "${YELLOW}⚠️  ${alarm_name}: no weekday or weekend time set, nothing scheduled${NC}"
        return 0
    fi

    {
        crontab -l 2>/dev/null || true
        echo "$new_jobs"
    } | crontab -
}

cron_calculate_warning_time() {
    local hour="$1"
    local minute="$2"
    local warning_minutes="$3"

    local total_minutes=$(( (10#$hour * 60 + 10#$minute - warning_minutes) % MINUTES_PER_DAY ))
    if [[ $total_minutes -lt 0 ]]; then
        total_minutes=$((total_minutes + MINUTES_PER_DAY))
    fi

    printf "%02d:%02d" $((total_minutes / 60)) $((total_minutes % 60))
}

cron_remove_all() {
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)
    if [[ "$current_crontab" == *"${CRON_MARKER}"* ]]; then
        { echo "$current_crontab" | grep -vF "${CRON_MARKER}" || true; } | crontab -
        echo -e "${GREEN}✅ Removed existing breaktime cron jobs${NC}"
    fi
}

# "0,1,2,3,4" -> "Sun–Thu"; "0,6" -> "Sat–Sun"; all days -> "Daily"
cron_format_days() {
    local -a present=(0 0 0 0 0 0 0)
    local day count=0
    for day in ${1//,/ }; do
        present[day]=1
        count=$((count + 1))
    done
    if [[ $count -ge 7 ]]; then
        echo "Daily"
        return
    elif [[ $count -eq 0 ]]; then
        echo "never"
        return
    fi

    # Start on the first day of a run (a present day whose previous day is absent),
    # scanning from Monday so runs read naturally.
    local start=-1 i
    for i in 1 2 3 4 5 6 0; do
        if [[ ${present[i]} -eq 1 && ${present[(i + 6) % 7]} -eq 0 ]]; then
            start=$i
            break
        fi
    done

    local parts=() run_start=-1 prev=-1 step idx
    for step in 0 1 2 3 4 5 6; do
        idx=$(( (start + step) % 7 ))
        if [[ ${present[idx]} -eq 1 ]]; then
            [[ $run_start -lt 0 ]] && run_start=$idx
            prev=$idx
        elif [[ $run_start -ge 0 ]]; then
            parts+=("$(cron_format_run "$run_start" "$prev")")
            run_start=-1
        fi
    done
    [[ $run_start -ge 0 ]] && parts+=("$(cron_format_run "$run_start" "$prev")")

    local result="${parts[0]}" part
    for part in "${parts[@]:1}"; do
        result="${result}, ${part}"
    done
    echo "$result"
}

cron_format_run() {
    local names=(Sun Mon Tue Wed Thu Fri Sat)
    if [[ "$1" == "$2" ]]; then
        echo "${names[$1]}"
    elif [[ $(( ($1 + 1) % 7 )) == "$2" ]]; then
        echo "${names[$1]}, ${names[$2]}"
    else
        echo "${names[$1]}–${names[$2]}"
    fi
}

cron_show_next() {
    if ! crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        echo -e "${YELLOW}   No scheduled breaks found${NC}"
        echo -e "   Configure breaks with: ${BOLD}breaktime --config${NC}"
        return 0
    fi

    echo -e "   Current time: ${BLUE}$(date '+%a %Y-%m-%d %H:%M')${NC}"
    echo -e "   Workdays:     ${BLUE}$(cron_format_days "$(config_get_workday_indices | tr ' ' ',')")${NC} (mode: $(config_get_schedule_value mode evening))"
    echo ""

    local line minute hour days kind alarm arg
    while read -r minute hour _ _ days line; do
        [[ "$line" == *"${CRON_MARKER}"* ]] || continue
        [[ "$line" =~ --(warn|execute)\ \"([^\"]*)\"\ \"([^\"]*)\" ]] || continue
        kind="${BASH_REMATCH[1]}"
        alarm="$(format_alarm_name "${BASH_REMATCH[2]}")"
        arg="${BASH_REMATCH[3]}"
        if [[ "$kind" == "warn" ]]; then
            echo -e "   ⚠️  ${YELLOW}${hour}:${minute}${NC}  ${alarm} warning (${arg} min before) — $(cron_format_days "$days")"
        else
            echo -e "   🎯 ${GREEN}${hour}:${minute}${NC}  ${alarm}: ${arg} — $(cron_format_days "$days")"
        fi
    done < <(crontab -l 2>/dev/null | grep -F "${CRON_MARKER}" | sort -k2,2n -k1,1n)
}

# Handle cron job execution
cron_execute_warning() {
    local alarm_name="$1"
    local warning_minutes="$2"
    
    debug_log "cron" "INFO" "=== WARNING EXECUTION START ==="
    debug_log "cron" "INFO" "Executing warning for alarm='$alarm_name' minutes='$warning_minutes'"
    debug_log_environment "cron"
    
    # Check if desktop notifications are enabled
    local desktop_notifications
    desktop_notifications=$(config_get_desktop_notifications)
    debug_log "cron" "INFO" "Desktop notifications setting: $desktop_notifications"
    
    if [[ "$desktop_notifications" == "false" ]]; then
        # Just log, don't show notification
        debug_log "cron" "INFO" "Warning suppressed (notifications disabled): $alarm_name in $warning_minutes minutes"
        logger -t breaktime "Warning suppressed (notifications disabled): $alarm_name in $warning_minutes minutes"
    else
        local message
        message=$(config_get_warning_message "$alarm_name" "$warning_minutes")
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
    local desktop_notifications
    desktop_notifications=$(config_get_desktop_notifications)
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