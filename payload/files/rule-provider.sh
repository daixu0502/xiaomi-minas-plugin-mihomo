#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
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
EDITOR="$SCRIPT_DIR/rule_provider_editor.py"
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

. "$SCRIPT_DIR/update-common.sh"

do_import() {
    operation_lock
    task_progress generating 15 "正在生成规则提供者配置"
    request_body=$(cat)
    printf '%s' "$request_body" | jq empty >/dev/null 2>&1 || json_error "规则提供者参数不是有效 JSON"
    provider_name=$(printf '%s' "$request_body" | jq -r '.name // empty')
    provider_url=$(printf '%s' "$request_body" | jq -r '.url // empty')
    provider_behavior=$(printf '%s' "$request_body" | jq -r '.behavior // empty')
    provider_format=$(printf '%s' "$request_body" | jq -r '.format // empty')
    provider_action=$(printf '%s' "$request_body" | jq -r '.target // empty')
    provider_via=$(printf '%s' "$request_body" | jq -r '.via // "PROXY"')

    case "$provider_name" in
        ''|*[!A-Za-z0-9_.-]*) json_error "名称只能包含字母、数字、点、下划线和短横线" ;;
    esac
    [ "${#provider_name}" -le 64 ] || json_error "规则提供者名称不能超过 64 个字符"
    case "$provider_name" in [A-Za-z0-9]*) ;; *) json_error "规则提供者名称必须以字母或数字开头" ;; esac
    [ "${#provider_url}" -le 4096 ] || json_error "规则 URL 过长"
    case "$provider_url" in https://*) ;; *) json_error "规则 URL 必须使用 HTTPS" ;; esac
    case "$provider_url" in *[[:space:]]*) json_error "规则 URL 不能包含空白字符" ;; esac
    case "$provider_behavior" in domain|ipcidr|classical) ;; *) json_error "不支持的规则行为" ;; esac
    case "$provider_format" in yaml|mrs) ;; *) json_error "不支持的规则格式" ;; esac
    case "$provider_action" in PROXY|DIRECT|REJECT) ;; *) json_error "不支持的匹配动作" ;; esac
    case "$provider_via" in PROXY|DIRECT) ;; *) json_error "不支持的下载通道" ;; esac
    [ -s "$CONFIG_FILE" ] || json_error "配置文件不存在"

    mkdir -p "$VAR_DIR" "$ETC_DIR/rules"
    exec 9>"$RUNTIME_DIR/rule-provider.lock"
    flock -n 9 || json_error "另一个规则提供者操作正在进行"
    umask 077
    config_tmp="$RUNTIME_DIR/config.rule-provider.$$"
    test_log="$RUNTIME_DIR/rule-provider-test.$$"
    if ! python3 "$EDITOR" "$CONFIG_FILE" "$config_tmp" "$provider_name" "$provider_url" \
        "$provider_behavior" "$provider_format" "$provider_action" "$provider_via"; then
        json_error "生成规则提供者配置失败"
    fi
    chmod 0600 "$config_tmp"
    task_progress validating 45 "正在校验规则提供者配置"
    if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
        json_error "规则提供者配置无法通过 Mihomo 校验；请确认 PROXY 策略组和 URL 可用"
    fi

    cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    python3 -B "$PLUGIN_HOME/src/files/plugin_paths.py" --publish "$config_tmp" "$CONFIG_FILE"
    config_tmp=""
    chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    if ! activation=$(hot_apply config); then
        cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
        hot_apply config >/dev/null 2>&1 || true
        hot_error=$(printf '%s' "$activation" | jq -r '.error // "内核接口不可用"')
        json_error "规则提供者热加载失败，已恢复原配置：$hot_error"
    fi
    source_host=$(printf '%s' "$provider_url" | sed -n 's#^https://\([^/?#]*\).*#https://\1#p')
    jq -n --arg name "$provider_name" --arg source "$source_host" --arg target "$provider_action" \
        '{ok:true,imported:true,name:$name,source:$source,target:$target,restarted:false}'
}

case "${1:-}" in
    import) do_import ;;
    *) json_error "未知规则提供者操作" ;;
esac
