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
    
    # Check if a recent suspend success occurred for this alarm (within last 2 minutes)
    if [[ "$is_final" == "true" ]]; then
        local recent_success=$(find "${SNOOZE_STATE_DIR}" -name "suspend_success_${alarm_name}_*" -newermt "2 minutes ago" 2>/dev/null | head -1)
        if [[ -n "$recent_success" ]]; then
            logger -t breaktime "Skipping dialog for $alarm_name - recent suspend success found: $(basename "$recent_success")"
            return 0
        fi
    fi
    
    # Determine dialog type and styling based on urgency
    local dialog_type="--info"
    local timeout=8
    local buttons=""
    local width=400
    
    if [[ "$is_final" == "true" ]]; then
        dialog_type="--warning"
        timeout=0  # No timeout - persistent dialog
        width=660
        height=280
        
        # Check snooze availability for final suspend dialog
        local remaining_snoozes=$(snooze_get_remaining "$alarm_name")
        local current_count=$(snooze_get_count "$alarm_name")
        local max_snoozes=$(snooze_get_max)
        local snooze_duration=$(snooze_get_duration)
        
        if [[ $remaining_snoozes -gt 0 ]]; then
            # Show both remaining and used counts for clarity
            buttons="--button=\"Suspend Now\":0 --button=\"Snooze ${snooze_duration}min (${remaining_snoozes}/${max_snoozes} left)\":1"
            # Add snooze info to message with larger font using simple Pango markup
            message="<span size='large'>${message}\n\n📊 Snooze status: Used ${current_count}/${max_snoozes}</span>"
        else
            buttons="--button=\"Suspend Now\":0"
            # Show that snooze limit is reached with larger font
            message="<span size='large'>${message}\n\n🚫 Snooze limit reached (${max_snoozes}/${max_snoozes})</span>"
        fi
    elif [[ $minutes -le 2 ]]; then
        dialog_type="--info"
        timeout=12
        width=450
        buttons="--button=OK:0"
    elif [[ $minutes -le 5 ]]; then
        dialog_type="--info"
        timeout=10
        buttons="--button=OK:0"
    fi
    
    # Determine icon based on alarm type (empty for final dialogs to remove default icon)
    local icon="dialog-information"
    if [[ "$is_final" == "true" ]]; then
        icon=""  # No icon for suspend dialogs
    else
        case "$alarm_name" in
            "bedtime")
                icon="night-light"
                ;;
            "lunch_break")
                icon="applications-dining"
                ;;
            "afternoon_nap"|"focus_break")
                icon="appointment-soon"
                ;;
        esac
    fi
    
    # Create YAD command with improved styling
    local yad_cmd="yad $dialog_type \
        --text=\"$message\" \
        --title=\"Breaktime - $(format_alarm_name "$alarm_name")\" \
        --borders=30 \
        --timeout=$timeout \
        --center \
        --on-top \
        --no-escape \
        --width=$width \
        --skip-taskbar \
        --window-icon=\"clock\" \
        --sticky \
        --always-print-result"
    
    # Add icon only if not empty (for final dialogs we skip the icon)
    if [[ -n "$icon" ]]; then
        yad_cmd="$yad_cmd --image=\"$icon\""
    fi
    
    # Add close protection and styling for final dialogs
    if [[ "$is_final" == "true" ]]; then
        # Use aggressive protection - remove decorations and escape handling
        yad_cmd="$yad_cmd --undecorated --fixed --modal --keep-above --skip-pager --no-escape"
        # Override the --no-escape that was set earlier for final dialogs
        yad_cmd=$(echo "$yad_cmd" | sed 's/--no-escape --/--/' | sed 's/--no-escape//')
        # Add sizing and styling for final dialogs
        yad_cmd="$yad_cmd --no-escape --height=$height --text-align=center"
    fi
    
    yad_cmd="$yad_cmd $buttons"
    
    # Execute with proper environment
    local result=0
    if command -v yad >/dev/null 2>&1; then
        # For final dialogs, keep showing until user makes a choice
        if [[ "$is_final" == "true" ]]; then
            local made_choice=false
            while [[ "$made_choice" == "false" ]]; do
                DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME eval "$yad_cmd" 2>/dev/null || result=$?
                
                logger -t breaktime "DEBUG: YAD dialog result code: $result for $alarm_name"
                
                # Check if user made a valid choice (clicked a button)
                case $result in
                    0)
                        # Suspend Now button
                        logger -t breaktime "User clicked Suspend Now for $alarm_name"
                        made_choice=true
                        # Handle suspend immediately
                        local action=$(config_get_alarm_action "$alarm_name")
                        logger -t breaktime "Executing system action: $action for $alarm_name"
                        # Reset snooze count and clean up jobs
                        snooze_reset_count "$alarm_name"
                        snooze_cleanup_jobs "$alarm_name"
                        
                        # Create success marker to prevent dialog reshowing after resume
                        local success_file="${SNOOZE_STATE_DIR}/suspend_success_${alarm_name}_$(date +%s)"
                        echo "$(date): Successfully suspended for $alarm_name" > "$success_file"
                        
                        # Execute the system action directly
                        cron_execute_system_action "$action"
                        # Exit the script entirely after suspend to prevent dialog loop
                        logger -t breaktime "System action completed, exiting notification process"
                        exit 0
                        ;;
                    1)
                        # Snooze button
                        logger -t breaktime "User clicked Snooze for $alarm_name"
                        made_choice=true
                        # Handle snooze immediately
                        if [[ $(snooze_is_allowed "$alarm_name") == "true" ]]; then
                            logger -t breaktime "Processing snooze request for $alarm_name"
                            ${SCRIPT_DIR}/breaktime.sh --snooze-suspend "$alarm_name"
                        else
                            logger -t breaktime "Snooze not allowed for $alarm_name"
                        fi
                        ;;
                    *)
                        # Dialog was closed improperly (Alt+F4, etc.) - show it again
                        logger -t breaktime "Suspend dialog dismissed improperly for $alarm_name (exit code: $result), reshowing..."
                        sleep 1  # Brief pause before reshowing
                        ;;
                esac
            done
        else
            # Regular warnings - show once
            DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME eval "$yad_cmd" 2>/dev/null || result=$?
        fi
        
        # Handle button responses for non-final dialogs (warnings)
        if [[ -n "$buttons" ]] && [[ "$is_final" != "true" ]]; then
            case $result in
                0)
                    # OK button for warnings
                    logger -t breaktime "User acknowledged warning for $alarm_name"
                    ;;
            esac
        fi
    else
        # Fallback to zenity or notify-send
        fallback_notification "$alarm_name" "$message" "$minutes" "$is_final"
    fi
    
    # Log notification
    logger -t breaktime "YAD notification: $alarm_name in $minutes minutes"
    
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
        
        DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME zenity $dialog_type \
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
        
        DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME notify-send \
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
    
    local message="$action_text for $(format_alarm_name "$alarm_name")"
    
    yad_send_notification "$alarm_name" "$message" "0" "true"
    
    # Log action
    logger -t breaktime "Executing: $action for $alarm_name"
    
    # Sound disabled per user preference
}

format_alarm_name() {
    local alarm_name="$1"
    case "$alarm_name" in
        "bedtime") echo "🌙 Bedtime" ;;
        "lunch_break") echo "🍽️ Lunch Break" ;;
        "afternoon_nap") echo "💤 Afternoon Nap" ;;
        "focus_break") echo "🧠 Focus Break" ;;
        *) echo "$(echo "$alarm_name" | sed 's/_/ /g' | sed 's/\b\w/\U&/g')" ;;
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