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
    
    # Determine dialog type and styling based on urgency
    local dialog_type="--info"
    local timeout=8
    local buttons=""
    local width=400
    
    if [[ "$is_final" == "true" ]]; then
        dialog_type="--warning"
        timeout=0  # No timeout - persistent dialog
        width=450
        
        # Check snooze availability for final suspend dialog
        local remaining_snoozes=$(snooze_get_remaining "$alarm_name")
        local snooze_duration=$(snooze_get_duration)
        
        if [[ $remaining_snoozes -gt 0 ]]; then
            buttons="--button=Suspend Now:0 --button=Snooze ${snooze_duration}min \\(${remaining_snoozes} left\\):1"
        else
            buttons="--button=Suspend Now:0"
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
    
    # Determine icon based on alarm type
    local icon="dialog-information"
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
    
    # Create YAD command with your preferred styling
    local yad_cmd="yad $dialog_type \
        --text=\"$message\" \
        --title=\"Breaktime - $(format_alarm_name "$alarm_name")\" \
        --borders=20 \
        --timeout=$timeout \
        --center \
        --on-top \
        --no-escape \
        --width=$width \
        --image=\"$icon\" \
        --skip-taskbar \
        --window-icon=\"clock\" \
        --sticky \
        --always-print-result"
    
    # Add close protection for final dialogs - use undecorated instead
    if [[ "$is_final" == "true" ]]; then
        yad_cmd="$yad_cmd --undecorated --fixed"
    fi
    
    yad_cmd="$yad_cmd $buttons"
    
    # Execute with proper environment
    local result=0
    if command -v yad >/dev/null 2>&1; then
        DISPLAY=:1 XDG_CURRENT_DESKTOP=ubuntu:GNOME eval "$yad_cmd" 2>/dev/null || result=$?
        
        # Handle button responses for interactive dialogs
        if [[ -n "$buttons" ]]; then
            case $result in
                0)
                    # Suspend Now button (only for final notifications)
                    if [[ "$is_final" == "true" ]]; then
                        logger -t breaktime "User requested immediate suspend for $alarm_name"
                        local action=$(config_get_alarm_action "$alarm_name")
                        ${SCRIPT_DIR}/breaktime.sh --sleep-now "$alarm_name" "$action" &
                    fi
                    ;;
                1)
                    # Snooze button (only for final notifications with remaining snoozes)
                    if [[ "$is_final" == "true" ]] && [[ $(snooze_is_allowed "$alarm_name") == "true" ]]; then
                        logger -t breaktime "User requested snooze for $alarm_name from suspend dialog"
                        ${SCRIPT_DIR}/breaktime.sh --snooze-suspend "$alarm_name" &
                    else
                        logger -t breaktime "Snooze not allowed for $alarm_name (limit reached)"
                    fi
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