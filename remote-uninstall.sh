#!/bin/sh
set -eu

PLUGIN_USER="${1:-u103868178}"
PLUGIN_NAME="mihomo"

fail() {
    echo "错误：$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "必须以 root 身份运行"
case "$PLUGIN_USER" in u*) ;; *) fail "无效插件用户" ;; esac
case "${PLUGIN_USER#u}" in ''|*[!0-9]*) fail "无效插件用户" ;; esac

PLUGIN_ROOT="/home/$PLUGIN_USER/plugin"
PLUGIN_HOME="$PLUGIN_ROOT/$PLUGIN_NAME"
LIST_FILE="/data/plugin/$PLUGIN_USER.list"
SRC_DIR=""
TMP_DIR=""
DOCKER_HELPER="/data/plugin/.mihomo-system/mihomo-docker-proxy"
DOCKER_SUDOERS="/etc/sudoers.d/mihomo-docker-proxy-$PLUGIN_USER"
DOCKER_SUDOERS_LEGACY="/etc/sudoers.d/mihomo-docker-proxy"
PORTS_FILE="$PLUGIN_HOME/etc/ports.env"
[ -L "$PLUGIN_HOME/src" ] && SRC_DIR=$(readlink "$PLUGIN_HOME/src" 2>/dev/null || true)
[ -L "$PLUGIN_HOME/tmp" ] && TMP_DIR=$(readlink "$PLUGIN_HOME/tmp" 2>/dev/null || true)

MIXED_PORT=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" 2>/dev/null | head -n 1)
if [ -x "$DOCKER_HELPER" ] && [ -n "$MIXED_PORT" ]; then
    "$DOCKER_HELPER" disable "$MIXED_PORT" >/dev/null 2>&1 || true
fi
rm -f "$DOCKER_SUDOERS"
if [ -f "$DOCKER_SUDOERS_LEGACY" ] && grep -q "^$PLUGIN_USER[[:space:]]" "$DOCKER_SUDOERS_LEGACY"; then rm -f "$DOCKER_SUDOERS_LEGACY"; fi
if ! find /etc/sudoers.d -maxdepth 1 -type f -name 'mihomo-docker-proxy-u*' | grep -q . && [ ! -f "$DOCKER_SUDOERS_LEGACY" ]; then
    rm -f "$DOCKER_HELPER"
    rmdir /data/plugin/.mihomo-system >/dev/null 2>&1 || true
fi
rmdir /etc/systemd/system/docker.service.d >/dev/null 2>&1 || true

if [ -x "$PLUGIN_HOME/scripts/control" ]; then
    PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$PLUGIN_HOME/scripts/control" disable >/dev/null 2>&1 || true
fi

reserve_dir="$PLUGIN_ROOT/.reserve/$PLUGIN_NAME"
mkdir -p "$reserve_dir"
if [ -d "$PLUGIN_HOME/etc" ]; then
    cp -R "$PLUGIN_HOME/etc/." "$reserve_dir/"
    chown -R "$PLUGIN_USER:$PLUGIN_USER" "$reserve_dir"
    chmod 0700 "$reserve_dir"
fi

if [ -f "$LIST_FILE" ] && jq empty "$LIST_FILE" >/dev/null 2>&1; then
    list_tmp="$LIST_FILE.mihomo-uninstall.$$"
    jq 'del(.mihomo)' "$LIST_FILE" > "$list_tmp"
    chmod --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || chmod 0644 "$list_tmp"
    chown --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || chown "$PLUGIN_USER:$PLUGIN_USER" "$list_tmp"
    mv -f "$list_tmp" "$LIST_FILE"
fi

rm -f "/data/plugin/www/$PLUGIN_USER/$PLUGIN_NAME"
rm -f "/etc/cron.d/mihomo-plugin-$PLUGIN_USER"
if [ -f /etc/cron.d/mihomo-plugin ] && grep -Fq "boot.sh $PLUGIN_USER" /etc/cron.d/mihomo-plugin; then rm -f /etc/cron.d/mihomo-plugin; fi
rm -f "/data/plugin/.$PLUGIN_USER.mihomo.lock"

hotplug_root=$(jq -r '.settings.system_hotplug // empty' /etc/config/plugin 2>/dev/null || true)
if [ -n "$hotplug_root" ]; then
    rm -f "$hotplug_root/net/$PLUGIN_USER.$PLUGIN_NAME"
fi

case "$SRC_DIR" in
    /nas/pool*/"$PLUGIN_USER"/plugin/pluginsrc/"$PLUGIN_NAME") rm -rf "$SRC_DIR" ;;
    "") ;;
    *) echo "警告：未删除异常的 src 路径：$SRC_DIR" >&2 ;;
esac
case "$TMP_DIR" in
    /nas/pool*/"$PLUGIN_USER"/plugin/plugintmp/"$PLUGIN_NAME") rm -rf "$TMP_DIR" ;;
    "") ;;
    *) echo "警告：未删除异常的 tmp 路径：$TMP_DIR" >&2 ;;
esac
expected_home="/home/$PLUGIN_USER/plugin/mihomo"
[ "$PLUGIN_HOME" = "$expected_home" ] || fail "插件目录安全校验失败：$PLUGIN_HOME"
rm -rf "$PLUGIN_HOME"

if ! find /home -path '/home/u*/plugin/mihomo' -type d 2>/dev/null | grep -q .; then
    rm -f "/data/plugin/www/icon/$PLUGIN_NAME.icon"
fi

systemctl reload crond.service >/dev/null 2>&1 || true
echo "Mihomo 插件已卸载。"
echo "配置、订阅和手动节点备份保留在：$reserve_dir"
