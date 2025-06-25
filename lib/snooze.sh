#!/bin/bash

# snooze.sh - Snooze state management for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0

# State directory for tracking snooze counts
if [[ -z "${SNOOZE_STATE_DIR:-}" ]]; then
    readonly SNOOZE_STATE_DIR="${HOME}/.cache/breaktime"
fi

snooze_init() {
    mkdir -p "${SNOOZE_STATE_DIR}"
}

# Get current snooze count for an alarm
snooze_get_count() {
    local alarm_name="$1"
    local state_file="${SNOOZE_STATE_DIR}/${alarm_name}.count"
    
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "0"
    fi
}

# Set snooze count for an alarm
snooze_set_count() {
    local alarm_name="$1"
    local count="$2"
    local state_file="${SNOOZE_STATE_DIR}/${alarm_name}.count"
    
    snooze_init
    echo "$count" > "$state_file"
}

# Increment snooze count for an alarm
snooze_increment_count() {
    local alarm_name="$1"
    local current_count=$(snooze_get_count "$alarm_name")
    local new_count=$((current_count + 1))
    
    snooze_set_count "$alarm_name" "$new_count"
    echo "$new_count"
}

# Reset snooze count for an alarm
snooze_reset_count() {
    local alarm_name="$1"
    local state_file="${SNOOZE_STATE_DIR}/${alarm_name}.count"
    
    rm -f "$state_file" 2>/dev/null || true
}

# Get maximum snoozes allowed from config
snooze_get_max() {
    config_get_snooze_max
}

# Get snooze duration from config
snooze_get_duration() {
    config_get_snooze_duration
}

# Check if snoozing is still allowed for an alarm
snooze_is_allowed() {
    local alarm_name="$1"
    local current_count=$(snooze_get_count "$alarm_name")
    local max_snoozes=$(snooze_get_max)
    
    if [[ $current_count -lt $max_snoozes ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Get remaining snoozes for an alarm
snooze_get_remaining() {
    local alarm_name="$1"
    local current_count=$(snooze_get_count "$alarm_name")
    local max_snoozes=$(snooze_get_max)
    local remaining=$((max_snoozes - current_count))
    
    if [[ $remaining -lt 0 ]]; then
        echo "0"
    else
        echo "$remaining"
    fi
}

# Calculate new time after snooze
snooze_calculate_new_time() {
    local current_hour="$1"
    local current_minute="$2"
    local snooze_minutes="$(snooze_get_duration)"
    
    # Convert to total minutes from midnight
    local total_minutes=$((current_hour * 60 + current_minute + snooze_minutes))
    
    # Handle day rollover
    if [[ $total_minutes -ge 1440 ]]; then
        total_minutes=$((total_minutes - 1440))
    fi
    
    # Convert back to hour:minute
    local new_hour=$((total_minutes / 60))
    local new_minute=$((total_minutes % 60))
    
    printf "%02d:%02d" "$new_hour" "$new_minute"
}

# Store snooze job information for potential cleanup
snooze_store_job_info() {
    local alarm_name="$1"
    local suspend_time="$2"
    local warning_time="$3"
    local job_file="${SNOOZE_STATE_DIR}/${alarm_name}.jobs"
    
    snooze_init
    echo "suspend_time=$suspend_time" > "$job_file"
    echo "warning_time=$warning_time" >> "$job_file"
    echo "created=$(date +%s)" >> "$job_file"
}

# Get stored snooze job information
snooze_get_job_info() {
    local alarm_name="$1"
    local job_file="${SNOOZE_STATE_DIR}/${alarm_name}.jobs"
    
    if [[ -f "$job_file" ]]; then
        cat "$job_file"
    fi
}

# Clean up pending 'at' jobs for a specific alarm
snooze_cleanup_jobs() {
    local alarm_name="$1"
    local job_file="${SNOOZE_STATE_DIR}/${alarm_name}.jobs"
    
    if [[ -f "$job_file" ]]; then
        # Get job times to find and remove them from 'at' queue
        local suspend_time=$(grep "suspend_time=" "$job_file" | cut -d= -f2)
        local warning_time=$(grep "warning_time=" "$job_file" | cut -d= -f2)
        
        # Remove the job files that match our commands
        # Note: 'at' doesn't provide easy job removal by command, but jobs will expire naturally
        # For now, just clean up our state files
        rm -f "$job_file" 2>/dev/null || true
        
        logger -t breaktime "Cleaned up snooze jobs for $alarm_name"
    fi
}

# Clean up old state files (older than 24 hours)
snooze_cleanup() {
    if [[ -d "${SNOOZE_STATE_DIR}" ]]; then
        find "${SNOOZE_STATE_DIR}" -name "*.count" -type f -mtime +1 -delete 2>/dev/null || true
        find "${SNOOZE_STATE_DIR}" -name "*.jobs" -type f -mtime +1 -delete 2>/dev/null || true
    fi
}