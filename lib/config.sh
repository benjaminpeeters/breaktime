#!/bin/bash

# config.sh - Configuration management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Debug logging infrastructure
if [[ -z "${DEBUG_LOG_DIR:-}" ]]; then
    readonly DEBUG_LOG_DIR="/tmp/breaktime/logs"
fi
if [[ -z "${DEBUG_ENABLED:-}" ]]; then
    readonly DEBUG_ENABLED="true"
fi

debug_log() {
    local component="$1"
    local level="$2"
    local message="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    
    if [[ "$DEBUG_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Ensure log directory exists
    mkdir -p "$DEBUG_LOG_DIR" 2>/dev/null || true
    
    # Create component-specific log file
    local log_file="${DEBUG_LOG_DIR}/${component}.log"
    
    # Format: [TIMESTAMP] [PID] [LEVEL] MESSAGE
    local log_entry="[${timestamp}] [${pid}] [${level}] ${message}"
    
    # Write to both file and syslog
    echo "$log_entry" >> "$log_file" 2>/dev/null || true
    logger -t "breaktime-${component}" "$log_entry" 2>/dev/null || true
    
    # Also write to main debug log
    echo "$log_entry" >> "${DEBUG_LOG_DIR}/breaktime-debug.log" 2>/dev/null || true
}

debug_log_environment() {
    local component="$1"
    debug_log "$component" "ENV" "=== ENVIRONMENT DUMP ==="
    debug_log "$component" "ENV" "DISPLAY=${DISPLAY:-<unset>}"
    debug_log "$component" "ENV" "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}"
    debug_log "$component" "ENV" "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}"
    debug_log "$component" "ENV" "PATH=${PATH}"
    debug_log "$component" "ENV" "USER=${USER:-<unset>}"
    debug_log "$component" "ENV" "HOME=${HOME:-<unset>}"
    debug_log "$component" "ENV" "PWD=${PWD:-<unset>}"
    debug_log "$component" "ENV" "=== END ENVIRONMENT ==="
}

# Function to detect the active display
detect_active_display() {
    local detected_display=""
    
    # Method 1: Check systemd user environment
    if command -v systemctl >/dev/null 2>&1; then
        detected_display=$(systemctl --user show-environment | grep ^DISPLAY= | cut -d= -f2)
        if [[ -n "$detected_display" ]]; then
            debug_log "config" "INFO" "Detected display from systemd: $detected_display"
            echo "$detected_display"
            return 0
        fi
    fi
    
    # Method 2: Check active X sessions
    local x_displays=$(ps aux | grep -E "Xorg.*vt" | grep -v grep | sed -n 's/.*:\([0-9]\+\).*/:\1/p' | head -1)
    if [[ -n "$x_displays" ]]; then
        debug_log "config" "INFO" "Detected display from Xorg process: $x_displays"
        echo "$x_displays"
        return 0
    fi
    
    # Method 3: Check /tmp/.X11-unix sockets
    if [[ -d /tmp/.X11-unix ]]; then
        for socket in /tmp/.X11-unix/X*; do
            if [[ -S "$socket" ]]; then
                local display_num=$(basename "$socket" | sed 's/X//')
                detected_display=":${display_num}"
                debug_log "config" "INFO" "Detected display from X11 socket: $detected_display"
                echo "$detected_display"
                return 0
            fi
        done
    fi
    
    # Method 4: Try common defaults
    for try_display in :0 :1; do
        if DISPLAY=$try_display xset q &>/dev/null; then
            debug_log "config" "INFO" "Detected working display by testing: $try_display"
            echo "$try_display"
            return 0
        fi
    done
    
    # Fallback to :0
    debug_log "config" "WARN" "Could not detect display, using default :0"
    echo ":0"
}

config_edit() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo -e "${YELLOW}⚠️  No configuration found. Creating from template...${NC}"
        mkdir -p "${CONFIG_DIR}"
        cp "${DEFAULT_CONFIG}" "${CONFIG_FILE}"
        echo -e "✅ Created: ${CONFIG_FILE}"
    fi
    
    # Use preferred editor or fallback to nano
    local editor="${EDITOR:-nano}"
    
    echo -e "${BOLD}📝 Opening configuration file...${NC}"
    echo -e "File: ${BLUE}${CONFIG_FILE}${NC}"
    echo ""
    
    # Open editor
    "${editor}" "${CONFIG_FILE}"
    
    # Validate configuration after editing
    if config_validate; then
        echo -e "${GREEN}✅ Configuration is valid${NC}"
        # Update cron jobs based on new config
        cron_update_from_config
    else
        echo -e "${RED}❌ Configuration has errors${NC}"
        read -p "Edit again? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            config_edit
        fi
    fi
}

config_validate() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "Error: Configuration file not found: ${CONFIG_FILE}" >&2
        return 1
    fi
    
    # Basic YAML syntax check (if yq is available)
    if command -v yq >/dev/null 2>&1; then
        if ! yq eval '.' "${CONFIG_FILE}" >/dev/null 2>&1; then
            echo "Error: Invalid YAML syntax in configuration file" >&2
            return 1
        fi
    fi
    
    # Check for required top-level keys
    if ! grep -q "^enabled:" "${CONFIG_FILE}"; then
        echo "Error: Missing required key 'enabled' in configuration" >&2
        return 1
    fi
    
    if ! grep -q "^alarms:" "${CONFIG_FILE}"; then
        echo "Error: Missing required key 'alarms' in configuration" >&2
        return 1
    fi
    
    return 0
}

config_get_enabled() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "false"
        return
    fi
    
    # Extract enabled value using basic bash parsing
    local enabled=$(grep "^enabled:" "${CONFIG_FILE}" | sed 's/enabled:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
    echo "${enabled:-false}"
}

config_get_alarms() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi
    
    # Extract alarm names - find lines that are directly under alarms with 2-space indent
    sed -n '/^alarms:/,/^[a-zA-Z]/p' "${CONFIG_FILE}" | \
    grep "^  [a-zA-Z_][a-zA-Z0-9_]*:" | \
    sed 's/^  //' | \
    sed 's/:.*$//'
}

config_get_alarm_enabled() {
    local alarm_name="$1"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "false"
        return
    fi
    
    # Extract enabled value for specific alarm
    local in_alarm=false
    local enabled="false"
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*enabled:[[:space:]]*(.*) ]]; then
            enabled=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            break
        fi
    done < "${CONFIG_FILE}"
    
    echo "${enabled}"
}

config_get_alarm_time() {
    local alarm_name="$1"
    local day_type="$2"  # weekdays or weekends
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi
    
    # Extract time value for specific alarm and day type
    local in_alarm=false
    local time=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*${day_type}:[[:space:]]*(.*) ]]; then
            time=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | sed 's/#.*//' | xargs)
            if [[ "$time" == "null" ]]; then
                time=""
            fi
            break
        fi
    done < "${CONFIG_FILE}"
    
    echo "${time}"
}

config_get_alarm_action() {
    local alarm_name="$1"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "suspend"
        return
    fi
    
    # Extract action value for specific alarm
    local in_alarm=false
    local action="suspend"
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*action:[[:space:]]*(.*) ]]; then
            action=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            break
        fi
    done < "${CONFIG_FILE}"
    
    echo "${action:-suspend}"
}

config_get_alarm_warnings() {
    local alarm_name="$1"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi
    
    # Extract warning configurations for specific alarm
    local in_alarm=false
    local in_warnings=false
    local warnings=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            # Found another alarm at same level - end of current alarm
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*warnings:[[:space:]]*$ ]]; then
            in_warnings=true
            continue
        elif [[ "$in_warnings" == true ]] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*minutes:[[:space:]]*(.*) ]]; then
            local minutes=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            warnings+=("$minutes")
        # Skip message lines and other warning details
        fi
    done < "${CONFIG_FILE}"
    
    # Output warnings separated by spaces
    printf '%s\n' "${warnings[@]}"
}

config_get_warning_message() {
    local alarm_name="$1"
    local minutes="$2"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "System will suspend in ${minutes} minutes"
        return
    fi
    
    # Extract specific warning message
    local in_alarm=false
    local in_warnings=false
    local in_warning_block=false
    local current_minutes=""
    local message=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*warnings:[[:space:]]*$ ]]; then
            in_warnings=true
            continue
        elif [[ "$in_warnings" == true ]] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*minutes:[[:space:]]*(.*) ]]; then
            current_minutes=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            in_warning_block=true
            continue
        elif [[ "$in_warning_block" == true ]] && [[ "$current_minutes" == "$minutes" ]] && [[ "$line" =~ ^[[:space:]]*message:[[:space:]]*(.*) ]]; then
            message=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*"//' | sed 's/"[[:space:]]*$//')
            break
        elif [[ "$in_warning_block" == true ]] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*minutes: ]]; then
            in_warning_block=false
            current_minutes=""
        fi
    done < "${CONFIG_FILE}"
    
    # Default message if not found
    if [[ -z "$message" ]]; then
        message="System will suspend in ${minutes} minutes"
    fi
    
    echo "$message"
}

config_get_snooze_max() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "3"  # default
        return
    fi
    
    local max_snoozes=$(grep "^[[:space:]]*max_snoozes:" "${CONFIG_FILE}" | sed 's/.*max_snoozes:[[:space:]]*//' | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs)
    echo "${max_snoozes:-3}"
}

config_get_snooze_duration() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "2"  # default
        return
    fi
    
    local duration=$(grep "^[[:space:]]*snooze_duration:" "${CONFIG_FILE}" | sed 's/.*snooze_duration:[[:space:]]*//' | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs)
    echo "${duration:-2}"
}

config_get_desktop_notifications() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "true"  # default
        return
    fi
    
    # Extract desktop_notifications setting from notifications section
    local in_notifications=false
    local desktop_notifications="true"  # Default to true
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*notifications:[[:space:]]*$ ]]; then
            in_notifications=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_notifications" == true ]]; then
            # We've hit another top-level section
            break
        elif [[ "$in_notifications" == true ]] && [[ "$line" =~ ^[[:space:]]*desktop_notifications:[[:space:]]*(.*) ]]; then
            desktop_notifications=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            break
        fi
    done < "${CONFIG_FILE}"
    
    echo "${desktop_notifications}"
}