#!/bin/sh
# Installs the restic backup of ~/Containers. Run as: sudo sh ~/Packages/restic-containers/install.sh
# Safe to run again: updates the script, excludes and units; never touches the password or a repo it can open.
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }

install -Dm755 restic-containers /usr/local/bin/restic-containers
install -d -m700 /etc/restic
install -m644 containers.env containers.exclude /etc/restic/
install -m644 restic-containers.service restic-containers.timer /etc/systemd/system/

PASS=/etc/restic/containers.password
if [ ! -s "$PASS" ]; then
    (umask 077; head -c 32 /dev/urandom | base64 > "$PASS")
    echo ">> Generated $PASS. Save a copy in your password manager: without it the backups can't be opened."
fi

set -a; . /etc/restic/containers.env; set +a
if [ -f "$RESTIC_REPOSITORY/config" ] && ! restic cat config >/dev/null 2>&1; then
    # An older repo with a different password. Move it aside only if it never got a snapshot.
    if [ -z "$(find "$RESTIC_REPOSITORY/snapshots" -type f 2>/dev/null)" ]; then
        old="$RESTIC_REPOSITORY.old-$(date +%F)"
        mv "$RESTIC_REPOSITORY" "$old"
        echo ">> Moved the empty old repo (unknown password) to $old. Delete it once you're happy."
    else
        echo "!! $RESTIC_REPOSITORY has snapshots but $PASS doesn't open it. Put the right password in $PASS and re-run." >&2
        exit 1
    fi
fi
[ -f "$RESTIC_REPOSITORY/config" ] || restic init

systemctl daemon-reload
systemctl enable --now restic-containers.timer
echo ">> Installed. First backup now:  sudo systemctl start restic-containers  (watch: journalctl -fu restic-containers)"
