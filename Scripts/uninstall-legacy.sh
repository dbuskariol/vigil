#!/bin/sh
# Removes traces of the pre-rename Vigil development build.
# Run once on a machine that has the old dev build installed before installing v0.1.0.
# Safe to run if no legacy install exists.

set -eu

UID_VALUE=$(id -u)

# Old assertion LaunchAgent (pre-rename bundle id).
launchctl bootout "gui/${UID_VALUE}/dev.local.vigil.assertions" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/dev.local.vigil.assertions.plist"

# Old privileged helper Mach-Os (both the original `clamshellctl` name and any
# intermediate transitional names that may have been installed by dev iterations).
sudo rm -f /Library/PrivilegedHelperTools/dev.local.vigil.clamshellctl
sudo rm -f /Library/PrivilegedHelperTools/com.vigil.app.clamshellctl

# Old sudoers drop-in (the non-uid-suffixed legacy form).
sudo rm -f /etc/sudoers.d/vigil

# Old `make install` CLI symlink (now `vigil` instead of `clamshellctl`).
sudo rm -f /usr/local/bin/clamshellctl

echo "Legacy Vigil dev artifacts removed."
echo "macOS's Background Items database may still show an orphan 'Vigil' entry."
echo "To clear it, run 'sfltool resetbtm' (this logs you out)."
