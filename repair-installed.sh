#!/bin/sh
set -eu

PLUGIN_USER="${1:-u103868178}"
PROJECT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PLUGIN_HOME="/home/$PLUGIN_USER/plugin/mihomo"
SRC_DIR=$(readlink "$PLUGIN_HOME/src" 2>/dev/null || true)
CONTROL="$PLUGIN_HOME/scripts/control"
INFO_FILE="$PLUGIN_HOME/INFO"

fail() {
    echo "错误：$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "必须以 root 身份运行"
case "$PLUGIN_USER" in u*) ;; *) fail "无效插件用户" ;; esac
case "${PLUGIN_USER#u}" in ''|*[!0-9]*) fail "无效插件用户" ;; esac
case "$SRC_DIR" in
    /nas/pool*/"$PLUGIN_USER"/plugin/pluginsrc/mihomo) ;;
    *) fail "异常的插件源目录：$SRC_DIR" ;;
esac

[ -f "$PROJECT_DIR/payload/files/boot.sh" ] || fail "修复包缺少 boot.sh"
[ -f "$PROJECT_DIR/remote-install.sh" ] || fail "修复包缺少 remote-install.sh"
[ -x "$CONTROL" ] || fail "已安装插件缺少 control"
[ -f "$INFO_FILE" ] || fail "已安装插件缺少 INFO"

cp "$PROJECT_DIR/payload/files/boot.sh" "$SRC_DIR/files/boot.sh"
chown "$PLUGIN_USER:$PLUGIN_USER" "$SRC_DIR/files/boot.sh"
chmod 0755 "$SRC_DIR/files/boot.sh"

# Keep the on-device source project fixed as well, when it exists. Xiaomi's
# root account uses /home/rootx on this firmware rather than /root.
root_home=$(getent passwd root | cut -d: -f6)
if [ -n "$root_home" ] \
   && [ -d "$root_home/mihomo-plugin/payload/files" ] \
   && [ "$PROJECT_DIR" != "$root_home/mihomo-plugin" ]; then
    cp "$PROJECT_DIR/payload/files/boot.sh" "$root_home/mihomo-plugin/payload/files/boot.sh"
    cp "$PROJECT_DIR/remote-install.sh" "$root_home/mihomo-plugin/remote-install.sh"
    chmod 0755 "$root_home/mihomo-plugin/payload/files/boot.sh" "$root_home/mihomo-plugin/remote-install.sh"
fi

digest_file=$(mktemp /tmp/mihomo-repair-digest.XXXXXX)
info_tmp=$(mktemp /tmp/mihomo-repair-info.XXXXXX)
cleanup() {
    rm -f "$digest_file" "$info_tmp"
}
trap cleanup EXIT HUP INT TERM

find "$SRC_DIR/" -type f | LC_ALL=C sort | while IFS= read -r source_file; do
    sha256sum "$source_file" | cut -d ' ' -f 1
done > "$digest_file"
abstract=$(sha256sum "$digest_file" | cut -d ' ' -f 1)
jq --arg abstract "$abstract" '.abstract=$abstract' "$INFO_FILE" > "$info_tmp"
cp "$info_tmp" "$INFO_FILE"
chown "$PLUGIN_USER:$PLUGIN_USER" "$INFO_FILE"
chmod 0600 "$INFO_FILE"

# This is idempotent: an already running process is only verified, not restarted.
PLUG_USER="$PLUGIN_USER" PLUG_NAME=mihomo \
PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
"$CONTROL" enable
"$SRC_DIR/files/register.sh" running true "$PLUGIN_USER"

PLUG_USER="$PLUGIN_USER" PLUG_NAME=mihomo \
PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
"$CONTROL" status

echo "启动与开机助手修复完成。"
echo "abstract=$abstract"
