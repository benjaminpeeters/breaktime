#!/bin/bash

# config.sh - Configuration management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# Persistent state/log locations (survive reboots, unlike /tmp)
if [[ -z "${BREAKTIME_STATE_DIR:-}" ]]; then
    readonly BREAKTIME_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/breaktime"
fi
if [[ -z "${DEBUG_LOG_DIR:-}" ]]; then
    readonly DEBUG_LOG_DIR="${BREAKTIME_STATE_DIR}/logs"
fi

# Debug logging is opt-in: BREAKTIME_DEBUG=1 or `debug: true` in the config
debug_enabled() {
    if [[ -n "${BREAKTIME_DEBUG:-}" ]]; then
        [[ "${BREAKTIME_DEBUG}" == "1" || "${BREAKTIME_DEBUG}" == "true" ]]
        return
    fi
    [[ "$(config_get_top_value debug false)" == "true" ]]
}

debug_log() {
    local component="$1"
    local level="$2"
    local message="$3"

    # Warnings and errors always reach syslog; everything else only in debug mode
    if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
        logger -t "breaktime-${component}" "[${level}] ${message}" 2>/dev/null || true
    fi

    debug_enabled || return 0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[${timestamp}] [$$] [${level}] ${message}"

    mkdir -p "$DEBUG_LOG_DIR" 2>/dev/null || true
    echo "$log_entry" >> "${DEBUG_LOG_DIR}/${component}.log" 2>/dev/null || true
    echo "$log_entry" >> "${DEBUG_LOG_DIR}/breaktime-debug.log" 2>/dev/null || true
}

debug_log_environment() {
    local component="$1"
    debug_enabled || return 0
    debug_log "$component" "ENV" "DISPLAY=${DISPLAY:-<unset>} XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>} XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>} USER=${USER:-<unset>} HOME=${HOME:-<unset>}"
    debug_log "$component" "ENV" "PATH=${PATH}"
}

# Function to detect the active display
detect_active_display() {
    local detected_display=""

    # Method 1: Check systemd user environment
    if command -v systemctl >/dev/null 2>&1; then
        detected_display=$(systemctl --user show-environment 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2 || true)
        if [[ -n "$detected_display" ]]; then
            debug_log "config" "INFO" "Detected display from systemd: $detected_display"
            echo "$detected_display"
            return 0
        fi
    fi

    # Method 2: Check active X sessions
    local x_display
    x_display=$(pgrep -a Xorg 2>/dev/null | sed -n 's/.* \(:[0-9]\+\).*/\1/p' | head -1 || true)
    if [[ -n "$x_display" ]]; then
        debug_log "config" "INFO" "Detected display from Xorg process: $x_display"
        echo "$x_display"
        return 0
    fi

    # Method 3: Check /tmp/.X11-unix sockets
    local socket
    for socket in /tmp/.X11-unix/X*; do
        if [[ -S "$socket" ]]; then
            detected_display=":${socket##*/X}"
            debug_log "config" "INFO" "Detected display from X11 socket: $detected_display"
            echo "$detected_display"
            return 0
        fi
    done

    # Method 4: Try common defaults
    local try_display
    for try_display in :0 :1; do
        if DISPLAY=$try_display xset q &>/dev/null; then
            debug_log "config" "INFO" "Detected working display by testing: $try_display"
            echo "$try_display"
            return 0
        fi
    done

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

    local editor="${EDITOR:-nano}"

    echo -e "${BOLD}📝 Opening configuration file...${NC}"
    echo -e "File: ${BLUE}${CONFIG_FILE}${NC}"
    echo ""

    "${editor}" "${CONFIG_FILE}"

    if config_validate; then
        echo -e "${GREEN}✅ Configuration is valid${NC}"
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

    if ! config_yaml_syntax_ok; then
        echo "Error: Invalid YAML syntax in configuration file" >&2
        return 1
    fi

    if ! grep -q "^enabled:" "${CONFIG_FILE}"; then
        echo "Error: Missing required key 'enabled' in configuration" >&2
        return 1
    fi

    if ! grep -q "^alarms:" "${CONFIG_FILE}"; then
        echo "Error: Missing required key 'alarms' in configuration" >&2
        return 1
    fi

    local errors=0 alarm day_type value
    while read -r alarm; do
        [[ -n "$alarm" ]] || continue
        for day_type in weekdays weekends; do
            value=$(config_get_alarm_time "$alarm" "$day_type")
            if [[ -n "$value" ]] && ! config_is_time "$value"; then
                echo "Error: alarms.${alarm}.${day_type}: invalid time '${value}' (expected HH:MM)" >&2
                errors=$((errors + 1))
            fi
        done
        value=$(config_get_alarm_action "$alarm")
        if [[ ! "$value" =~ ^(suspend|shutdown|hibernate)$ ]]; then
            echo "Error: alarms.${alarm}.action: unknown action '${value}'" >&2
            errors=$((errors + 1))
        fi
    done < <(config_get_alarms)

    local day
    for day in $(config_get_workdays); do
        if ! config_day_index "$day" >/dev/null; then
            echo "Error: schedule.workdays: unknown day '${day}' (use mon, tue, ...)" >&2
            errors=$((errors + 1))
        fi
    done

    value=$(config_get_schedule_value mode evening)
    if [[ ! "$value" =~ ^(evening|calendar)$ ]]; then
        echo "Error: schedule.mode: must be 'evening' or 'calendar', got '${value}'" >&2
        errors=$((errors + 1))
    fi
    for day_type in day_starts_at evening_starts_at; do
        value=$(config_get_schedule_value "$day_type" "00:00")
        if ! config_is_time "$value"; then
            echo "Error: schedule.${day_type}: invalid time '${value}' (expected HH:MM)" >&2
            errors=$((errors + 1))
        fi
    done

    [[ $errors -eq 0 ]]
}

# Full YAML syntax check with whatever parser is available (none: skip).
# Note: `yq` may be mikefarah's Go version (`yq eval`) or the Python jq
# wrapper (`yq .`), which is what Ubuntu's apt package installs.
config_yaml_syntax_ok() {
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "${CONFIG_FILE}" 2>/dev/null
    elif command -v yq >/dev/null 2>&1; then
        if yq --version 2>&1 | grep -q 'mikefarah'; then
            yq eval '.' "${CONFIG_FILE}" >/dev/null 2>&1
        else
            yq '.' "${CONFIG_FILE}" >/dev/null 2>&1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Low-level YAML helpers (a small, indentation-based subset of YAML)
# ---------------------------------------------------------------------------

# Strip a trailing comment, surrounding quotes and whitespace from a raw value
config_clean_value() {
    local value="$1"
    # Only strip comments that are outside quotes: handle quoted values first
    if [[ "$value" =~ ^[[:space:]]*\"([^\"]*)\" ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[[:space:]]*\'([^\']*)\' ]]; then
        value="${BASH_REMATCH[1]}"
    else
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    echo "$value"
}

config_is_time() {
    [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# Print the lines of a top-level section (without its header line)
config_section() {
    local section="$1"
    [[ -f "${CONFIG_FILE}" ]] || return 0
    awk -v key="$section" '
        $0 ~ "^" key ":[[:space:]]*(#.*)?$" { inside = 1; next }
        inside && /^[^[:space:]#]/ { exit }
        inside { print }
    ' "${CONFIG_FILE}"
}

# Value of a top-level scalar key, e.g. `enabled: true`
config_get_top_value() {
    local key="$1"
    local default="${2:-}"
    local raw=""
    if [[ -f "${CONFIG_FILE}" ]]; then
        raw=$(sed -n "s/^${key}:[[:space:]]*//p" "${CONFIG_FILE}" | head -1)
    fi
    raw=$(config_clean_value "$raw")
    echo "${raw:-$default}"
}

# Value of a key inside a top-level section, e.g. `snooze: max_snoozes: 3`
config_get_section_value() {
    local section="$1"
    local key="$2"
    local default="${3:-}"
    local raw
    raw=$(config_section "$section" | sed -n "s/^[[:space:]]\{1,\}${key}:[[:space:]]*//p" | head -1)
    raw=$(config_clean_value "$raw")
    if [[ -z "$raw" || "$raw" == "null" ]]; then
        raw="$default"
    fi
    echo "$raw"
}

# Print the body of one alarm block (lines between `  name:` and the next `  key:`)
config_alarm_block() {
    local alarm_name="$1"
    config_section alarms | awk -v name="$alarm_name" '
        $0 ~ "^  " name ":[[:space:]]*(#.*)?$" { inside = 1; next }
        inside && /^  [^[:space:]#]/ { exit }
        inside { print }
    '
}

# Value of a direct (4-space) key of an alarm
config_get_alarm_value() {
    local alarm_name="$1"
    local key="$2"
    local default="${3:-}"
    local raw
    raw=$(config_alarm_block "$alarm_name" | sed -n "s/^    ${key}:[[:space:]]*//p" | head -1)
    raw=$(config_clean_value "$raw")
    if [[ -z "$raw" || "$raw" == "null" ]]; then
        raw="$default"
    fi
    echo "$raw"
}

# ---------------------------------------------------------------------------
# Public getters
# ---------------------------------------------------------------------------

config_get_enabled() {
    config_get_top_value enabled false
}

config_get_alarms() {
    config_section alarms | sed -n 's/^  \([a-zA-Z_][a-zA-Z0-9_]*\):.*/\1/p'
}

config_get_alarm_enabled() {
    config_get_alarm_value "$1" enabled false
}

# day_type: weekdays or weekends. Prints nothing when unset/null.
config_get_alarm_time() {
    config_get_alarm_value "$1" "$2" ""
}

config_get_alarm_action() {
    local default_action
    default_action=$(config_get_top_value default_action suspend)
    config_get_alarm_value "$1" action "$default_action"
}

# Print the warning lead times (minutes) of an alarm, one per line
config_get_alarm_warnings() {
    local alarm_name="$1"
    config_alarm_block "$alarm_name" | awk '
        /^    warnings:/ { inside = 1; next }
        inside && /^    [^[:space:]]/ { exit }
        inside && match($0, /^[[:space:]]*-[[:space:]]*minutes:[[:space:]]*/) {
            value = substr($0, RLENGTH + 1)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/["\047[:space:]]/, "", value)
            if (value != "") print value
        }
    '
}

config_get_warning_message() {
    local alarm_name="$1"
    local minutes="$2"
    local raw
    raw=$(config_alarm_block "$alarm_name" | awk -v want="$minutes" '
        /^    warnings:/ { inside = 1; next }
        inside && /^    [^[:space:]]/ { exit }
        inside && match($0, /^[[:space:]]*-[[:space:]]*minutes:[[:space:]]*/) {
            value = substr($0, RLENGTH + 1)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/["\047[:space:]]/, "", value)
            current = value
            next
        }
        inside && current == want && match($0, /^[[:space:]]*message:[[:space:]]*/) {
            print substr($0, RLENGTH + 1)
            exit
        }
    ')
    local message
    message=$(config_clean_value "$raw")
    if [[ -z "$message" ]]; then
        message="System will $(config_get_alarm_action "$alarm_name") in ${minutes} minutes"
    fi
    echo "$message"
}

config_get_snooze_max() {
    config_get_section_value snooze max_snoozes 3
}

config_get_snooze_duration() {
    config_get_section_value snooze snooze_duration 2
}

config_get_desktop_notifications() {
    config_get_section_value notifications desktop_notifications true
}

# ---------------------------------------------------------------------------
# Schedule / workdays
# ---------------------------------------------------------------------------

config_get_schedule_value() {
    config_get_section_value schedule "$1" "${2:-}"
}

# Map a day name to cron's day-of-week number (0 = Sunday)
config_day_index() {
    case "${1,,}" in
        sun|sunday) echo 0 ;;
        mon|monday) echo 1 ;;
        tue|tuesday) echo 2 ;;
        wed|wednesday) echo 3 ;;
        thu|thursday) echo 4 ;;
        fri|friday) echo 5 ;;
        sat|saturday) echo 6 ;;
        *) return 1 ;;
    esac
}

# Print the configured workdays (names), one per line.
# Accepts both `workdays: [mon, tue]` and a `- mon` block list.
config_get_workdays() {
    local block inline
    block=$(config_section schedule)
    inline=$(echo "$block" | sed -n 's/^[[:space:]]\{1,\}workdays:[[:space:]]*//p' | head -1)
    inline="${inline%%#*}"

    local days=""
    if [[ "$inline" == *"["* ]]; then
        days=$(echo "$inline" | tr -d '[]"'\''' | tr ',' '\n')
    elif echo "$block" | grep -q '^[[:space:]]\{1,\}workdays:'; then
        days=$(echo "$block" | awk '
            /^[[:space:]]+workdays:/ { inside = 1; next }
            inside && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/["\047]/, ""); print; next }
            inside && /[^[:space:]]/ { exit }
        ')
    fi

    days=$(echo "$days" | tr -d ' \t' | sed '/^$/d')
    if [[ -z "$days" ]]; then
        days=$'mon\ntue\nwed\nthu\nfri'
    fi
    echo "$days"
}

# Print the cron day-of-week numbers of the workdays, space separated
config_get_workday_indices() {
    local day indices=()
    while read -r day; do
        [[ -n "$day" ]] || continue
        indices+=("$(config_day_index "$day" || true)")
    done < <(config_get_workdays)
    echo "${indices[*]}"
}
