# Breaktime

🕒 **Automated break scheduling system for healthy work habits**

Breaktime helps you maintain a healthy work-life balance by automatically scheduling and enforcing breaks, bedtime, and other important pauses throughout your day.

## Features

- 🌙 **Bedtime enforcement** - Automatic suspend/shutdown at configured times
- 🍽️ **Lunch breaks** - Midday work interruptions  
- 💤 **Afternoon naps** - Weekend rest periods
- 🧠 **Focus breaks** - End of deep work sessions
- ⚡ **Flexible scheduling** - Different times for weekdays vs weekends
- 🔔 **Smart notifications** - YAD-based dialogs with interactive buttons
- ⏰ **Snooze functionality** - Limited snoozes with countdown display
- 🔕 **Silent mode** - Auto-execute when desktop notifications disabled
- 🔄 **Background service** - Runs automatically on login with 30-second polling
- ⚙️ **YAML configuration** - Easy to customize and version control
- 🛡️ **Persistent dialogs** - Cannot be dismissed accidentally (Alt+F4 protection)

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

# Global notification settings
notifications:
  desktop_notifications: true  # Set to false for auto-execute mode

# Snooze settings for final warnings
snooze:
  max_snoozes: 3        # Maximum number of snoozes allowed per alarm
  snooze_duration: 2    # Minutes to delay each snooze

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

### Notification Settings

- **desktop_notifications: true** - Show YAD dialogs with snooze options
- **desktop_notifications: false** - Auto-execute actions without dialogs (silent mode)

### Snooze System

- **max_snoozes** - Maximum number of snoozes per alarm (default: 3)
- **snooze_duration** - Minutes to delay each snooze (default: 2)
- Snooze counts reset daily and only apply to final suspend dialogs
- Uses reliable file-based scheduling system (no dependency on `at` daemon)

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
- **yad** - For interactive dialog notifications (recommended)
- **zenity** - Fallback for notifications if YAD unavailable
- **notify-send** - Last resort for basic notifications

## File Structure

```
breaktime/
├── breaktime.sh           # Main executable
├── lib/                   # Library modules
│   ├── config.sh         # Configuration management
│   ├── cron.sh           # Cron job management
│   ├── notify.sh         # YAD-based notification system
│   ├── snooze.sh         # File-based snooze job management
│   └── daemon.sh         # Background service with 30s polling
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
1. Install YAD for best experience:
   ```bash
   sudo apt install yad
   ```

2. Install fallback notification support:
   ```bash
   sudo apt install zenity libnotify-bin
   ```

3. Test notifications manually:
   ```bash
   breaktime --test-notifications
   ```

### Snooze not working
1. Check if snooze jobs are being created:
   ```bash
   ls ~/.cache/breaktime/pending/
   ```

2. Check daemon logs for errors:
   ```bash
   journalctl --user -u breaktime -f | grep snooze
   ```

3. Verify service is polling every 30 seconds:
   ```bash
   systemctl --user status breaktime
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