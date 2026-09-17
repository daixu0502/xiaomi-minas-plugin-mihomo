#!/bin/sh
set -eu

status=${1:-stopped}
enabled=${2:-true}
plugin_user=${3:-${PLUG_USER:-}}
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SRC_DIR=$(dirname "$SCRIPT_DIR")

if [ -z "$plugin_user" ]; then
    plugin_user=$(printf '%s\n' "$SRC_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo$#\1#p')
fi
case "$plugin_user" in u*) ;; *) exit 1 ;; esac
case "${plugin_user#u}" in ''|*[!0-9]*) exit 1 ;; esac
case "$status" in running|stopped) ;; *) exit 1 ;; esac
case "$enabled" in true|false) ;; *) exit 1 ;; esac

PLUGIN_HOME="/home/$plugin_user/plugin/mihomo"
LIST_FILE="/data/plugin/$plugin_user.list"
INFO_FILE="$PLUGIN_HOME/INFO"
FRONTEND_FILE="$SRC_DIR/ui/config"
LOCK_FILE="/data/plugin/.$plugin_user.mihomo.lock"

[ -f "$INFO_FILE" ] || exit 1
[ -f "$FRONTEND_FILE" ] || exit 1
if [ ! -f "$LIST_FILE" ]; then
    printf '{}\n' > "$LIST_FILE"
fi
jq empty "$LIST_FILE" >/dev/null 2>&1 || exit 1

exec 9>"$LOCK_FILE"
flock -x 9

list_tmp="$LIST_FILE.mihomo-register.$$"
now=$(date +%s)
jq \
    --slurpfile frontend "$FRONTEND_FILE" \
    --slurpfile info "$INFO_FILE" \
    --arg status "$status" \
    --argjson enabled "$enabled" \
    --argjson now "$now" \
    '.mihomo = ((.mihomo // {}) + {
      resource:((.mihomo.resource // {mpk:"",icon:"",preview:null})),
      status:$status,
      install:true,
      upgrade:false,
      enable:$enabled,
      changetime:$now,
      icon:"/icon/mihomo.icon",
      progress:"100",
      frontend:$frontend[0],
      info:($info[0] | del(.abstract)),
      online:true
    })' "$LIST_FILE" > "$list_tmp"
jq empty "$list_tmp" >/dev/null
chmod --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || chmod 0644 "$list_tmp"
chown --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || true
mv -f "$list_tmp" "$LIST_FILE"
flock -u 9

