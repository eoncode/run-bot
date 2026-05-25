# UI Test Runner Setup

One-time manual setup required on the self-hosted Mac before UI tests will run.

## 1. Ensure the runner has a GUI session

The runner agent must run as a **user-level launch agent**, not a system daemon. Check:

```bash
# OK — user launch agent (has GUI)
ls ~/Library/LaunchAgents/com.github.runner.*.plist

# Not OK — system daemon (no GUI, UI tests will fail)
ls /Library/LaunchDaemons/com.github.runner.*.plist
```

If it's a system daemon, reinstall:

```bash
cd /path/to/actions-runner
sudo ./svc.sh uninstall
./svc.sh install   # installs to ~/Library/LaunchAgents
./svc.sh start
```

## 2. Grant Accessibility permission to xcodebuild

**System Settings → Privacy & Security → Accessibility** → add `/usr/bin/xcodebuild`
