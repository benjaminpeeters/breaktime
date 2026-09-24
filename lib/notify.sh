#!/bin/bash

# notify.sh - YAD-based notification system for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Main notification function using YAD
yad_send_notification() {
    local alarm_name="$1"
    local message="$2"
    local minutes="$3"
    local is_final="${4:-false}"
    
    debug_log "notify" "INFO" "=== YAD NOTIFICATION START ==="
    debug_log "notify" "INFO" "yad_send_notification called: alarm='$alarm_name' minutes='$minutes' is_final='$is_final'"
    debug_log "notify" "INFO" "Message: '$message'"
    debug_log_environment "notify"
    
    # Check if a recent suspend success occurred for this alarm (within last 2 minutes)
    if [[ "$is_final" == "true" ]]; then
        debug_log "notify" "INFO" "Checking for recent suspend success files"
        local recent_success
        recent_success=$(find "${SNOOZE_STATE_DIR}" -name "suspend_success_${alarm_name}_*" -newermt "2 minutes ago" 2>/dev/null | head -1)
        if [[ -n "$recent_success" ]]; then
            debug_log "notify" "INFO" "Skipping dialog - recent suspend success found: $(basename "$recent_success")"
            logger -t breaktime "Skipping dialog for $alarm_name - recent suspend success found: $(basename "$recent_success")"
            return 0
        fi
        debug_log "notify" "INFO" "No recent suspend success found, proceeding with dialog"
    fi
    
    # Escape Pango markup characters in user-provided text
    message=$(notify_escape_markup "$message")

    # Determine dialog type and styling based on urgency
    local dialog_type="--info"
    local timeout=8
    local width=400
    local height=""
    local buttons=()

    if [[ "$is_final" == "true" ]]; then
        dialog_type="--warning"
        timeout=0  # No timeout - persistent dialog
        width=660
        height=280

        # Check snooze availability for final suspend dialog
        local remaining_snoozes current_count max_snoozes snooze_duration
        remaining_snoozes=$(snooze_get_remaining "$alarm_name")
        current_count=$(snooze_get_count "$alarm_name")
        max_snoozes=$(snooze_get_max)
        snooze_duration=$(snooze_get_duration)

        local action_label
        action_label="$(notify_action_label "$(config_get_alarm_action "$alarm_name")") Now"
        buttons+=("--button=${action_label}:0")
        if [[ $remaining_snoozes -gt 0 ]]; then
            buttons+=("--button=Snooze ${snooze_duration}min (${remaining_snoozes}/${max_snoozes} left):1")
            message="<span size='large'>${message}\n\n📊 Snooze status: Used ${current_count}/${max_snoozes}</span>"
        else
            message="<span size='large'>${message}\n\n🚫 Snooze limit reached (${max_snoozes}/${max_snoozes})</span>"
        fi
    elif [[ $minutes -le 2 ]]; then
        timeout=12
        width=450
        buttons+=("--button=OK:0")
    elif [[ $minutes -le 5 ]]; then
        timeout=10
        buttons+=("--button=OK:0")
    fi

    # Determine icon based on alarm type (no icon for final dialogs)
    local icon="dialog-information"
    if [[ "$is_final" == "true" ]]; then
        icon=""
    else
        case "$alarm_name" in
            "bedtime") icon="night-light" ;;
            "lunch_break") icon="applications-dining" ;;
            "afternoon_nap"|"focus_break") icon="appointment-soon" ;;
        esac
    fi

    local yad_cmd=(
        yad "$dialog_type"
        --text="$message"
        --title="Breaktime - $(format_alarm_name "$alarm_name")"
        --borders=30
        --timeout="$timeout"
        --center
        --on-top
        --no-escape
        --width="$width"
        --skip-taskbar
        --window-icon=clock
        --sticky
        --always-print-result
    )
    [[ -n "$icon" ]] && yad_cmd+=(--image="$icon")

    # Close protection and styling for final dialogs
    if [[ "$is_final" == "true" ]]; then
        yad_cmd+=(--undecorated --fixed --modal --keep-above --skip-pager --height="$height" --text-align=center)
    fi
    yad_cmd+=("${buttons[@]}")

    # Execute with proper environment
    local result=0
    debug_log "notify" "INFO" "Checking if YAD is available..."
    if command -v yad >/dev/null 2>&1; then
        debug_log "notify" "INFO" "YAD is available, command: ${yad_cmd[*]}"

        # Cron jobs run without a session environment: fill in the usual defaults
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        fi

        # Detect and set the active display
        if [[ -z "${DISPLAY:-}" ]]; then
            DISPLAY=$(detect_active_display)
            export DISPLAY
        fi
        debug_log "notify" "INFO" "Using detected display: $DISPLAY"
        
        # Test if display is accessible
        debug_log "notify" "INFO" "Testing display accessibility..."
        if xset q &>/dev/null; then
            debug_log "notify" "INFO" "Display $DISPLAY is accessible"
        else
            debug_log "notify" "WARN" "Display $DISPLAY is not accessible, will try anyway"
        fi
        
        # For final dialogs, keep showing until user makes a choice
        if [[ "$is_final" == "true" ]]; then
            debug_log "notify" "INFO" "Showing final dialog (persistent until user choice)"
            local made_choice=false
            local attempt=1
            while [[ "$made_choice" == "false" ]]; do
                debug_log "notify" "INFO" "Dialog attempt #$attempt"
                
                # Capture stderr for debugging
                local yad_stderr yad_error_output
                yad_stderr=$(mktemp)
                result=0
                "${yad_cmd[@]}" 2>"$yad_stderr" || result=$?
                yad_error_output=$(cat "$yad_stderr" 2>/dev/null)
                rm -f "$yad_stderr" 2>/dev/null
                
                debug_log "notify" "INFO" "YAD dialog result code: $result for $alarm_name"
                if [[ -n "$yad_error_output" ]]; then
                    debug_log "notify" "WARN" "YAD stderr output: $yad_error_output"
                fi
                
                # Check if user made a valid choice (clicked a button)
                case $result in
                    0)
                        # Suspend Now button
                        debug_log "notify" "INFO" "User clicked Suspend Now for $alarm_name"
                        logger -t breaktime "User clicked Suspend Now for $alarm_name"
                        made_choice=true
                        # Handle suspend immediately
                        local action
                        action=$(config_get_alarm_action "$alarm_name")
                        debug_log "notify" "INFO" "Executing system action: $action for $alarm_name"
                        logger -t breaktime "Executing system action: $action for $alarm_name"
                        # Reset snooze count and clean up jobs
                        snooze_reset_count "$alarm_name"
                        snooze_cleanup_jobs "$alarm_name"
                        
                        # Create success marker to prevent dialog reshowing after resume
                        local success_file
                        success_file="${SNOOZE_STATE_DIR}/suspend_success_${alarm_name}_$(date +%s)"
                        echo "$(date): Successfully suspended for $alarm_name" > "$success_file"
                        debug_log "notify" "INFO" "Created success marker: $success_file"
                        
                        # Execute the system action directly
                        debug_log "notify" "INFO" "Calling cron_execute_system_action"
                        cron_execute_system_action "$action"
                        # Exit the script entirely after suspend to prevent dialog loop
                        debug_log "notify" "INFO" "System action completed, exiting notification process"
                        logger -t breaktime "System action completed, exiting notification process"
                        exit 0
                        ;;
                    1)
                        # Snooze button
                        debug_log "notify" "INFO" "User clicked Snooze for $alarm_name"
                        logger -t breaktime "User clicked Snooze for $alarm_name"
                        made_choice=true
                        # Handle snooze immediately
                        if [[ $(snooze_is_allowed "$alarm_name") == "true" ]]; then
                            debug_log "notify" "INFO" "Processing snooze request for $alarm_name"
                            logger -t breaktime "Processing snooze request for $alarm_name"
                            "${SCRIPT_DIR}/breaktime.sh" --snooze-suspend "$alarm_name"
                        else
                            debug_log "notify" "WARN" "Snooze not allowed for $alarm_name"
                            logger -t breaktime "Snooze not allowed for $alarm_name"
                        fi
                        ;;
                    *)
                        # Dialog was closed improperly (Alt+F4, etc.) - show it again
                        debug_log "notify" "WARN" "Suspend dialog dismissed improperly for $alarm_name (exit code: $result), attempt #$attempt"
                        logger -t breaktime "Suspend dialog dismissed improperly for $alarm_name (exit code: $result), reshowing..."
                        sleep 1  # Brief pause before reshowing
                        attempt=$((attempt + 1))
                        if [[ $attempt -gt 10 ]]; then
                            debug_log "notify" "ERROR" "Too many failed dialog attempts, giving up"
                            made_choice=true
                        fi
                        ;;
                esac
            done
        else
            # Regular warnings - show once
            debug_log "notify" "INFO" "Showing warning dialog (one-time)"
            local yad_stderr yad_error_output
            yad_stderr=$(mktemp)
            "${yad_cmd[@]}" 2>"$yad_stderr" || result=$?
            yad_error_output=$(cat "$yad_stderr" 2>/dev/null)
            rm -f "$yad_stderr" 2>/dev/null
            
            debug_log "notify" "INFO" "Warning dialog result code: $result"
            if [[ -n "$yad_error_output" ]]; then
                debug_log "notify" "WARN" "YAD stderr output: $yad_error_output"
            fi
        fi
        
        if [[ "$is_final" != "true" ]] && [[ $result -eq 0 ]]; then
            debug_log "notify" "INFO" "User acknowledged warning for $alarm_name"
        fi
    else
        # Fallback to zenity or notify-send
        debug_log "notify" "WARN" "YAD not available, falling back to zenity/notify-send"
        fallback_notification "$alarm_name" "$message" "$minutes" "$is_final"
    fi
    
    # Log notification
    debug_log "notify" "INFO" "YAD notification completed: $alarm_name in $minutes minutes"
    logger -t breaktime "YAD notification: $alarm_name in $minutes minutes"
    
    debug_log "notify" "INFO" "=== YAD NOTIFICATION END ==="
    
    # Sound disabled per user preference
}

# Fallback notification system
fallback_notification() {
    local alarm_name="$1"
    local message="$2"
    local minutes="$3"
    local is_final="${4:-false}"
    
    local timeout=10
    if [[ $minutes -le 2 ]]; then
        timeout=15
    fi
    
    # Try zenity first
    if command -v zenity >/dev/null 2>&1; then
        local dialog_type="--info"
        if [[ $minutes -le 5 ]] || [[ "$is_final" == "true" ]]; then
            dialog_type="--warning"
        fi
        
        zenity $dialog_type \
            --text="$message" \
            --title="Breaktime - $(format_alarm_name "$alarm_name")" \
            --timeout=$timeout \
            --width=400 \
            2>/dev/null || true
            
        logger -t breaktime "Zenity fallback: $alarm_name in $minutes minutes"
    
    # Last resort: notify-send
    elif command -v notify-send >/dev/null 2>&1; then
        local urgency="normal"
        if [[ $minutes -le 2 ]]; then
            urgency="critical"
        fi
        
        notify-send \
            --urgency="$urgency" \
            --icon="dialog-information" \
            --expire-time=$((timeout * 1000)) \
            "Breaktime: $(format_alarm_name "$alarm_name")" \
            "$message" \
            2>/dev/null || true
            
        logger -t breaktime "notify-send fallback: $alarm_name in $minutes minutes"
    else
        # Terminal fallback
        echo "🔔 BREAKTIME ALERT: $message"
        logger -t breaktime "Terminal fallback: $alarm_name in $minutes minutes"
    fi
}

# Warning notification wrapper (called by cron)
notify_send_warning() {
    local alarm_name="$1"
    local message="$2"
    local minutes="$3"
    
    yad_send_notification "$alarm_name" "$message" "$minutes" "false"
}

# Final action notification wrapper
notify_send_final() {
    local alarm_name="$1"
    local action="$2"
    
    local action_text=""
    case "$action" in
        "suspend") action_text="💤 Suspending system now" ;;
        "shutdown") action_text="🔌 Shutting down now" ;;
        "hibernate") action_text="💾 Hibernating now" ;;
        *) action_text="⚡ Executing $action now" ;;
    esac
    
    local message
    message="$action_text for $(format_alarm_name "$alarm_name")"
    
    yad_send_notification "$alarm_name" "$message" "0" "true"
    
    # Log action
    logger -t breaktime "Executing: $action for $alarm_name"
    
    # Sound disabled per user preference
}

# Escape &, < and > so user text cannot break yad's Pango markup
notify_escape_markup() {
    printf '%s\n' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

notify_action_label() {
    case "$1" in
        suspend) echo "Suspend" ;;
        shutdown) echo "Shut Down" ;;
        hibernate) echo "Hibernate" ;;
        *) echo "Continue" ;;
    esac
}

format_alarm_name() {
    local alarm_name="$1"
    case "$alarm_name" in
        "bedtime") echo "🌙 Bedtime" ;;
        "lunch_break") echo "🍽️ Lunch Break" ;;
        "afternoon_nap") echo "💤 Afternoon Nap" ;;
        "focus_break") echo "🧠 Focus Break" ;;
        *) echo "$alarm_name" | sed -e 's/_/ /g' -e 's/\b\w/\U&/g' ;;
    esac
}

# Test notification system
notify_test() {
    echo -e "${BOLD}🔔 Testing YAD Notification System${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check YAD (primary)
    if command -v yad >/dev/null 2>&1; then
        echo -e "✅ YAD: ${GREEN}Available${NC}"
        
        # Test YAD notification
        echo -e "📤 Testing YAD notification..."
        yad_send_notification "bedtime" "🧪 Test notification from YAD!" "10" "false"
        
    else
        echo -e "❌ YAD: ${RED}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install yad${NC}"
    fi
    
    # Check Zenity (fallback)
    if command -v zenity >/dev/null 2>&1; then
        echo -e "✅ Zenity: ${GREEN}Available${NC}"
    else
        echo -e "❌ Zenity: ${RED}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install zenity${NC}"
    fi
    
    # Check notify-send (last resort)
    if command -v notify-send >/dev/null 2>&1; then
        echo -e "✅ notify-send: ${GREEN}Available${NC}"
    else
        echo -e "❌ notify-send: ${RED}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install libnotify-bin${NC}"
    fi
    
    # Check for sound system
    if command -v paplay >/dev/null 2>&1; then
        echo -e "✅ paplay: ${GREEN}Available${NC}"
    else
        echo -e "❌ paplay: ${RED}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install pulseaudio-utils${NC}"
    fi
    
    # Check for system sounds
    if [[ -f "/usr/share/sounds/alsa/Front_Right.wav" ]]; then
        echo -e "✅ System sounds: ${GREEN}Available${NC}"
    else
        echo -e "❌ System sounds: ${RED}Not available${NC}"
        echo -e "   Install with: ${BOLD}sudo apt install alsa-utils${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}💡 Tips:${NC}"
    echo "• YAD creates modal dialogs that are hard to miss"
    echo "• Notifications include interactive buttons for final warnings"
    echo "• Sound alerts accompany visual notifications"
    echo -e "• Test with: ${BOLD}breaktime --test-notifications${NC}"
}