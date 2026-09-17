#!/bin/sh
set -u

PLUGIN_USER=${1:-}
case "$PLUGIN_USER" in u*) ;; *) exit 1 ;; esac
case "${PLUGIN_USER#u}" in ''|*[!0-9]*) exit 1 ;; esac

PLUGIN_NAME="mihomo"
PLUGIN_HOME="/home/$PLUGIN_USER/plugin/$PLUGIN_NAME"
SRC_DIR=$(readlink "$PLUGIN_HOME/src" 2>/dev/null || true)
CONTROL="$PLUGIN_HOME/scripts/control"
REGISTER="$SRC_DIR/files/register.sh"

[ "$(id -u)" = "0" ] || exit 1
[ -x "$CONTROL" ] || exit 1
[ -x "$REGISTER" ] || exit 1

# Mark stopped first so plugincenter does not mistake the persisted pre-reboot
# state for a live process, and repair the APP entry if it was removed.
"$REGISTER" stopped true "$PLUGIN_USER" || exit 1

/usr/bin/plugincenter -u "$PLUGIN_USER" -p "$PLUGIN_NAME" enable >/dev/null 2>&1 || true

if /usr/sbin/runuser -u "$PLUGIN_USER" -- /usr/bin/env \
    PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$CONTROL" status >/dev/null 2>&1; then
    result=0
else
    /usr/sbin/runuser -u "$PLUGIN_USER" -- /usr/bin/env \
        PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
        PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" enable
    result=$?
fi

if [ "$result" = "0" ]; then
    "$REGISTER" running true "$PLUGIN_USER" || true
    logger -t plugin.mihomo "boot fallback started Mihomo for $PLUGIN_USER"
    exit 0
fi

logger -t plugin.mihomo -p user.err "boot fallback failed for $PLUGIN_USER"
exit "$result"
