# Breaktime

🕒 **Automated break scheduling system for healthy work habits**

Breaktime helps you maintain a healthy work-life balance by automatically scheduling and enforcing breaks, bedtime, and other important pauses throughout your day.

## Features

- 🌙 **Bedtime enforcement** - Automatic suspend/shutdown at configured times
- 🍽️ **Lunch breaks** - Midday work interruptions
- 💤 **Afternoon naps** - Weekend rest periods
- 🧠 **Focus breaks** - End of deep work sessions
- ⚡ **Flexible scheduling** - Different times for weekdays vs weekends
- 🔔 **Smart notifications** - Customizable warnings before each break
- 🔄 **Background service** - Runs automatically on login
- ⚙️ **YAML configuration** - Easy to customize and version control

## Quick Start

1. **Install breaktime:**
   ```bash
   cd /home/bpeeters/MEGA/repo/bash/breaktime
   ./install.sh
   ```

2. **Configure your breaks:**
   ```bash
   breaktime --config
   ```

3. **Check status:**
   ```bash
   breaktime --status
   ```

## Usage

```bash
# Edit configuration
breaktime --config

# View current status and upcoming breaks
breaktime --status

# Install/setup systemd service
breaktime --install

# Remove systemd service
breaktime --uninstall

# Show help
breaktime --help
```

## Configuration

Breaktime uses a YAML configuration file at `~/.config/breaktime/config.yaml`:

```yaml
enabled: true
default_action: suspend  # suspend, shutdown, hibernate

alarms:
  bedtime:
    enabled: true
    action: suspend
    weekdays: "23:00"     # Sunday-Thursday bedtime
    weekends: "00:30"     # Friday-Saturday late bedtime
    warnings:
      - minutes: 10
        message: "🌙 Time to start winding down! Bedtime in 10 minutes"
      - minutes: 2
        message: "😴 Save your work! Going to sleep in 2 minutes"
```

### Break Types

- **bedtime**: Evening shutdown/suspend for healthy sleep
- **lunch_break**: Midday work interruptions
- **afternoon_nap**: Weekend rest periods
- **focus_break**: End of deep work sessions

### Actions

- **suspend**: Put computer to sleep (recommended)
- **shutdown**: Complete shutdown
- **hibernate**: Save to disk and power off

### Time Format

Use 24-hour format: `"23:00"` for 11 PM, `"07:30"` for 7:30 AM.
Set to `null` to disable for specific day types.

## Installation Details

The install script:
- Creates a symlink at `~/bin/breaktime`
- Sets up systemd user service for background operation
- Creates default configuration
- Enables auto-start on login

## Requirements

- **systemd** - For background service management
- **cron** - For scheduling break actions
- **notify-send** - For desktop notifications (optional)

## File Structure

```
breaktime/
├── breaktime.sh           # Main executable
├── lib/                   # Library modules
│   ├── config.sh         # Configuration management
│   ├── cron.sh           # Cron job management
│   ├── notify.sh         # Notification system
│   └── daemon.sh         # Background service
├── config/
│   └── default.yaml      # Default configuration template
├── systemd/
│   └── breaktime.service # Systemd service template
├── install.sh            # Installation script
└── README.md
```

## Advanced Usage

### Check service status
```bash
systemctl --user status breaktime
```

### View logs
```bash
journalctl --user -u breaktime -f
```

### Test notifications
```bash
breaktime --test-notifications
```

### Manual cron job management
Breaktime automatically manages cron jobs based on your configuration. All breaktime cron jobs are marked with `# breaktime-managed` for easy identification.

## Troubleshooting

### Service not starting
1. Check if systemd user services are enabled:
   ```bash
   systemctl --user status
   ```

2. Verify the service file:
   ```bash
   systemctl --user cat breaktime
   ```

### Notifications not showing
1. Install desktop notification support:
   ```bash
   sudo apt install libnotify-bin
   ```

2. Test notifications manually:
   ```bash
   notify-send "Test" "Hello World"
   ```

### Cron jobs not working
1. Check if cron is running:
   ```bash
   systemctl status cron
   ```

2. View current crontab:
   ```bash
   crontab -l
   ```

## Uninstall

```bash
./install.sh --uninstall
```

This removes the service and cron jobs but preserves your configuration files.

## License

Licensed under AGPL-3.0. See [LICENSE](LICENSE) for details.

## Contributing

This is a personal utility project. Feel free to fork and adapt for your own needs.

## Author

Created by Benjamin Peeters for maintaining healthy work habits and sleep schedules.