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

run_test cli_status t_cli_status < <(default_config)
run_test cli_help_and_unknown t_cli_help_and_unknown < <(default_config)
run_test cli_install_via_symlink t_cli_install_via_symlink < <(default_config)

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "✅ All ${PASSED} tests passed"
else
    echo "❌ ${FAILED} failed, ${PASSED} passed: ${FAILED_NAMES[*]}"
    exit 1
fi
