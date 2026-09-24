#!/bin/bash

# run.sh - Test suite for breaktime
# Copyright (C) 2025 Benjamin Peeters
# Licensed under AGPL-3.0
#
# Usage: tests/run.sh [name-filter]
#
# Every test runs in a subshell with a throw-away HOME and stub versions of
# crontab, systemctl and logger, so nothing touches the real system.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

# ---------------------------------------------------------------------------
# Test environment
# ---------------------------------------------------------------------------

make_stubs() {
    local bin="$1"
    mkdir -p "$bin"

    # crontab: stores the table in $HOME/crontab.txt
    cat > "$bin/crontab" <<'EOF'
#!/bin/bash
file="$HOME/crontab.txt"
case "$1" in
    -l) [[ -s "$file" ]] && cat "$file" || { echo "no crontab for $USER" >&2; exit 1; } ;;
    -)  # read everything first, like the real crontab, then write
        table=$(cat)
        if [[ -n "$table" ]]; then printf '%s\n' "$table" > "$file"; else : > "$file"; fi ;;
    *) echo "crontab stub: unsupported $*" >&2; exit 2 ;;
esac
EOF
    # systemctl: records every call, reports the service as inactive
    cat > "$bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.log"
[[ "$*" == *is-active* ]] && exit 3
exit 0
EOF
    # logger: appends to a file instead of syslog
    cat > "$bin/logger" <<'EOF'
#!/bin/bash
[[ "$1" == "-t" ]] && shift 2
if [[ $# -gt 0 ]]; then echo "$*"; else cat; fi >> "$HOME/syslog.txt"
EOF
    # yad: records its arguments (one per line) in $HOME/yad/<n>.args and
    # exits with the next code from $HOME/yad_exit_codes (default 0 = first button)
    cat > "$bin/yad" <<'EOF'
#!/bin/bash
dir="$HOME/yad"
mkdir -p "$dir"
n=$(( $(find "$dir" -name '*.args' | wc -l) + 1 ))
printf '%s\n' "$@" > "$dir/$n.args"
code=0
if [[ -s "$HOME/yad_exit_codes" ]]; then
    code=$(head -1 "$HOME/yad_exit_codes")
    sed -i 1d "$HOME/yad_exit_codes"
fi
exit "$code"
EOF
    # notify-send: records its arguments
    cat > "$bin/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$HOME/notify-send.log"
EOF
    chmod +x "$bin"/*
}

# Prepare a fresh HOME; the config is read from stdin (or the default template)
new_home() {
    local home="$TMP_ROOT/$1"
    rm -rf "$home"
    mkdir -p "$home/.config/breaktime" "$home/bin"
    make_stubs "$home/bin"
    echo "$home"
}

# Load breaktime's functions into the current (sub)shell
load_breaktime() {
    # shellcheck source=../breaktime.sh
    source "$REPO_DIR/breaktime.sh"
}

# Run a test body in an isolated subshell. Config comes from stdin.
# Feed it with `< <(fixture)` rather than a pipe, so the counters survive.
run_test() {
    local name="$1"
    local body="$2"

    if [[ -n "$FILTER" ]] && [[ "$name" != *"$FILTER"* ]]; then
        return
    fi

    local home config output status
    home=$(new_home "$name")
    config=$(cat)
    if [[ -n "$config" ]]; then
        printf '%s\n' "$config" > "$home/.config/breaktime/config.yaml"
    fi

    output=$(
        export HOME="$home"
        export PATH="$home/bin:$PATH"
        export USER="${USER:-tester}"
        unset DISPLAY BREAKTIME_DEBUG XDG_STATE_HOME
        cd "$home" || exit 1
        load_breaktime
        set +e  # let assertions report instead of aborting
        "$body"
    ) 2>&1
    status=$?

    if [[ $status -eq 0 ]]; then
        PASSED=$((PASSED + 1))
        echo "  ✅ $name"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
        echo "  ❌ $name"
        echo "$output" | sed 's/^/       /'
    fi
}

# ---------------------------------------------------------------------------
# Assertions (exit the test subshell on failure)
# ---------------------------------------------------------------------------

fail() {
    echo "ASSERTION FAILED: $*"
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-value}"
    [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    [[ "$haystack" == *"$needle"* ]] || fail "$label does not contain '$needle'. Full text:
$haystack"
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    [[ "$haystack" != *"$needle"* ]] || fail "$label unexpectedly contains '$needle'. Full text:
$haystack"
}

# Cron schedule lines as "MM HH DOW KIND ALARM ARG" for easy comparison
cron_summary() {
    crontab -l 2>/dev/null | grep 'breaktime-managed' | \
        sed -E 's/^([0-9]+) ([0-9]+) \* \* ([0-9,]+) .* --(warn|execute) "([^"]*)" "([^"]*)".*/\1 \2 \3 \4 \5 \6/' | \
        sort
}

assert_cron_has() {
    local expected="$1"
    local summary
    summary=$(cron_summary)
    grep -qxF "$expected" <<< "$summary" || fail "crontab missing '$expected'. Crontab:
$summary"
}

# Number of dialogs shown by the yad stub, and the arguments of dialog N
yad_calls() {
    find "$HOME/yad" -name '*.args' 2>/dev/null | wc -l | xargs
}

yad_args() {
    cat "$HOME/yad/${1:-1}.args" 2>/dev/null
}

# Queue exit codes for the next yad calls (0 = first button, 10 = snooze,
# 252 = closed, 1 = yad failed e.g. no display)
yad_will_return() {
    printf '%s\n' "$@" > "$HOME/yad_exit_codes"
}

# Wait up to $2 seconds (default 10) for a command to succeed
wait_for() {
    local cmd="$1" timeout="${2:-10}" i
    for ((i = 0; i < timeout * 10; i++)); do
        eval "$cmd" && return 0
        command sleep 0.1
    done
    return 1
}

update_quietly() {
    cron_update_from_config > /dev/null || fail "cron_update_from_config returned $?"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

default_config() {
    cat "$REPO_DIR/config/default.yaml"
}

# Default config with every alarm enabled
all_enabled_config() {
    sed 's/^    enabled: false/    enabled: true/' "$REPO_DIR/config/default.yaml"
}

# Default config with a replaced schedule block
config_with_schedule() {
    local schedule="$1"
    awk -v repl="$schedule" '
        /^schedule:/ { print repl; skip = 1; next }
        skip && /^[^[:space:]]/ { skip = 0 }
        !skip { print }
    ' "$REPO_DIR/config/default.yaml"
}

# ---------------------------------------------------------------------------
# Tests: configuration parsing
# ---------------------------------------------------------------------------

t_config_basic_values() {
    assert_eq "true" "$(config_get_enabled)" "enabled"
    assert_eq "suspend" "$(config_get_alarm_action bedtime)" "bedtime action"
    assert_eq "true" "$(config_get_alarm_enabled bedtime)" "bedtime enabled"
    assert_eq "false" "$(config_get_alarm_enabled lunch_break)" "lunch enabled"
    assert_eq "23:00" "$(config_get_alarm_time bedtime weekdays)" "bedtime weekdays (comment stripped)"
    assert_eq "00:30" "$(config_get_alarm_time bedtime weekends)" "bedtime weekends"
    assert_eq "" "$(config_get_alarm_time lunch_break weekends)" "null time"
    assert_eq "3" "$(config_get_snooze_max)" "max_snoozes"
    assert_eq "2" "$(config_get_snooze_duration)" "snooze_duration"
    assert_eq "true" "$(config_get_desktop_notifications)" "desktop_notifications"
    assert_eq "bedtime lunch_break afternoon_nap focus_break" "$(config_get_alarms | xargs)" "alarm list"
}

t_config_warnings() {
    assert_eq "10 2" "$(config_get_alarm_warnings bedtime | xargs)" "bedtime warnings"
    assert_eq "5" "$(config_get_alarm_warnings afternoon_nap | xargs)" "nap warnings"
}

t_config_custom_warning_message() {
    assert_eq "🌙 Time to start winding down! Bedtime in 10 minutes" \
        "$(config_get_warning_message bedtime 10)" "10-minute message"
    assert_eq "😴 Save your work! Going to sleep in 2 minutes" \
        "$(config_get_warning_message bedtime 2)" "2-minute message"
    assert_eq "🔄 Time to step away from the screen!" \
        "$(config_get_warning_message focus_break 1)" "focus 1-minute message"
    assert_eq "System will suspend in 7 minutes" \
        "$(config_get_warning_message bedtime 7)" "fallback message"
}

t_config_default_action_fallback() {
    assert_eq "hibernate" "$(config_get_alarm_action bedtime)" "falls back to default_action"
}

t_config_missing_file_defaults() {
    rm -f "$CONFIG_FILE"
    assert_eq "false" "$(config_get_enabled)" "enabled"
    assert_eq "3" "$(config_get_snooze_max)" "max_snoozes"
    assert_eq "true" "$(config_get_desktop_notifications)" "desktop_notifications"
    assert_eq "mon tue wed thu fri" "$(config_get_workdays | xargs)" "workdays"
}

t_config_workdays_inline() {
    assert_eq "mon tue wed thu" "$(config_get_workdays | xargs)" "workdays"
    assert_eq "1 2 3 4" "$(config_get_workday_indices)" "indices"
}

t_config_workdays_block_list() {
    assert_eq "tue wed thu fri" "$(config_get_workdays | xargs)" "workdays"
}

t_config_no_schedule_block() {
    assert_eq "mon tue wed thu fri" "$(config_get_workdays | xargs)" "workdays"
    assert_eq "evening" "$(config_get_schedule_value mode evening)" "mode"
}

t_validate_default_ok() {
    config_validate || fail "default config should be valid"
}

t_validate_bad_values() {
    local errors
    errors=$(config_validate 2>&1) && fail "invalid config accepted"
    assert_contains "$errors" "alarms.bedtime.weekdays: invalid time '25:00'"
    assert_contains "$errors" "alarms.lunch_break.action: unknown action 'nap'"
    assert_contains "$errors" "schedule.workdays: unknown day 'funday'"
}

# ---------------------------------------------------------------------------
# Tests: cron scheduling
# ---------------------------------------------------------------------------

t_schedule_all_alarms() {
    # Regression: ((count++)) under `set -e` used to abort after the first alarm
    set -e
    cron_update_from_config > /dev/null
    set +e
    local summary
    summary=$(cron_summary)
    local alarm
    for alarm in bedtime lunch_break afternoon_nap focus_break; do
        assert_contains "$summary" "execute ${alarm} suspend" "crontab"
    done
}

t_schedule_default_bedtime() {
    update_quietly
    # Weekday bedtime on the nights before Mon-Fri (Sun-Thu), weekend bedtime
    # after midnight on Saturday and Sunday mornings (Fri and Sat nights)
    assert_cron_has "00 23 0,1,2,3,4 execute bedtime suspend"
    assert_cron_has "50 22 0,1,2,3,4 warn bedtime 10"
    assert_cron_has "58 22 0,1,2,3,4 warn bedtime 2"
    assert_cron_has "30 00 0,6 execute bedtime suspend"
    assert_cron_has "20 00 0,6 warn bedtime 10"
    assert_cron_has "28 00 0,6 warn bedtime 2"
    assert_eq "6" "$(cron_summary | wc -l | xargs)" "number of cron lines"
}

t_schedule_four_day_week() {
    update_quietly
    # Thursday night is now a weekend night -> Friday 00:30
    assert_cron_has "00 23 0,1,2,3 execute bedtime suspend"
    assert_cron_has "30 00 0,5,6 execute bedtime suspend"
}

t_schedule_daytime_alarm_uses_today() {
    update_quietly
    assert_cron_has "30 12 1,2,3,4,5 execute lunch_break suspend"
    assert_cron_has "25 12 1,2,3,4,5 warn lunch_break 5"
    assert_cron_has "00 15 0,6 execute afternoon_nap suspend"
    assert_cron_has "00 16 1,2,3,4,5 execute focus_break suspend"
}

t_schedule_warning_crosses_midnight() {
    update_quietly
    # 00:05 belongs to the evening before a workday -> fires Mon-Fri morning,
    # and its 10-minute warning at 23:55 the previous calendar day (Sun-Thu)
    assert_cron_has "05 00 1,2,3,4,5 execute late alarm"
    assert_cron_has "55 23 0,1,2,3,4 warn late 10"
}

t_schedule_warning_wraps_week() {
    update_quietly
    # Sunday 00:05 alarm -> its warning lands on Saturday 23:55 (day 6)
    assert_cron_has "05 00 0 execute wrap suspend"
    assert_cron_has "55 23 6 warn wrap 10"
}

t_schedule_calendar_mode() {
    update_quietly
    assert_cron_has "00 23 1,2,3,4,5 execute bedtime suspend"
    assert_cron_has "30 00 0,6 execute bedtime suspend"
}

t_schedule_disabled_globally() {
    update_quietly
    [[ -z "$(cron_summary)" ]] || fail "expected no jobs, got: $(cron_summary)"
}

t_schedule_keeps_user_cron_lines() {
    echo "0 9 * * * /usr/bin/backup" | crontab -
    update_quietly
    update_quietly
    local table
    table=$(crontab -l)
    assert_contains "$table" "0 9 * * * /usr/bin/backup" "crontab"
    assert_eq "6" "$(cron_summary | wc -l | xargs)" "jobs after two updates (no duplicates)"
}

t_remove_all_on_empty_result() {
    update_quietly
    cron_remove_all > /dev/null || fail "cron_remove_all failed"
    assert_eq "" "$(crontab -l 2>/dev/null)" "crontab after removal"
}

t_cron_line_logs_to_state_dir() {
    update_quietly
    local line
    line=$(crontab -l | head -1)
    assert_contains "$line" "$HOME/.local/state/breaktime/logs/cron-execution.log" "cron line"
    assert_not_contains "$line" "/tmp/breaktime" "cron line"
    [[ -d "$HOME/.local/state/breaktime/logs" ]] || fail "log directory was not created"
}

t_format_days() {
    assert_eq "Sun–Thu" "$(cron_format_days 0,1,2,3,4)"
    assert_eq "Mon–Fri" "$(cron_format_days 1,2,3,4,5)"
    assert_eq "Sat, Sun" "$(cron_format_days 0,6)"
    assert_eq "Daily" "$(cron_format_days 0,1,2,3,4,5,6)"
    assert_eq "Mon, Wed, Fri" "$(cron_format_days 1,3,5)"
    assert_eq "Fri–Sun" "$(cron_format_days 0,5,6)"
}

t_warning_time_helper() {
    assert_eq "22:50" "$(cron_calculate_warning_time 23 00 10)"
    assert_eq "23:55" "$(cron_calculate_warning_time 00 05 10)"
    assert_eq "08:59" "$(cron_calculate_warning_time 09 00 1)"
}

# ---------------------------------------------------------------------------
# Tests: snooze
# ---------------------------------------------------------------------------

t_snooze_counts() {
    assert_eq "0" "$(snooze_get_count bedtime)" "initial count"
    assert_eq "true" "$(snooze_is_allowed bedtime)" "allowed"
    snooze_increment_count bedtime > /dev/null
    snooze_increment_count bedtime > /dev/null
    assert_eq "2" "$(snooze_get_count bedtime)" "count"
    assert_eq "1" "$(snooze_get_remaining bedtime)" "remaining"
    snooze_increment_count bedtime > /dev/null
    assert_eq "false" "$(snooze_is_allowed bedtime)" "allowed at limit"
    assert_eq "0" "$(snooze_get_remaining bedtime)" "remaining at limit"
    snooze_reset_count bedtime
    assert_eq "0" "$(snooze_get_count bedtime)" "count after reset"
}

t_snooze_suspend_schedules_job() {
    daemon_handle_snooze_suspend bedtime || fail "snooze refused"
    local jobs
    jobs=$(ls "$SNOOZE_STATE_DIR/pending")
    assert_contains "$jobs" "bedtime_" "pending jobs"
    assert_eq "1" "$(snooze_get_count bedtime)" "count"

    snooze_set_count bedtime 3
    daemon_handle_snooze_suspend bedtime && fail "snooze beyond the limit was accepted"
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR/pending" -name '*.job' | wc -l | xargs)" "pending job count"
}

t_snooze_pending_runs_when_due() {
    # Replace the dialog with a marker file
    notify_send_final() { echo "$1 $2" >> "$HOME/final_dialogs.txt"; }
    snooze_init
    snooze_schedule_job bedtime "$(( $(date +%s) - 5 ))" suspend 1 > /dev/null
    snooze_schedule_job lunch_break "$(( $(date +%s) + 3600 ))" suspend 1 > /dev/null
    snooze_check_pending
    wait

    assert_eq "bedtime suspend" "$(cat "$HOME/final_dialogs.txt" 2>/dev/null)" "dialogs shown"
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR/completed" -name 'bedtime_*' | wc -l | xargs)" "completed jobs"
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR/pending" -name 'lunch_break_*' | wc -l | xargs)" "future job kept"

    snooze_check_pending
    wait
    assert_eq "1" "$(wc -l < "$HOME/final_dialogs.txt" | xargs)" "due job ran only once"
}

t_snooze_cleanup_jobs() {
    snooze_init
    snooze_schedule_job bedtime "$(( $(date +%s) + 60 ))" suspend 1 > /dev/null
    snooze_schedule_job lunch_break "$(( $(date +%s) + 60 ))" suspend 1 > /dev/null
    snooze_cleanup_jobs bedtime
    assert_eq "0" "$(find "$SNOOZE_STATE_DIR/pending" -name 'bedtime_*' | wc -l | xargs)" "bedtime jobs"
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR/pending" -name 'lunch_break_*' | wc -l | xargs)" "other jobs kept"
}

# ---------------------------------------------------------------------------
# Tests: notifications and actions
# ---------------------------------------------------------------------------

t_escape_markup() {
    assert_eq "Tom &amp; Jerry &lt;3 &gt;" "$(notify_escape_markup "Tom & Jerry <3 >")"
}

t_format_alarm_name() {
    assert_eq "🌙 Bedtime" "$(format_alarm_name bedtime)"
    assert_eq "Evening Walk" "$(format_alarm_name evening_walk)"
}

t_execute_without_notifications_runs_action() {
    sleep() { :; }  # skip the 3-second grace period
    cron_execute_action bedtime suspend > /dev/null
    assert_contains "$(cat "$HOME/systemctl.log")" "suspend" "systemctl calls"
}

t_warning_without_notifications_is_silent() {
    yad_send_notification() { fail "dialog shown although notifications are disabled"; }
    cron_execute_warning bedtime 10
    assert_contains "$(cat "$HOME/syslog.txt")" "Warning suppressed" "syslog"
}

t_debug_logging_off_by_default() {
    debug_log "test" "INFO" "hello"
    [[ ! -e "$DEBUG_LOG_DIR/test.log" ]] || fail "debug log written although debug is off"
    BREAKTIME_DEBUG=1 debug_log "test" "INFO" "hello"
    assert_contains "$(cat "$DEBUG_LOG_DIR/test.log")" "hello" "debug log"
}

# ---------------------------------------------------------------------------
# Tests: dialogs (driven through the yad stub)
# ---------------------------------------------------------------------------

t_final_suspend_now() {
    snooze_set_count bedtime 2
    snooze_schedule_job bedtime "$(( $(date +%s) + 600 ))" suspend 2 > /dev/null
    yad_will_return 0

    ( notify_send_final bedtime suspend ) || fail "final dialog exited with $?"

    assert_eq "1" "$(yad_calls)" "dialogs shown"
    local args
    args=$(yad_args 1)
    assert_contains "$args" "--button=Suspend Now:0" "yad args"
    assert_contains "$args" "--button=Snooze 2min (1/3 left):10" "yad args"
    assert_contains "$args" "Used 2/3" "yad args"
    assert_contains "$args" "--undecorated" "yad args"
    assert_contains "$(cat "$HOME/systemctl.log")" "suspend" "systemctl calls"
    assert_eq "0" "$(snooze_get_count bedtime)" "snooze count after suspend"
    assert_eq "0" "$(find "$SNOOZE_STATE_DIR/pending" -name 'bedtime_*' | wc -l | xargs)" "pending jobs"
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR" -name 'suspend_success_bedtime_*' | wc -l | xargs)" "success marker"
}

t_final_snooze_button() {
    yad_will_return 10

    ( notify_send_final bedtime suspend ) || fail "final dialog exited with $?"

    assert_eq "1" "$(snooze_get_count bedtime)" "snooze count"
    local job
    job=$(find "$SNOOZE_STATE_DIR/pending" -name 'bedtime_*.job')
    [[ -n "$job" ]] || fail "no pending snooze job"
    local TARGET_TIME ACTION SNOOZE_COUNT
    # shellcheck source=/dev/null
    source "$job"
    assert_eq "suspend" "$ACTION" "job action"
    assert_eq "1" "$SNOOZE_COUNT" "job snooze count"
    local delay=$(( TARGET_TIME - $(date +%s) ))
    [[ $delay -ge 110 && $delay -le 121 ]] || fail "snooze delay ${delay}s, expected ~120s"
    assert_not_contains "$(cat "$HOME/systemctl.log" 2>/dev/null)" "suspend" "systemctl calls"
}

t_final_snooze_limit_reached() {
    snooze_set_count bedtime 3
    yad_will_return 0

    ( notify_send_final bedtime suspend )

    local args
    args=$(yad_args 1)
    assert_not_contains "$args" "--button=Snooze" "buttons"
    assert_contains "$args" "--button=Suspend Now:0" "buttons"
    assert_contains "$args" "Snooze limit reached (3/3)" "dialog text"
}

t_final_limit_reached_ignores_snooze_code() {
    # Even if yad reports the snooze code at the limit, no job must be created
    snooze_set_count bedtime 3
    yad_will_return 10

    ( notify_send_final bedtime suspend )

    assert_eq "0" "$(find "$SNOOZE_STATE_DIR/pending" -name '*.job' 2>/dev/null | wc -l | xargs)" "pending jobs"
    assert_eq "3" "$(snooze_get_count bedtime)" "snooze count"
}

t_final_yad_failure_is_not_a_snooze() {
    # Regression: yad exits 1 when it cannot open the display; that used to
    # be the snooze button's code, so a broken display silently snoozed
    sleep() { :; }
    yad_will_return 1 1 0

    ( notify_send_final bedtime suspend )

    assert_eq "3" "$(yad_calls)" "dialogs shown"
    assert_eq "0" "$(snooze_get_count bedtime)" "snooze count"
    assert_eq "0" "$(find "$SNOOZE_STATE_DIR/pending" -name '*.job' 2>/dev/null | wc -l | xargs)" "pending jobs"
    assert_contains "$(cat "$HOME/systemctl.log")" "suspend" "systemctl calls"
}

t_final_dismissed_dialog_reappears() {
    sleep() { :; }
    yad_will_return 252 70 0

    ( notify_send_final bedtime suspend )

    assert_eq "3" "$(yad_calls)" "dialogs shown"
    assert_contains "$(cat "$HOME/systemctl.log")" "suspend" "systemctl calls"
}

t_final_gives_up_after_ten_dismissals() {
    sleep() { :; }
    yad_will_return 252 252 252 252 252 252 252 252 252 252 252 252

    ( notify_send_final bedtime suspend )

    assert_eq "10" "$(yad_calls)" "dialogs shown"
    assert_not_contains "$(cat "$HOME/systemctl.log" 2>/dev/null)" "suspend" "systemctl calls"
}

t_final_skipped_after_recent_suspend() {
    snooze_init
    touch "$SNOOZE_STATE_DIR/suspend_success_bedtime_$(date +%s)"

    ( notify_send_final bedtime suspend )

    assert_eq "0" "$(yad_calls)" "dialogs shown"
}

t_final_shutdown_action() {
    yad_will_return 0

    ( notify_send_final bedtime shutdown )

    assert_contains "$(yad_args 1)" "--button=Shut Down Now:0" "yad args"
    assert_contains "$(cat "$HOME/systemctl.log")" "poweroff" "systemctl calls"
}

t_warning_dialogs() {
    cron_execute_warning bedtime 10
    cron_execute_warning bedtime 2

    assert_eq "2" "$(yad_calls)" "dialogs shown"
    local first second
    first=$(yad_args 1)
    second=$(yad_args 2)
    assert_contains "$first" "--text=🌙 Time to start winding down! Bedtime in 10 minutes" "10-min warning"
    assert_contains "$first" "--timeout=8" "10-min warning"
    assert_contains "$first" "--image=night-light" "10-min warning"
    assert_not_contains "$first" "--undecorated" "10-min warning"
    assert_contains "$second" "--text=😴 Save your work! Going to sleep in 2 minutes" "2-min warning"
    assert_contains "$second" "--timeout=12" "2-min warning"
    assert_contains "$second" "--button=OK:0" "2-min warning"
}

t_message_special_characters() {
    assert_eq "Save & quit <now>, it's #1 \"really\"" "$(config_get_warning_message bedtime 10)" "parsed message"
    cron_execute_warning bedtime 10
    assert_contains "$(yad_args 1)" "--text=Save &amp; quit &lt;now&gt;, it's #1 \"really\"" "yad text"
}

t_fallback_to_notify_send() {
    # Pretend yad and zenity are not installed
    command() {
        if [[ "$1" == "-v" && ( "$2" == "yad" || "$2" == "zenity" ) ]]; then
            return 1
        fi
        builtin command "$@"
    }
    cron_execute_warning bedtime 2
    assert_eq "0" "$(yad_calls)" "yad dialogs"
    local sent
    sent=$(cat "$HOME/notify-send.log")
    assert_contains "$sent" "--urgency=critical" "notify-send args"
    assert_contains "$sent" "Save your work" "notify-send args"
}

t_full_snooze_cycle() {
    # Final dialog -> snooze -> job becomes due -> dialog again -> suspend
    yad_will_return 10 0
    ( notify_send_final bedtime suspend )
    local job
    job=$(find "$SNOOZE_STATE_DIR/pending" -name 'bedtime_*.job')
    [[ -n "$job" ]] || fail "no pending job after snooze"
    sed -i 's/^TARGET_TIME=.*/TARGET_TIME="1"/' "$job"

    snooze_check_pending
    wait

    assert_eq "2" "$(yad_calls)" "dialogs shown"
    assert_contains "$(yad_args 2)" "Used 1/3" "second dialog"
    assert_contains "$(yad_args 2)" "(2/3 left)" "second dialog"
    assert_contains "$(cat "$HOME/systemctl.log")" "suspend" "systemctl calls"
    assert_eq "0" "$(snooze_get_count bedtime)" "count after suspend"
}

# ---------------------------------------------------------------------------
# Tests: daemon (runs the real --daemon loop with short intervals)
# ---------------------------------------------------------------------------

t_daemon_lifecycle() {
    export BREAKTIME_POLL_INTERVAL=1 BREAKTIME_CONFIG_POLL_INTERVAL=1
    "$REPO_DIR/breaktime.sh" --daemon > "$HOME/daemon.out" 2>&1 &
    local pid=$!

    wait_for 'cron_summary | grep -q "execute bedtime"' 10 \
        || fail "daemon did not install cron jobs. Output: $(cat "$HOME/daemon.out")"

    # Config change is picked up
    sed -i '/lunch_break:/,/action/ s/enabled: false/enabled: true/' "$CONFIG_FILE"
    touch -d '+5 seconds' "$CONFIG_FILE"
    wait_for 'cron_summary | grep -q "execute lunch_break"' 15 \
        || fail "config change not applied. Crontab: $(cron_summary)"

    # A due snooze job shows the dialog, and "Suspend Now" suspends
    yad_will_return 0
    snooze_schedule_job bedtime 1 suspend 1 > /dev/null
    wait_for '[[ -f "$HOME/systemctl.log" ]] && grep -q suspend "$HOME/systemctl.log"' 10 \
        || fail "due snooze job was not executed"
    assert_eq "0" "$(find "$SNOOZE_STATE_DIR/pending" -name '*.job' | wc -l | xargs)" "pending jobs"

    # Invalid config keeps the existing jobs
    local before
    before=$(cron_summary)
    sed -i 's/weekdays: "23:00"/weekdays: "99:99"/' "$CONFIG_FILE"
    touch -d '+10 seconds' "$CONFIG_FILE"
    wait_for 'grep -q "validation failed" "$HOME/syslog.txt"' 15 || fail "invalid config not reported"
    assert_eq "$before" "$(cron_summary)" "crontab after invalid config"

    # Clean shutdown on SIGTERM, including the config monitor
    local children
    children=$(pgrep -P "$pid" | xargs)
    kill -TERM "$pid"
    wait_for "! kill -0 $pid 2>/dev/null" 5 || fail "daemon ignored SIGTERM"
    local child
    for child in $children; do
        wait_for "! kill -0 $child 2>/dev/null" 5 || fail "child $child still running after SIGTERM"
    done
}

t_daemon_restarts_dead_monitor() {
    export BREAKTIME_POLL_INTERVAL=1 BREAKTIME_CONFIG_POLL_INTERVAL=1
    "$REPO_DIR/breaktime.sh" --daemon > "$HOME/daemon.out" 2>&1 &
    local pid=$!
    wait_for 'cron_summary | grep -q "execute bedtime"' 10 || fail "daemon did not start"

    # Kill the monitor subshell (the child that is not a sleep)
    local child monitor=""
    for child in $(pgrep -P "$pid"); do
        [[ "$(ps -o comm= -p "$child")" == "sleep" ]] || monitor=$child
    done
    [[ -n "$monitor" ]] || fail "monitor process not found"
    kill "$monitor"
    wait_for 'grep -q "Config monitor stopped" "$HOME/syslog.txt"' 10 || fail "monitor was not restarted"

    kill -TERM "$pid"
    wait_for "! kill -0 $pid 2>/dev/null" 5 || fail "daemon ignored SIGTERM"
}

# ---------------------------------------------------------------------------
# Tests: regressions from code review
# ---------------------------------------------------------------------------

t_review_bad_warning_minutes() {
    local errors
    errors=$(config_validate 2>&1) && fail "non-numeric warning minutes accepted"
    assert_contains "$errors" "alarms.bedtime.warnings: invalid minutes '10m'"
    # Scheduling it anyway must report a failure instead of silently dropping it
    local output
    output=$(cron_update_from_config 2>&1)
    assert_contains "$output" "Failed to add alarm: bedtime" "update output"
}

t_review_mixed_day_and_night_times() {
    update_quietly
    # nap: weekdays 23:00 (night), weekends 15:00 (day) -> 15:00 on Sat/Sun
    assert_cron_has "00 23 0,1,2,3,4 execute nap suspend"
    assert_cron_has "00 15 0,6 execute nap suspend"
    # late: weekdays 16:00 (day), weekends 01:00 (night of Fri/Sat) -> Sat/Sun 01:00
    assert_cron_has "00 16 1,2,3,4,5 execute late suspend"
    assert_cron_has "00 01 0,6 execute late suspend"
}

t_review_warnings_same_indent() {
    assert_eq "10 2" "$(config_get_alarm_warnings bedtime | xargs)" "warnings"
    assert_eq "second" "$(config_get_warning_message bedtime 2)" "message"
}

t_review_alarm_name_prefixes() {
    snooze_schedule_job lunch_break "$(( $(date +%s) + 60 ))" suspend 1 > /dev/null
    snooze_cleanup_jobs lunch
    assert_eq "1" "$(find "$SNOOZE_STATE_DIR/pending" -name 'lunch_break_*' | wc -l | xargs)" "lunch_break job kept"

    touch "$SNOOZE_STATE_DIR/suspend_success_lunch_break_$(date +%s)"
    yad_will_return 0
    ( notify_send_final lunch suspend )
    assert_eq "1" "$(yad_calls)" "lunch dialog shown despite lunch_break marker"
}

t_review_empty_workdays() {
    assert_eq "" "$(config_get_workdays)" "workdays"
    update_quietly
    assert_cron_has "30 00 0,1,2,3,4,5,6 execute bedtime suspend"
    assert_not_contains "$(cron_summary)" "00 23" "crontab"
}

t_review_crlf_config() {
    config_validate || fail "CRLF config rejected"
    assert_eq "mon tue wed thu" "$(config_get_workdays | xargs)" "workdays"
    assert_eq "true" "$(config_get_enabled)" "enabled"
    update_quietly
    assert_cron_has "00 23 0,1,2,3 execute bedtime suspend"
    assert_cron_has "30 00 0,5,6 execute bedtime suspend"
}

t_review_hash_inside_unquoted_value() {
    assert_eq "It's C# time" "$(config_get_warning_message bedtime 10)" "message"
    assert_eq "suspend" "$(config_get_top_value default_action)" "value followed by a comment"
}

t_review_backslash_in_message() {
    assert_eq 'C:\\new &amp; &lt;b&gt;' "$(notify_escape_markup 'C:\new & <b>')"
}

# ---------------------------------------------------------------------------
# Tests: command line
# ---------------------------------------------------------------------------

t_cli_status() {
    update_quietly
    local output
    output=$("$REPO_DIR/breaktime.sh" --status) || fail "--status exited with $?"
    assert_contains "$output" "Sun–Thu"
    assert_contains "$output" "Sat, Sun"
    assert_contains "$output" "Bedtime"
}

t_cli_execute_on_fresh_home() {
    # Regression: with no ~/.cache/breaktime yet, "Suspend Now" used to abort
    # (set -e) while writing its marker file, before suspending
    rm -rf "$HOME/.cache"
    yad_will_return 0
    "$REPO_DIR/breaktime.sh" --execute bedtime suspend > /dev/null 2>&1 || fail "--execute exited with $?"
    assert_contains "$(cat "$HOME/systemctl.log" 2>/dev/null)" "suspend" "systemctl calls"
}

t_cli_warn_and_snooze_commands() {
    "$REPO_DIR/breaktime.sh" --warn bedtime 10 || fail "--warn exited with $?"
    assert_contains "$(yad_args 1)" "Time to start winding down" "warning dialog"
    "$REPO_DIR/breaktime.sh" --snooze-suspend bedtime || fail "--snooze-suspend exited with $?"
    assert_eq "1" "$(find "$HOME/.cache/breaktime/pending" -name 'bedtime_*.job' | wc -l | xargs)" "pending jobs"
}

t_cli_help_and_unknown() {
    "$REPO_DIR/breaktime.sh" --help | grep -q "USAGE" || fail "--help output"
    "$REPO_DIR/breaktime.sh" --bogus > /dev/null 2>&1 && fail "unknown option accepted"
    return 0
}

t_cli_install_via_symlink() {
    mkdir -p "$HOME/.local/bin"
    ln -s "$REPO_DIR/breaktime.sh" "$HOME/.local/bin/breaktime"
    rm -f "$CONFIG_FILE"
    "$HOME/.local/bin/breaktime" --install > /dev/null || fail "--install failed"
    [[ -f "$CONFIG_FILE" ]] || fail "config not created"
    local unit="$HOME/.config/systemd/user/breaktime.service"
    assert_contains "$(cat "$unit")" "ExecStart=$REPO_DIR/breaktime.sh --daemon" "service file"
    assert_contains "$(cat "$HOME/systemctl.log")" "--user enable breaktime.service" "systemctl calls"
}

# ---------------------------------------------------------------------------
# Test list
# ---------------------------------------------------------------------------

echo "🧪 breaktime tests"

run_test config_basic_values t_config_basic_values < <(default_config)
run_test config_warnings t_config_warnings < <(default_config)
run_test config_custom_warning_message t_config_custom_warning_message < <(default_config)
run_test config_default_action_fallback t_config_default_action_fallback < <(sed -e 's/^default_action: suspend/default_action: hibernate/' -e '/^    action: suspend/d' "$REPO_DIR/config/default.yaml")
run_test config_missing_file_defaults t_config_missing_file_defaults < <(default_config)
run_test config_workdays_inline t_config_workdays_inline < <(config_with_schedule 'schedule:
  workdays: [mon, tue, "wed", thu]  # 80%')
run_test config_workdays_block_list t_config_workdays_block_list < <(config_with_schedule 'schedule:
  workdays:
    - tue
    - wed
    - thu
    - fri
  mode: evening')
run_test config_no_schedule_block t_config_no_schedule_block < <(config_with_schedule '')
run_test validate_default_ok t_validate_default_ok < <(default_config)
run_test validate_bad_values t_validate_bad_values < <(config_with_schedule 'schedule:
  workdays: [mon, funday]' \
    | sed -e 's/weekdays: "23:00"/weekdays: "25:00"/' \
          -e '/lunch_break:/,/weekdays/ s/action: suspend/action: nap/')

run_test schedule_all_alarms t_schedule_all_alarms < <(all_enabled_config)
run_test schedule_default_bedtime t_schedule_default_bedtime < <(default_config)
run_test schedule_four_day_week t_schedule_four_day_week < <(config_with_schedule 'schedule:
  workdays: [mon, tue, wed, thu]')
run_test schedule_daytime_alarm_uses_today t_schedule_daytime_alarm_uses_today < <(all_enabled_config)
run_test schedule_warning_crosses_midnight t_schedule_warning_crosses_midnight <<'EOF'
enabled: true
alarms:
  late:
    enabled: true
    action: alarm
    weekdays: "00:05"
    weekends: null
    warnings:
      - minutes: 10
        message: "late"
EOF
run_test schedule_warning_wraps_week t_schedule_warning_wraps_week <<'EOF'
enabled: true
schedule:
  workdays: [sun]
alarms:
  wrap:
    enabled: true
    weekdays: "00:05"
    warnings:
      - minutes: 10
        message: "wrap"
EOF
run_test schedule_calendar_mode t_schedule_calendar_mode < <(config_with_schedule 'schedule:
  mode: calendar')
run_test schedule_disabled_globally t_schedule_disabled_globally < <(sed 's/^enabled: true/enabled: false/' "$REPO_DIR/config/default.yaml")
run_test schedule_keeps_user_cron_lines t_schedule_keeps_user_cron_lines < <(default_config)
run_test remove_all_on_empty_result t_remove_all_on_empty_result < <(default_config)
run_test cron_line_logs_to_state_dir t_cron_line_logs_to_state_dir < <(default_config)
run_test format_days t_format_days < <(default_config)
run_test warning_time_helper t_warning_time_helper < <(default_config)

run_test snooze_counts t_snooze_counts < <(default_config)
run_test snooze_suspend_schedules_job t_snooze_suspend_schedules_job < <(default_config)
run_test snooze_pending_runs_when_due t_snooze_pending_runs_when_due < <(default_config)
run_test snooze_cleanup_jobs t_snooze_cleanup_jobs < <(default_config)

run_test escape_markup t_escape_markup < <(default_config)
run_test format_alarm_name t_format_alarm_name < <(default_config)
run_test execute_without_notifications_runs_action t_execute_without_notifications_runs_action < <(sed 's/desktop_notifications: true/desktop_notifications: false/' "$REPO_DIR/config/default.yaml")
run_test warning_without_notifications_is_silent t_warning_without_notifications_is_silent < <(sed 's/desktop_notifications: true/desktop_notifications: false/' "$REPO_DIR/config/default.yaml")
run_test debug_logging_off_by_default t_debug_logging_off_by_default < <(default_config)

run_test final_suspend_now t_final_suspend_now < <(default_config)
run_test final_snooze_button t_final_snooze_button < <(default_config)
run_test final_snooze_limit_reached t_final_snooze_limit_reached < <(default_config)
run_test final_limit_reached_ignores_snooze_code t_final_limit_reached_ignores_snooze_code < <(default_config)
run_test final_yad_failure_is_not_a_snooze t_final_yad_failure_is_not_a_snooze < <(default_config)
run_test final_dismissed_dialog_reappears t_final_dismissed_dialog_reappears < <(default_config)
run_test final_gives_up_after_ten_dismissals t_final_gives_up_after_ten_dismissals < <(default_config)
run_test final_skipped_after_recent_suspend t_final_skipped_after_recent_suspend < <(default_config)
run_test final_shutdown_action t_final_shutdown_action < <(default_config)
run_test warning_dialogs t_warning_dialogs < <(default_config)
run_test message_special_characters t_message_special_characters < <(sed 's/message: "🌙 Time to start winding down! Bedtime in 10 minutes"/message: "Save \& quit <now>, it'"'"'s #1 \\"really\\""  # comment/' "$REPO_DIR/config/default.yaml")
run_test fallback_to_notify_send t_fallback_to_notify_send < <(default_config)
run_test full_snooze_cycle t_full_snooze_cycle < <(default_config)
run_test daemon_lifecycle t_daemon_lifecycle < <(default_config)
run_test daemon_restarts_dead_monitor t_daemon_restarts_dead_monitor < <(default_config)

run_test review_bad_warning_minutes t_review_bad_warning_minutes < <(sed 's/- minutes: 10$/- minutes: "10m"/' "$REPO_DIR/config/default.yaml")
run_test review_mixed_day_and_night_times t_review_mixed_day_and_night_times <<'EOF'
enabled: true
alarms:
  nap:
    enabled: true
    weekdays: "23:00"
    weekends: "15:00"
  late:
    enabled: true
    weekdays: "16:00"
    weekends: "01:00"
EOF
run_test review_warnings_same_indent t_review_warnings_same_indent <<'EOF'
enabled: true
alarms:
  bedtime:
    enabled: true
    weekdays: "23:00"
    warnings:
    - minutes: 10
      message: "first"
    - minutes: 2
      message: "second"
    action: suspend
EOF
run_test review_alarm_name_prefixes t_review_alarm_name_prefixes <<'EOF'
enabled: true
alarms:
  lunch:
    enabled: true
    weekdays: "12:00"
  lunch_break:
    enabled: true
    weekdays: "12:30"
EOF
run_test review_empty_workdays t_review_empty_workdays < <(config_with_schedule 'schedule:
  workdays: []')
run_test review_crlf_config t_review_crlf_config < <(config_with_schedule 'schedule:
  workdays: [mon, tue, wed, thu]' | sed 's/$/\r/')
run_test review_hash_inside_unquoted_value t_review_hash_inside_unquoted_value < <(sed -e "s/message: \"🌙 Time to start winding down! Bedtime in 10 minutes\"/message: It's C# time   # comment/" "$REPO_DIR/config/default.yaml")
run_test review_backslash_in_message t_review_backslash_in_message < <(default_config)

run_test cli_status t_cli_status < <(default_config)
run_test cli_execute_on_fresh_home t_cli_execute_on_fresh_home < <(default_config)
run_test cli_warn_and_snooze_commands t_cli_warn_and_snooze_commands < <(default_config)
run_test cli_help_and_unknown t_cli_help_and_unknown < <(default_config)
run_test cli_install_via_symlink t_cli_install_via_symlink < <(default_config)

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "✅ All ${PASSED} tests passed"
else
    echo "❌ ${FAILED} failed, ${PASSED} passed: ${FAILED_NAMES[*]}"
    exit 1
fi
