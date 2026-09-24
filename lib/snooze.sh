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
    local current_count
    current_count=$(snooze_get_count "$alarm_name")
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
    local current_count max_snoozes
    current_count=$(snooze_get_count "$alarm_name")
    max_snoozes=$(snooze_get_max)
    
    if [[ $current_count -lt $max_snoozes ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Get remaining snoozes for an alarm
snooze_get_remaining() {
    local alarm_name="$1"
    local current_count max_snoozes
    current_count=$(snooze_get_count "$alarm_name")
    max_snoozes=$(snooze_get_max)
    local remaining=$((max_snoozes - current_count))
    
    if [[ $remaining -lt 0 ]]; then
        remaining="0"
    fi

    echo "$remaining"
}

# Remove pending snooze jobs for an alarm (e.g. after it was executed)
snooze_cleanup_jobs() {
    local alarm_name="$1"
    local job_file removed=0

    for job_file in "${SNOOZE_STATE_DIR}/pending/${alarm_name}_"[0-9]*.job; do
        [[ -f "$job_file" ]] || continue
        rm -f "$job_file"
        removed=$((removed + 1))
    done

    if [[ $removed -gt 0 ]]; then
        logger -t breaktime "Removed ${removed} pending snooze job(s) for $alarm_name"
    fi
}

# Clean up old state files (older than 24 hours)
snooze_cleanup() {
    if [[ -d "${SNOOZE_STATE_DIR}" ]]; then
        find "${SNOOZE_STATE_DIR}" -name "*.count" -type f -mtime +1 -delete 2>/dev/null || true
        find "${SNOOZE_STATE_DIR}" -name "suspend_success_*" -type f -mtime +1 -delete 2>/dev/null || true
    fi
}

# File-based snooze scheduling: the daemon polls the pending/ directory

# Schedule a snooze job using simple file system
snooze_schedule_job() {
    local alarm_name="$1"
    local target_timestamp="$2"  # Unix timestamp when to execute
    local action="$3"
    local snooze_count="$4"
    
    local job_file="${SNOOZE_STATE_DIR}/pending/${alarm_name}_${target_timestamp}.job"

    snooze_init
    
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
    local current_time job_file
    current_time=$(date +%s)

    for job_file in "${SNOOZE_STATE_DIR}/pending"/*.job; do
        [[ -f "$job_file" ]] || continue

        local ALARM_NAME="" ACTION="" TARGET_TIME="" SNOOZE_COUNT=""
        # shellcheck source=/dev/null
        source "$job_file" 2>/dev/null || continue
        [[ "$TARGET_TIME" =~ ^[0-9]+$ ]] || continue

        if [[ $current_time -ge $TARGET_TIME ]]; then
            logger -t breaktime "Executing pending snooze job: $ALARM_NAME (count: $SNOOZE_COUNT)"

            # Move to completed first so the job never runs twice
            mv "$job_file" "${SNOOZE_STATE_DIR}/completed/" 2>/dev/null || rm -f "$job_file"

            # Run in the background so a dialog does not block the daemon loop
            snooze_execute_job "$ALARM_NAME" "$ACTION" "$SNOOZE_COUNT" &
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

# Clean up completed jobs older than 24 hours
snooze_cleanup_completed() {
    local completed_dir="${SNOOZE_STATE_DIR}/completed"
    [[ -d "$completed_dir" ]] || return
    
    # Remove files older than 24 hours
    find "$completed_dir" -name "*.job" -mtime +1 -delete 2>/dev/null || true
}