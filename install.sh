#!/bin/sh
# Installs kivotos. Run as: sudo sh ~/Packages/kivotos/install.sh
# Safe to run again: updates the program and rewrites the systemd service and timer from the config.
# It never overwrites /etc/kivotos/config.toml or the password, and never touches a repo it can open.
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }

install -Dm755 kivotos /usr/local/bin/kivotos
install -d -m755 /etc/kivotos
[ -f /etc/kivotos/config.toml ] || install -m644 config.toml /etc/kivotos/config.toml

# --- migrate from restic-containers --------------------------------------------------------------
if [ -e /etc/systemd/system/restic-containers.timer ]; then
    systemctl disable --now restic-containers.timer || true
    rm -f /etc/systemd/system/restic-containers.timer /etc/systemd/system/restic-containers.service
    echo ">> Removed the old restic-containers timer and service"
fi
rm -f /usr/local/bin/restic-containers
if [ -s /etc/restic/containers.password ] && [ ! -e /etc/kivotos/password ]; then
    mv /etc/restic/containers.password /etc/kivotos/password
    echo ">> Moved the repo password to /etc/kivotos/password"
fi
rm -f /etc/restic/containers.env /etc/restic/containers.exclude
rmdir /etc/restic 2>/dev/null || true
rm -rf /var/cache/restic

# --- password and repo --------------------------------------------------------------------------
PASS=/etc/kivotos/password
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
