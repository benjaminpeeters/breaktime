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
    mkdir -p "${SNOOZE_STATE_DIR}/pending"
    mkdir -p "${SNOOZE_STATE_DIR}/completed"
}

# Get current snooze count for an alarm
snooze_get_count() {
    local alarm_name="$1"
    local state_file="${SNOOZE_STATE_DIR}/${alarm_name}.count"
    
    local count
    if [[ -f "$state_file" ]]; then
        count=$(cat "$state_file")
    else
        count="0"
    fi
    
    logger -t breaktime "DEBUG: snooze_get_count($alarm_name) = $count"
    echo "$count"
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
    
    logger -t breaktime "DEBUG: snooze_increment_count($alarm_name) from $current_count to $new_count"
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
        remaining="0"
    fi
    
    logger -t breaktime "DEBUG: snooze_get_remaining($alarm_name) = $remaining (current: $current_count, max: $max_snoozes)"
    echo "$remaining"
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

# NEW FILE-BASED SNOOZE SYSTEM (replaces fragile 'at' commands)

# Schedule a snooze job using simple file system
snooze_schedule_job() {
    local alarm_name="$1"
    local target_timestamp="$2"  # Unix timestamp when to execute
    local action="$3"
    local snooze_count="$4"
    
    local job_file="${SNOOZE_STATE_DIR}/pending/${alarm_name}_${target_timestamp}.job"
    
    # Create job file with all needed info
    cat > "$job_file" <<EOF
ALARM_NAME="${alarm_name}"
TARGET_TIME="${target_timestamp}"
ACTION="${action}"
SNOOZE_COUNT="${snooze_count}"
CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    logger -t breaktime "Scheduled snooze job: $job_file (execute at $(date -d "@$target_timestamp" '+%H:%M:%S'))"
    echo "$job_file"
}

# Check for pending snooze jobs and execute ready ones
snooze_check_pending() {
    local current_time=$(date +%s)
    
    # Check all pending job files
    for job_file in "${SNOOZE_STATE_DIR}/pending"/*.job; do
        [[ -f "$job_file" ]] || continue
        
        # Read job details
        local alarm_name action target_time snooze_count
        source "$job_file" 2>/dev/null || continue
        
        alarm_name="$ALARM_NAME"
        action="$ACTION"
        target_time="$TARGET_TIME"
        snooze_count="$SNOOZE_COUNT"
        
        # Check if it's time to execute
        if [[ $current_time -ge $target_time ]]; then
            logger -t breaktime "Executing pending snooze job: $alarm_name (count: $snooze_count)"
            
            # Execute the job
            snooze_execute_job "$alarm_name" "$action" "$snooze_count"
            
            # Move to completed
            local completed_file="${SNOOZE_STATE_DIR}/completed/$(basename "$job_file")"
            mv "$job_file" "$completed_file" 2>/dev/null || rm -f "$job_file"
        fi
    done
}

# Execute a snooze job (show suspend dialog)
snooze_execute_job() {
    local alarm_name="$1"
    local action="$2"
    local snooze_count="$3"
    
    logger -t breaktime "Executing snooze job: $alarm_name with action $action (snooze count: $snooze_count)"
    
    # Set the current snooze count before showing dialog
    snooze_set_count "$alarm_name" "$snooze_count"
    
    # Execute the final notification dialog (this handles user interaction)
    notify_send_final "$alarm_name" "$action"
}

# Clean up old completed jobs (keep last 10)
snooze_cleanup_completed() {
    local completed_dir="${SNOOZE_STATE_DIR}/completed"
    [[ -d "$completed_dir" ]] || return
    
    # Remove files older than 24 hours
    find "$completed_dir" -name "*.job" -mtime +1 -delete 2>/dev/null || true
}