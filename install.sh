#!/bin/sh
# Installs kivotos. Run as: sudo sh path/to/kivotos/install.sh
# First run: puts a config in /etc/kivotos/config.toml and stops, so you can edit it. Then run it again.
# Safe to run again: updates the program and rewrites the systemd service and timer from the config.
# It never overwrites the config or the password, and never touches a repo it can open.
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }

CONFIG=/etc/kivotos/config.toml
PASS=/etc/kivotos/password

install -Dm755 kivotos /usr/local/bin/kivotos
install -d -m755 /etc/kivotos

# --- first run: config --------------------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    install -m644 config.toml "$CONFIG"
    # Hooks run as the user who called sudo, unless the config says otherwise
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        sed -i "s/^user *= .*/user = \"$SUDO_USER\"/" "$CONFIG"
    fi
    echo ">> Wrote $CONFIG. Check the repository, user and sources in it:"
    echo "     sudoedit $CONFIG"
    echo "   then run this installer again to create the repo and the timer."
    exit 0
fi

# --- password and repo --------------------------------------------------------------------------
if [ ! -s "$PASS" ]; then
    (umask 077; head -c 32 /dev/urandom | base64 > "$PASS")
    echo ">> Generated $PASS. Save a copy in your password manager: without it the backups can't be opened."
fi
chown root:root "$PASS"; chmod 600 "$PASS"

if kivotos restic cat config >/dev/null 2>&1; then
    :
elif kivotos restic cat config 2>&1 | grep -q 'repository does not exist'; then
    kivotos restic init
else
    echo "!! The repo exists but $PASS doesn't open it. Fix the password (or the repository in the config) and re-run." >&2
    exit 1
fi

kivotos units
echo ">> Installed. Check the plan with: kivotos plan   Back up now: sudo systemctl start kivotos   Logs: journalctl -fu kivotos"
