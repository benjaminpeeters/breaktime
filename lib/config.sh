#!/bin/bash

# config.sh - Configuration management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

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
    echo "File: ${BLUE}${CONFIG_FILE}${NC}"
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
    
    # Extract alarm names using basic bash parsing
    # This is a simplified parser - assumes standard YAML formatting
    sed -n '/^alarms:/,/^[[:alpha:]]/p' "${CONFIG_FILE}" | \
        grep "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:" | \
        sed 's/^[[:space:]]*//' | \
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
        if [[ "$line" =~ ^[[:space:]]*${alarm_name}:[[:space:]]*$ ]]; then
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
        if [[ "$line" =~ ^[[:space:]]*${alarm_name}:[[:space:]]*$ ]]; then
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
        if [[ "$line" =~ ^[[:space:]]*${alarm_name}:[[:space:]]*$ ]]; then
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
        if [[ "$line" =~ ^[[:space:]]*${alarm_name}:[[:space:]]*$ ]]; then
            in_alarm=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]] && [[ "$in_alarm" == true ]]; then
            break
        elif [[ "$in_alarm" == true ]] && [[ "$line" =~ ^[[:space:]]*warnings:[[:space:]]*$ ]]; then
            in_warnings=true
            continue
        elif [[ "$in_warnings" == true ]] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*minutes:[[:space:]]*(.*) ]]; then
            local minutes=$(echo "${BASH_REMATCH[1]}" | tr -d '"' | tr -d "'" | xargs)
            warnings+=("$minutes")
        elif [[ "$in_warnings" == true ]] && [[ "$line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
            break
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
        if [[ "$line" =~ ^[[:space:]]*${alarm_name}:[[:space:]]*$ ]]; then
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