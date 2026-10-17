#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SRC_DIR=$(dirname "$SCRIPT_DIR")
plugin_user=$(printf '%s\n' "$SRC_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo$#\1#p')
[ -n "$plugin_user" ] || plugin_user=$(id -un)

PLUGIN_HOME=${PLUG_HOME_DIR:-/home/$plugin_user/plugin/mihomo}
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
RUNTIME_DIR=$(python3 -B "$PLUGIN_HOME/src/files/plugin_paths.py" "$PLUGIN_HOME") || exit 1
export TMPDIR="$RUNTIME_DIR"
BIN="$SCRIPT_DIR/mihomo"
# Runtime updates must never replace files covered by INFO.abstract.
[ ! -x "$VAR_DIR/core/mihomo" ] || BIN="$VAR_DIR/core/mihomo"
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

. "$SCRIPT_DIR/update-common.sh"

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
    raw_tmp="$RUNTIME_DIR/subscription.raw.$$"
    provider_tmp="$RUNTIME_DIR/subscription.provider.$$"
    download_log="$RUNTIME_DIR/subscription-download.$$"

    task_progress downloading 12 "正在下载订阅（有限超时与重试）"
    download_code=0
    download_http=$(curl --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 8 --max-time 40 --retry 1 --retry-delay 1 --retry-max-time 45 \
        --noproxy '*' --write-out '%{http_code}' \
        --user-agent 'clash.meta/v1.19.31' \
        --output "$raw_tmp" -- "$subscription_url" 2> "$download_log") || download_code=$?
    [ "$download_code" = 0 ] || download_failure "$download_code" "$download_http" "订阅下载失败"
    task_progress parsing 42 "下载完成，正在提取节点"
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
    provider_backup="$RUNTIME_DIR/subscription.provider.backup.$$"
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
    python3 -B "$PLUGIN_HOME/src/files/plugin_paths.py" --publish "$provider_tmp" "$PROVIDER_FILE"
    provider_tmp=""
    chmod 0600 "$PROVIDER_FILE"
}

write_metadata() {
    subscription_url=$1
    source_host=$(printf '%s' "$subscription_url" | sed -n 's#^https://\([^/?#]*\).*#https://\1#p')
    updated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
    proxy_count=$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" 2>/dev/null || true)
    meta_tmp="$RUNTIME_DIR/subscription.meta.$$"
    jq -n \
        --arg source "$source_host" \
        --arg updatedAt "$updated_at" \
        --argjson proxyCount "${proxy_count:-0}" \
        '{source:$source,updatedAt:$updatedAt,proxyCount:$proxyCount}' > "$meta_tmp"
    python3 -B "$PLUGIN_HOME/src/files/plugin_paths.py" --publish "$meta_tmp" "$META_FILE"
    meta_tmp=""
    chmod 0600 "$META_FILE"
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
    operation_lock
    subscription_url=$(cat)
    validate_url "$subscription_url"
    download_provider "$subscription_url"
    ensure_empty_provider "$MANUAL_FILE"

    config_tmp="$RUNTIME_DIR/config.subscription.$$"
    test_log="$RUNTIME_DIR/subscription-test.$$"
    task_progress validating 62 "正在校验订阅节点与受管配置"
    write_managed_config "$config_tmp" "$provider_tmp" "$MANUAL_FILE"
    chmod 0600 "$config_tmp"

    if ! "$BIN" -t -d "$PLUGIN_HOME" -f "$config_tmp" > "$test_log" 2>&1; then
        json_error "订阅节点无法通过 Mihomo 校验，原配置未修改"
    fi

    if [ ! -f "$BEFORE_FILE" ]; then
        cp "$CONFIG_FILE" "$BEFORE_FILE"
        chmod 0600 "$BEFORE_FILE"
    fi
    cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    activate_candidate_provider
    write_managed_config "$config_tmp"
    python3 -B "$PLUGIN_HOME/src/files/plugin_paths.py" --publish "$config_tmp" "$CONFIG_FILE"
    config_tmp=""
    chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"

    if ! activation=$(hot_apply config); then
        cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
        restore_provider
        hot_apply config >/dev/null 2>&1 || true
        hot_error=$(printf '%s' "$activation" | jq -r '.error // "内核接口不可用"')
        json_error "订阅热加载失败，已恢复原配置：$hot_error"
    fi

    printf '%s\n' "$subscription_url" > "$URL_FILE"
    chmod 0600 "$URL_FILE"
    write_metadata "$subscription_url"
    jq -n --argjson count "$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" || true)" \
        '{ok:true,imported:true,proxyCount:$count,restarted:false}'
}

do_update() {
    operation_lock
    [ -s "$URL_FILE" ] || json_error "尚未保存订阅 URL，请先导入"
    subscription_url=$(tr -d '\r\n' < "$URL_FILE")
    validate_url "$subscription_url"
    download_provider "$subscription_url"
    test_log="$RUNTIME_DIR/subscription-test.$$"
    if [ -f "$PROVIDER_FILE" ] && cmp -s "$provider_tmp" "$PROVIDER_FILE"; then
        write_metadata "$subscription_url"
        jq -n --argjson count "$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" || true)" \
            '{ok:true,updated:true,unchanged:true,proxyCount:$count,restarted:false}'
        return
    fi

    task_progress validating 65 "正在校验新节点，旧节点继续运行"
    if ! "$BIN" -t -d "$ETC_DIR" -f "$provider_tmp" > "$test_log" 2>&1; then
        json_error "更新后的订阅无法通过 Mihomo 校验，已保留旧节点"
    fi
    activate_candidate_provider
    if ! activation=$(hot_apply subscription); then
        restore_provider
        hot_apply subscription >/dev/null 2>&1 || true
        hot_error=$(printf '%s' "$activation" | jq -r '.error // "内核接口不可用"')
        json_error "节点热更新失败，已恢复旧节点：$hot_error"
    fi

    write_metadata "$subscription_url"
    jq -n --argjson count "$(grep -Ec '^[[:space:]]*-[[:space:]]' "$PROVIDER_FILE" || true)" \
        '{ok:true,updated:true,proxyCount:$count,restarted:false}'
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
