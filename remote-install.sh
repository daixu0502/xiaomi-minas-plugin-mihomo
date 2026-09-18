#!/bin/sh
set -eu

PLUGIN_USER="${1:-u103868178}"
PLUGIN_NAME="mihomo"
PLUGIN_VERSION="1.7.6"
CORE_VERSION="v1.19.31"
BUNDLE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PAYLOAD_DIR="$BUNDLE_DIR/payload"

fail() {
    echo "错误：$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "远端安装器必须以 root 身份运行"
case "$PLUGIN_USER" in
    u*) ;;
    *) fail "无效插件用户：$PLUGIN_USER" ;;
esac
case "${PLUGIN_USER#u}" in
    ''|*[!0-9]*) fail "无效插件用户：$PLUGIN_USER" ;;
esac
id "$PLUGIN_USER" >/dev/null 2>&1 || fail "设备上不存在用户 $PLUGIN_USER"

for command_name in jq sha256sum plugincenter runuser flock curl openssl python3 file cmp sudo systemctl ss visudo sort grep tail; do
    command -v "$command_name" >/dev/null 2>&1 || fail "设备上缺少命令 $command_name"
done

CORE_FILE="$PAYLOAD_DIR/files/mihomo"
[ -x "$CORE_FILE" ] || fail "安装包中缺少 ARM64 Mihomo 核心"
core_arch=$(file "$CORE_FILE" 2>/dev/null || true)
case "$core_arch" in
    *ARM*aarch64*|*ARM64*) ;;
    *) fail "Mihomo 核心不是 ARM64 ELF：$core_arch" ;;
esac

USER_HOME="/home/$PLUGIN_USER"
PLUGIN_ROOT="$USER_HOME/plugin"
PLUGIN_HOME="$PLUGIN_ROOT/$PLUGIN_NAME"

existing_src=""
if [ -L "$PLUGIN_HOME/src" ]; then
    existing_src=$(readlink "$PLUGIN_HOME/src" 2>/dev/null || true)
fi
case "$existing_src" in
    */"$PLUGIN_USER"/plugin/pluginsrc/"$PLUGIN_NAME")
        POOL_PLUGIN_ROOT=${existing_src%/pluginsrc/$PLUGIN_NAME}
        ;;
    *)
        POOL_PLUGIN_ROOT="/nas/pool0/$PLUGIN_USER/plugin"
        ;;
esac

[ -d "$(dirname "$POOL_PLUGIN_ROOT")" ] || fail "未找到用户存储池目录：$(dirname "$POOL_PLUGIN_ROOT")"

SRC_PARENT="$POOL_PLUGIN_ROOT/pluginsrc"
TMP_PARENT="$POOL_PLUGIN_ROOT/plugintmp"
SRC_DIR="$SRC_PARENT/$PLUGIN_NAME"
TMP_DIR="$TMP_PARENT/$PLUGIN_NAME"
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
SCRIPTS_DIR="$PLUGIN_HOME/scripts"
LIST_FILE="/data/plugin/$PLUGIN_USER.list"
WEB_ROOT=$(jq -r '.settings.nginx_plugin // "/data/plugin/www"' /etc/config/plugin)
WEB_USER_DIR="$WEB_ROOT/$PLUGIN_USER"
WEB_LINK="$WEB_USER_DIR/$PLUGIN_NAME"
ICON_DIR="/data/plugin/www/icon"
ICON_FILE="$ICON_DIR/$PLUGIN_NAME.icon"
CRON_FILE="/etc/cron.d/mihomo-plugin-$PLUGIN_USER"
LOCK_FILE="/data/plugin/.$PLUGIN_USER.mihomo.lock"
DOCKER_HELPER="/data/plugin/.mihomo-system/mihomo-docker-proxy"
DOCKER_SUDOERS="/etc/sudoers.d/mihomo-docker-proxy-$PLUGIN_USER"
DOCKER_SUDOERS_LEGACY="/etc/sudoers.d/mihomo-docker-proxy"
PORTS_FILE="$ETC_DIR/ports.env"

[ -f "$LIST_FILE" ] || fail "未找到插件清单：$LIST_FILE"
jq empty "$LIST_FILE" >/dev/null 2>&1 || fail "插件清单不是有效 JSON：$LIST_FILE"

mkdir -p "$PLUGIN_ROOT" "$SRC_PARENT" "$TMP_PARENT" "$PLUGIN_HOME" \
    "$ETC_DIR" "$VAR_DIR" "$SCRIPTS_DIR" "$WEB_USER_DIR" "$ICON_DIR"

if [ -x "$SCRIPTS_DIR/control" ]; then
    PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$SCRIPTS_DIR/control" disable >/dev/null 2>&1 || true
fi

stage_src="$SRC_PARENT/.$PLUGIN_NAME.new.$$"
old_src="$SRC_PARENT/.$PLUGIN_NAME.old.$$"
case "$stage_src" in "$SRC_PARENT"/.*) ;; *) fail "内部暂存路径校验失败" ;; esac
rm -rf "$stage_src"
mkdir -p "$stage_src"
cp -R "$PAYLOAD_DIR/files" "$stage_src/files"
cp -R "$PAYLOAD_DIR/ui" "$stage_src/ui"
cp -R "$PAYLOAD_DIR/system" "$stage_src/system"

core_version_of() {
    candidate_core=$1
    candidate_text=$($candidate_core -v 2>/dev/null || true)
    printf '%s\n' "$candidate_text" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' | head -n 1
}

# A core updated from the APP lives inside SRC_DIR. Keep it when it is newer
# than the core bundled with deploy.sh, so reinstalling the plugin UI never
# silently downgrades a successful in-app core update.
bundled_core_version=$(core_version_of "$stage_src/files/mihomo" || true)
existing_core="$SRC_DIR/files/mihomo"
if [ -x "$existing_core" ] && [ -n "$bundled_core_version" ]; then
    existing_core_arch=$(file "$existing_core" 2>/dev/null || true)
    existing_core_version=$(core_version_of "$existing_core" || true)
    case "$existing_core_arch" in
        *ARM*aarch64*|*ARM64*)
            if [ -n "$existing_core_version" ]; then
                newest_core_version=$(printf '%s\n%s\n' "$bundled_core_version" "$existing_core_version" | sort -V | tail -n 1)
                if [ "$newest_core_version" = "$existing_core_version" ] && [ "$existing_core_version" != "$bundled_core_version" ]; then
                    cp "$existing_core" "$stage_src/files/mihomo"
                    echo "保留 APP 已更新的 Mihomo 核心 $existing_core_version（安装包为 $bundled_core_version）。"
                fi
            fi
            ;;
    esac
fi
chmod 0755 "$stage_src/files/mihomo" "$stage_src/files/"*.sh "$stage_src/ui/mihomo.cgi"
chmod 0755 "$stage_src/system/mihomo-docker-proxy"
chmod 0644 "$stage_src/files/"*.py
chmod 0644 "$stage_src/ui/index.html" "$stage_src/ui/app.js" "$stage_src/ui/client-bridge.js" "$stage_src/ui/style.css" "$stage_src/ui/config"

if [ -d "$SRC_DIR" ] && [ ! -L "$SRC_DIR" ]; then
    mv "$SRC_DIR" "$old_src"
fi
mv "$stage_src" "$SRC_DIR"
if [ -d "$old_src" ]; then
    rm -rf "$old_src"
fi

INSTALLED_CORE_VERSION=$(core_version_of "$SRC_DIR/files/mihomo" || true)
[ -n "$INSTALLED_CORE_VERSION" ] || INSTALLED_CORE_VERSION="$CORE_VERSION"

cp "$PAYLOAD_DIR/scripts/control" "$SCRIPTS_DIR/control"
cp "$PAYLOAD_DIR/scripts/hotplug" "$SCRIPTS_DIR/hotplug"
chmod 0755 "$SCRIPTS_DIR/control" "$SCRIPTS_DIR/hotplug"

if [ ! -s "$ETC_DIR/config.yaml" ]; then
    cp "$PAYLOAD_DIR/etc/config.yaml" "$ETC_DIR/config.yaml"
fi
if [ ! -s "$ETC_DIR/api.secret" ]; then
    umask 077
    openssl rand -hex 32 > "$ETC_DIR/api.secret"
fi

port_in_use() {
    ss -lntH 2>/dev/null | awk -v suffix=":$1" '$4 ~ suffix "$" {found=1} END {exit !found}'
}
port_reserved() {
    for reserved_file in /home/u*/plugin/mihomo/etc/ports.env; do
        [ -f "$reserved_file" ] || continue
        [ "$reserved_file" = "$PORTS_FILE" ] && continue
        grep -Eq "^(MIXED_PORT|CONTROLLER_PORT)=$1$" "$reserved_file" && return 0
    done
    return 1
}
valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}
MIXED_PORT=""
CONTROLLER_PORT=""
exec 8>/data/plugin/.mihomo-ports.lock
flock -x 8
if [ -s "$PORTS_FILE" ]; then
    saved_mixed=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" | head -n 1)
    saved_controller=$(sed -n 's/^CONTROLLER_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" | head -n 1)
    if valid_port "$saved_mixed" && valid_port "$saved_controller" && ! port_in_use "$saved_mixed" && ! port_in_use "$saved_controller" && ! port_reserved "$saved_mixed" && ! port_reserved "$saved_controller"; then
        MIXED_PORT="$saved_mixed"
        CONTROLLER_PORT="$saved_controller"
    fi
fi
if [ -z "$MIXED_PORT" ]; then
    config_mixed=$(sed -n 's/^[[:space:]]*mixed-port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$ETC_DIR/config.yaml" | head -n 1)
    if valid_port "$config_mixed" && ! port_in_use "$config_mixed" && ! port_in_use 9090 && ! port_reserved "$config_mixed" && ! port_reserved 9090; then
        MIXED_PORT="$config_mixed"
        CONTROLLER_PORT=9090
    fi
fi
offset=0
while [ -z "$MIXED_PORT" ] && [ "$offset" -lt 100 ]; do
    candidate_mixed=$((7890+offset)); candidate_controller=$((9090+offset))
    if ! port_in_use "$candidate_mixed" && ! port_in_use "$candidate_controller" && ! port_reserved "$candidate_mixed" && ! port_reserved "$candidate_controller"; then
        MIXED_PORT="$candidate_mixed"; CONTROLLER_PORT="$candidate_controller"
    fi
    offset=$((offset+1))
done
[ -n "$MIXED_PORT" ] || fail "无法在 7890-7989 与 9090-9189 中分配 Mihomo 端口"
ports_tmp="$ETC_DIR/.ports.env.$$"
printf 'MIXED_PORT=%s\nCONTROLLER_PORT=%s\n' "$MIXED_PORT" "$CONTROLLER_PORT" > "$ports_tmp"
mv -f "$ports_tmp" "$PORTS_FILE"
flock -u 8
config_tmp="$ETC_DIR/.config.ports.$$"
awk -v port="$MIXED_PORT" 'BEGIN{seen=0} /^[[:space:]]*mixed-port:[[:space:]]*/{print "mixed-port: " port;seen=1;next}{print} END{if(!seen)print "mixed-port: " port}' "$ETC_DIR/config.yaml" > "$config_tmp"
mv -f "$config_tmp" "$ETC_DIR/config.yaml"
chmod 0600 "$ETC_DIR/config.yaml" "$ETC_DIR/api.secret" "$PORTS_FILE"

rm -f "$PLUGIN_HOME/src" "$PLUGIN_HOME/tmp"
ln -s "$SRC_DIR" "$PLUGIN_HOME/src"
mkdir -p "$TMP_DIR"
ln -s "$TMP_DIR" "$PLUGIN_HOME/tmp"

digest_file="$TMP_DIR/digest.$$"
find "$SRC_DIR/" -type f | LC_ALL=C sort | while IFS= read -r source_file; do
    sha256sum "$source_file" | cut -d ' ' -f 1
done > "$digest_file"
abstract=$(sha256sum "$digest_file" | cut -d ' ' -f 1)
rm -f "$digest_file"
plugin_size=$(du -sk "$SRC_DIR" | awk '{print $1 * 1024}')
timestamp=$(date +%s)

info_tmp="$TMP_DIR/INFO.$$"
jq -n \
    --arg plugin "$PLUGIN_NAME" \
    --arg version "$PLUGIN_VERSION" \
    --arg core_version "$INSTALLED_CORE_VERSION" \
    --arg controller_port "$CONTROLLER_PORT" \
    --arg abstract "$abstract" \
    --argjson timestamp "$timestamp" \
    --argjson size "$plugin_size" \
    '{
      plugin:$plugin,
      name:"Mihomo",
      id:19090,
      version:$version,
      tags:["tool"],
      timestamp:$timestamp,
      desc:("Mihomo " + $core_version + " 代理管理"),
      developer:"Local / MetaCubeX",
      publisher:"Local",
      changelog:"修复电脑端底部遮挡并优化按钮和文字尺寸",
      system:false,
      size:$size,
      port:$controller_port,
      type:"standard",
      forceupgrade:false,
      ext:{admin:true},
      hotplug:["net"],
      abstract:$abstract
    }' > "$info_tmp"
mv -f "$info_tmp" "$PLUGIN_HOME/INFO"

rm -f "$WEB_LINK"
ln -s "$SRC_DIR/ui" "$WEB_LINK"
if ! python3 "$PAYLOAD_DIR/make_icon.py" "$ICON_FILE"; then
    cp "$PAYLOAD_DIR/icon.svg" "$ICON_FILE"
    echo "警告：PNG 图标生成失败，已使用 SVG 备用图标。" >&2
fi
chmod 0644 "$ICON_FILE"

entry_file="$TMP_DIR/list-entry.$$"
jq -n \
    --slurpfile frontend "$SRC_DIR/ui/config" \
    --slurpfile info "$PLUGIN_HOME/INFO" \
    --argjson now "$timestamp" \
    '{
      resource:{mpk:"",icon:"",preview:null},
      status:"stopped",
      install:true,
      upgrade:false,
      enable:true,
      changetime:$now,
      icon:"/icon/mihomo.icon",
      progress:"100",
      frontend:$frontend[0],
      info:($info[0] | del(.abstract)),
      online:true
    }' > "$entry_file"

exec 9>"$LOCK_FILE"
flock -x 9
list_tmp="$LIST_FILE.mihomo.$$"
backup_file="$LIST_FILE.pre-mihomo.$timestamp"
cp -p "$LIST_FILE" "$backup_file"
jq --slurpfile entry "$entry_file" '.mihomo = $entry[0]' "$LIST_FILE" > "$list_tmp"
jq empty "$list_tmp" >/dev/null
chmod --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || chmod 0644 "$list_tmp"
chown --reference="$LIST_FILE" "$list_tmp" 2>/dev/null || chown "$PLUGIN_USER:$PLUGIN_USER" "$list_tmp"
mv -f "$list_tmp" "$LIST_FILE"
rm -f "$entry_file"
flock -u 9

hotplug_root=$(jq -r '.settings.system_hotplug // empty' /etc/config/plugin)
if [ -n "$hotplug_root" ] && [ -d "$hotplug_root/net" ]; then
    hotplug_link="$hotplug_root/net/$PLUGIN_USER.$PLUGIN_NAME"
    rm -f "$hotplug_link"
    ln -s "$SCRIPTS_DIR/hotplug" "$hotplug_link"
fi

cron_tmp="/etc/cron.d/.mihomo-plugin-$PLUGIN_USER.$$"
{
    echo 'SHELL=/bin/sh'
    echo 'PATH=/usr/sbin:/usr/bin:/sbin:/bin'
    echo 'MAILTO=""'
    echo
    echo '# Storage is mounted late; repair registration and start after plugin paths are ready.'
    printf '@reboot root /bin/sh -c '\''sleep 60; /bin/sh %s/files/boot.sh %s'\''\n' \
        "$SRC_DIR" "$PLUGIN_USER"
} > "$cron_tmp"
chmod 0644 "$cron_tmp"
mv -f "$cron_tmp" "$CRON_FILE"
if [ -f /etc/cron.d/mihomo-plugin ] && grep -Fq "boot.sh $PLUGIN_USER" /etc/cron.d/mihomo-plugin; then
    rm -f /etc/cron.d/mihomo-plugin
fi
systemctl reload crond.service >/dev/null 2>&1 || true

chown -R "$PLUGIN_USER:$PLUGIN_USER" "$PLUGIN_HOME" "$SRC_DIR" "$TMP_DIR"
chown -h "$PLUGIN_USER:$PLUGIN_USER" "$PLUGIN_HOME/src" "$PLUGIN_HOME/tmp" "$WEB_LINK"
chmod 0700 "$PLUGIN_HOME" "$SRC_DIR" "$TMP_DIR"
chmod 0755 "$SRC_DIR/ui"

mkdir -p /data/plugin/.mihomo-system /etc/sudoers.d
chown root:root /data/plugin/.mihomo-system
chmod 0755 /data/plugin/.mihomo-system
docker_helper_tmp="$DOCKER_HELPER.new.$$"
docker_sudoers_tmp="$DOCKER_SUDOERS.new.$$"
cp "$PAYLOAD_DIR/system/mihomo-docker-proxy" "$docker_helper_tmp"
chown root:root "$docker_helper_tmp"
chmod 0755 "$docker_helper_tmp"
printf '%s ALL=(root) NOPASSWD: %s status %s, %s enable %s, %s disable %s\n' \
    "$PLUGIN_USER" "$DOCKER_HELPER" "$MIXED_PORT" "$DOCKER_HELPER" "$MIXED_PORT" "$DOCKER_HELPER" "$MIXED_PORT" > "$docker_sudoers_tmp"
chown root:root "$docker_sudoers_tmp"
chmod 0440 "$docker_sudoers_tmp"
visudo -cf "$docker_sudoers_tmp" >/dev/null 2>&1 || fail "Docker 代理 sudoers 规则校验失败"
mv -f "$docker_helper_tmp" "$DOCKER_HELPER"
mv -f "$docker_sudoers_tmp" "$DOCKER_SUDOERS"
if [ -f "$DOCKER_SUDOERS_LEGACY" ] && grep -q "^$PLUGIN_USER[[:space:]]" "$DOCKER_SUDOERS_LEGACY"; then
    rm -f "$DOCKER_SUDOERS_LEGACY"
fi

start_ok=0
if runuser -u "$PLUGIN_USER" -- /usr/bin/env \
    PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$SCRIPTS_DIR/control" status >/dev/null 2>&1; then
    start_ok=1
else
    if runuser -u "$PLUGIN_USER" -- /usr/bin/env \
        PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
        PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$SCRIPTS_DIR/control" enable; then
        start_ok=1
    fi
fi

# Start under the plugin user's clean environment first. Some firmware builds
# inject state into plugincenter's control environment that can break the
# loopback Controller health check even though Mihomo is already listening.
# Register with plugincenter only after the process has passed its own check;
# at that point enable is idempotent because the runner detects the live PID.
if [ "$start_ok" = "1" ]; then
    plugincenter -u "$PLUGIN_USER" -p "$PLUGIN_NAME" enable >/dev/null 2>&1 || true
fi

if [ "$start_ok" != "1" ]; then
    fail "插件文件已安装，但 Mihomo 启动失败；请查看 $VAR_DIR/mihomo.log"
fi

sleep 1
if ! runuser -u "$PLUGIN_USER" -- /usr/bin/env \
    PLUG_USER="$PLUGIN_USER" PLUG_NAME="$PLUGIN_NAME" \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$SCRIPTS_DIR/control" status >/dev/null 2>&1; then
    fail "Mihomo 进程未保持运行；请查看 $VAR_DIR/mihomo.log"
fi

list_running="$LIST_FILE.mihomo-status.$$"
jq --argjson now "$(date +%s)" \
   '.mihomo.status="running" | .mihomo.enable=true | .mihomo.changetime=$now' \
   "$LIST_FILE" > "$list_running"
chmod --reference="$LIST_FILE" "$list_running" 2>/dev/null || chmod 0644 "$list_running"
chown --reference="$LIST_FILE" "$list_running" 2>/dev/null || chown "$PLUGIN_USER:$PLUGIN_USER" "$list_running"
mv -f "$list_running" "$LIST_FILE"

echo "Mihomo $INSTALLED_CORE_VERSION 已启动。"
echo "APP 插件清单：$LIST_FILE"
echo "配置文件：$ETC_DIR/config.yaml"
echo "代理端口：$MIXED_PORT；控制端口：$CONTROLLER_PORT"
echo "运行日志：$VAR_DIR/mihomo.log"
echo "清单安装前备份：$backup_file"
