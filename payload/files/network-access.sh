#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
SRC_DIR=$(dirname "$SCRIPT_DIR")
plugin_user=$(printf '%s\n' "$SRC_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo$#\1#p')
[ -n "$plugin_user" ] || plugin_user=$(id -un)

PLUGIN_HOME=${PLUG_HOME_DIR:-/home/$plugin_user/plugin/mihomo}
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
BIN="$SCRIPT_DIR/mihomo"
CONTROL="$PLUGIN_HOME/scripts/control"
CONFIG_FILE="$ETC_DIR/config.yaml"

config_tmp=""
test_log=""

cleanup() {
    [ -n "$config_tmp" ] && rm -f "$config_tmp"
    [ -n "$test_log" ] && rm -f "$test_log"
    return 0
}
trap cleanup EXIT HUP INT TERM

json_error() {
    jq -n --arg message "$1" '{ok:false,error:$message}'
    exit 0
}

control_command() (
    control_action=$1
    [ ! -e "/proc/$$/fd/9" ] || exec 9>&-
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" "$control_action"
)

do_status() {
    allow_lan=$(sed -n 's/^allow-lan:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$CONFIG_FILE" | head -n 1)
    bind_address=$(sed -n 's/^bind-address:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$CONFIG_FILE" | tr -d "\"'" | head -n 1)
    mixed_port=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_FILE" | head -n 1)
    access_mode=local
    if [ "$allow_lan" = "true" ] && [ "$bind_address" != "127.0.0.1" ] && [ "$bind_address" != "localhost" ]; then
        access_mode=lan
    fi
    jq -n --arg mode "$access_mode" --arg bindAddress "${bind_address:-127.0.0.1}" --arg port "${mixed_port:-7890}" \
        --arg allowLan "${allow_lan:-false}" \
        '{ok:true,mode:$mode,bindAddress:$bindAddress,allowLan:($allowLan == "true"),port:($port|tonumber)}'
}

do_set() {
    access_mode=${1:-}
    case "$access_mode" in local|lan) ;; *) json_error "不支持的访问范围" ;; esac
    [ -s "$CONFIG_FILE" ] || json_error "配置文件不存在"
    mkdir -p "$VAR_DIR"
    exec 9>"$VAR_DIR/network-access.lock"
    flock -n 9 || json_error "另一个网络访问设置正在进行"
    umask 077
    config_tmp="$VAR_DIR/config.network-access.$$"
    test_log="$VAR_DIR/network-access-test.$$"
    awk -v mode="$access_mode" '
        BEGIN { seen_allow=0; seen_bind=0 }
        /^allow-lan:[[:space:]]*/ {
            print (mode == "lan" ? "allow-lan: true" : "allow-lan: false")
            seen_allow=1
            next
        }
        /^bind-address:[[:space:]]*/ {
            print (mode == "lan" ? "bind-address: 0.0.0.0" : "bind-address: 127.0.0.1")
            seen_bind=1
            next
        }
        { print }
        END {
            if (!seen_allow) print (mode == "lan" ? "allow-lan: true" : "allow-lan: false")
            if (!seen_bind) print (mode == "lan" ? "bind-address: 0.0.0.0" : "bind-address: 127.0.0.1")
        }
    ' "$CONFIG_FILE" > "$config_tmp" || json_error "生成网络访问配置失败"
    chmod 0600 "$config_tmp"
    if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
        json_error "网络访问配置无法通过 Mihomo 校验"
    fi

    cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    mv -f "$config_tmp" "$CONFIG_FILE"
    config_tmp=""
    chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    was_running=false
    control_command status >/dev/null 2>&1 && was_running=true
    if [ "$was_running" = "true" ] && ! control_command restart >/dev/null 2>&1; then
        cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
        control_command restart >/dev/null 2>&1 || true
        json_error "切换后 Mihomo 启动失败，已恢复原配置"
    fi
    jq -n --arg mode "$access_mode" --argjson restarted "$was_running" \
        '{ok:true,mode:$mode,restarted:$restarted}'
}

case "${1:-status}" in
    status) do_status ;;
    set) do_set "${2:-}" ;;
    *) json_error "未知网络访问操作" ;;
esac
