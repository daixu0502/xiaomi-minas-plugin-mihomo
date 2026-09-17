#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SRC_DIR=$(dirname "$SCRIPT_DIR")
plugin_user=$(printf '%s\n' "$SRC_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo$#\1#p')
[ -n "$plugin_user" ] || plugin_user=$(id -un)

PLUGIN_HOME=${PLUG_HOME_DIR:-/home/$plugin_user/plugin/mihomo}
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
BIN="$SCRIPT_DIR/mihomo"
CONTROL="$PLUGIN_HOME/scripts/control"
CONFIG_FILE="$ETC_DIR/config.yaml"
URL_FILE="$ETC_DIR/subscription.url"
META_FILE="$ETC_DIR/subscription.meta.json"
PROVIDER_DIR="$ETC_DIR/providers"
PROVIDER_FILE="$PROVIDER_DIR/app-subscription.yaml"
MANUAL_FILE="$PROVIDER_DIR/app-manual.yaml"
BEFORE_FILE="$ETC_DIR/config.before-subscription.yaml"

. "$SCRIPT_DIR/config-tools.sh"

raw_tmp=""
provider_tmp=""
provider_backup=""
config_tmp=""
test_log=""
download_log=""
meta_tmp=""

cleanup() {
    for cleanup_file in "$raw_tmp" "$provider_tmp" "$provider_backup" "$config_tmp" "$test_log" "$download_log" "$meta_tmp"; do
        [ -n "$cleanup_file" ] && rm -f "$cleanup_file"
    done
    return 0
}
trap cleanup EXIT HUP INT TERM

json_error() {
    jq -n --arg message "$1" '{ok:false,error:$message}'
    exit 0
}

validate_url() {
    candidate=$1
    [ -n "$candidate" ] || json_error "订阅 URL 不能为空"
    [ "${#candidate}" -le 4096 ] || json_error "订阅 URL 过长"
    case "$candidate" in
        https://*) ;;
        *) json_error "订阅 URL 必须使用 HTTPS" ;;
    esac
    case "$candidate" in
        *[[:space:]]*) json_error "订阅 URL 不能包含空白字符" ;;
    esac
}

download_provider() {
    subscription_url=$1
    mkdir -p "$VAR_DIR" "$PROVIDER_DIR"
    umask 077
    raw_tmp="$VAR_DIR/subscription.raw.$$"
    provider_tmp="$VAR_DIR/subscription.provider.$$"
    download_log="$VAR_DIR/subscription-download.$$"

    if ! curl --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 90 --retry 2 \
        --user-agent 'clash.meta/v1.19.31' \
        --output "$raw_tmp" -- "$subscription_url" > "$download_log" 2>&1; then
        json_error "订阅下载失败，请检查 URL、网络或订阅状态"
    fi
    [ -s "$raw_tmp" ] || json_error "订阅返回内容为空"
    [ "$(wc -c < "$raw_tmp")" -le 10485760 ] || json_error "订阅内容超过 10 MiB"

    # A Clash-format subscription may contain a complete configuration.
    # Keep only its top-level proxies section so it can be used as a provider.
    if ! awk '
        BEGIN { found=0; block=0 }
        !found && /^proxies:[[:space:]]*/ {
            print
            found=1
            if ($0 ~ /^proxies:[[:space:]]*(#.*)?$/) block=1
            next
        }
        found && block {
            if ($0 ~ /^[^[:space:]#][^:]*:/) exit
            print
        }
        END { if (!found) exit 42 }
    ' "$raw_tmp" > "$provider_tmp"; then
        json_error "订阅不是 Clash YAML，或缺少顶层 proxies 节点列表"
    fi

    if ! grep -Eq '^proxies:.*\[|^[[:space:]]*-[[:space:]]' "$provider_tmp"; then
        json_error "订阅中没有可导入的代理节点"
    fi
    chmod 0600 "$provider_tmp"
}

backup_provider() {
    provider_backup="$VAR_DIR/subscription.provider.backup.$$"
    if [ -f "$PROVIDER_FILE" ]; then
        cp "$PROVIDER_FILE" "$provider_backup"
    fi
}

restore_provider() {
    if [ -s "$provider_backup" ]; then
        cp "$provider_backup" "$PROVIDER_FILE"
        chmod 0600 "$PROVIDER_FILE"
    else
        rm -f "$PROVIDER_FILE"
    fi
}

activate_candidate_provider() {
    backup_provider
    mv -f "$provider_tmp" "$PROVIDER_FILE"
    provider_tmp=""
    chmod 0600 "$PROVIDER_FILE"
}

write_metadata() {
    subscription_url=$1
    source_host=$(printf '%s' "$subscription_url" | sed -n 's#^https://\([^/?#]*\).*#https://\1#p')
    updated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
    proxy_count=$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" 2>/dev/null || true)
    meta_tmp="$VAR_DIR/subscription.meta.$$"
    jq -n \
        --arg source "$source_host" \
        --arg updatedAt "$updated_at" \
        --argjson proxyCount "${proxy_count:-0}" \
        '{source:$source,updatedAt:$updatedAt,proxyCount:$proxyCount}' > "$meta_tmp"
    mv -f "$meta_tmp" "$META_FILE"
    meta_tmp=""
    chmod 0600 "$META_FILE"
}

restart_core() {
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$CONTROL" restart
}

do_status() {
    if [ -s "$URL_FILE" ] && [ -s "$PROVIDER_FILE" ]; then
        if [ -s "$META_FILE" ] && jq empty "$META_FILE" >/dev/null 2>&1; then
            jq '. + {ok:true,configured:true}' "$META_FILE"
        else
            echo '{"ok":true,"configured":true,"source":"","updatedAt":"","proxyCount":0}'
        fi
    else
        echo '{"ok":true,"configured":false,"source":"","updatedAt":"","proxyCount":0}'
    fi
}

do_import() {
    subscription_url=$(cat)
    validate_url "$subscription_url"
    download_provider "$subscription_url"
    ensure_empty_provider "$MANUAL_FILE"
    activate_candidate_provider

    config_tmp="$VAR_DIR/config.subscription.$$"
    test_log="$VAR_DIR/subscription-test.$$"
    write_managed_config "$config_tmp"
    chmod 0600 "$config_tmp"

    if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
        restore_provider
        json_error "订阅节点无法通过 Mihomo 校验，原配置未修改"
    fi

    if [ ! -f "$BEFORE_FILE" ]; then
        cp "$CONFIG_FILE" "$BEFORE_FILE"
        chmod 0600 "$BEFORE_FILE"
    fi
    cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    mv -f "$config_tmp" "$CONFIG_FILE"
    config_tmp=""
    printf '%s\n' "$subscription_url" > "$URL_FILE"
    chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak" "$URL_FILE"

    if ! restart_core >/dev/null 2>&1; then
        cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
        restore_provider
        rm -f "$URL_FILE" "$META_FILE"
        restart_core >/dev/null 2>&1 || true
        json_error "订阅通过校验但核心重启失败，已恢复原配置"
    fi

    write_metadata "$subscription_url"
    jq -n --argjson count "$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" || true)" \
        '{ok:true,imported:true,proxyCount:$count}'
}

do_update() {
    [ -s "$URL_FILE" ] || json_error "尚未保存订阅 URL，请先导入"
    subscription_url=$(tr -d '\r\n' < "$URL_FILE")
    validate_url "$subscription_url"
    download_provider "$subscription_url"
    activate_candidate_provider
    test_log="$VAR_DIR/subscription-test.$$"

    if ! "$BIN" -t -d "$ETC_DIR" -f "$CONFIG_FILE" > "$test_log" 2>&1; then
        restore_provider
        json_error "更新后的订阅无法通过 Mihomo 校验，已保留旧节点"
    fi
    if ! restart_core >/dev/null 2>&1; then
        restore_provider
        restart_core >/dev/null 2>&1 || true
        json_error "更新后核心启动失败，已恢复旧节点"
    fi

    write_metadata "$subscription_url"
    jq -n --argjson count "$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" || true)" \
        '{ok:true,updated:true,proxyCount:$count}'
}

case "${1:-status}" in
    status)
        do_status
        ;;
    import)
        do_import
        ;;
    update)
        do_update
        ;;
    *)
        json_error "未知订阅操作"
        ;;
esac
