#!/bin/bash

# notify.sh - Notification system for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

notify_send_warning() {
    local alarm_name="$1"
    local message="$2"
    local minutes="$3"
    
    # Determine urgency based on time remaining
    local urgency="normal"
    if [[ $minutes -le 2 ]]; then
        urgency="critical"
    elif [[ $minutes -le 5 ]]; then
        urgency="high"
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
    
    # Send desktop notification
    if command -v notify-send >/dev/null 2>&1; then
        notify-send \
            --urgency="$urgency" \
            --icon="$icon" \
            --expire-time=$((minutes * 30 * 1000)) \
            "Breaktime: $(format_alarm_name "$alarm_name")" \
            "$message"
    fi
    
    # Log notification
    logger -t breaktime "Warning: $alarm_name in $minutes minutes"
    
    # Play sound for critical warnings
    if [[ "$urgency" == "critical" ]] && command -v paplay >/dev/null 2>&1; then
        paplay /usr/share/sounds/alsa/Front_Right.wav 2>/dev/null || true
    fi
}

notify_send_final() {
    local alarm_name="$1"
    local action="$2"
    
    local action_text=""
    case "$action" in
        "suspend") action_text="Suspending" ;;
        "shutdown") action_text="Shutting down" ;;
        "hibernate") action_text="Hibernating" ;;
        *) action_text="Executing action" ;;
    esac
    
    # Determine icon based on action
    local icon="system-shutdown"
    case "$action" in
        "suspend") icon="system-suspend" ;;
        "hibernate") icon="system-hibernate" ;;
    esac
    
    local message="$action_text now for $(format_alarm_name "$alarm_name")"
    
    # Send critical notification
    if command -v notify-send >/dev/null 2>&1; then
        notify-send \
            --urgency="critical" \
            --icon="$icon" \
            --expire-time=5000 \
            "Breaktime: $(format_alarm_name "$alarm_name")" \
            "$message"
    fi
    
    # Log action
    logger -t breaktime "Executing: $action for $alarm_name"
    
    # Play sound
    if command -v paplay >/dev/null 2>&1; then
        paplay /usr/share/sounds/alsa/Front_Left.wav 2>/dev/null || true
    fi
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
    echo -e "${BOLD}🔔 Testing Notification System${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if notify-send is available
    if command -v notify-send >/dev/null 2>&1; then
        echo -e "✅ notify-send: ${GREEN}Available${NC}"
        
        # Send test notification
        notify-send \
            --urgency="normal" \
            --icon="dialog-information" \
            --expire-time=5000 \
            "Breaktime Test" \
            "Notification system is working correctly!"
        
        echo -e "📤 Test notification sent"
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
    echo "• Notifications require a desktop environment"
    echo "• Sounds require PulseAudio or ALSA"
    echo -e "• Test with: ${BOLD}notify-send 'Test' 'Hello World'${NC}"
}