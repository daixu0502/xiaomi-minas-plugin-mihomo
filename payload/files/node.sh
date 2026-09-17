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
BEFORE_FILE="$ETC_DIR/config.before-subscription.yaml"
PROVIDER_DIR="$ETC_DIR/providers"
SUBSCRIPTION_FILE="$PROVIDER_DIR/app-subscription.yaml"
MANUAL_FILE="$PROVIDER_DIR/app-manual.yaml"
PARSER="$SCRIPT_DIR/node_parser.py"

. "$SCRIPT_DIR/config-tools.sh"

manual_tmp=""
manual_backup=""
config_tmp=""
config_backup=""
test_log=""
parse_log=""

cleanup() {
    for cleanup_file in "$manual_tmp" "$manual_backup" "$config_tmp" "$config_backup" "$test_log" "$parse_log"; do
        [ -n "$cleanup_file" ] && rm -f "$cleanup_file"
    done
    return 0
}
trap cleanup EXIT HUP INT TERM

json_error() {
    jq -n --arg message "$1" '{ok:false,error:$message}'
    exit 0
}

restart_core() (
    # Keep the operation lock in this script, but never leak fd 9 into the
    # long-running Mihomo process created by control restart.
    [ ! -e "/proc/$$/fd/9" ] || exec 9>&-
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
    PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
    "$CONTROL" restart
)

restore_manual() {
    if [ -s "$manual_backup" ]; then
        cp "$manual_backup" "$MANUAL_FILE"
        chmod 0600 "$MANUAL_FILE"
    else
        rm -f "$MANUAL_FILE"
    fi
}

prepare_change() {
    mkdir -p "$VAR_DIR" "$PROVIDER_DIR"
    umask 077
    exec 9>"$VAR_DIR/manual-node.lock"
    flock -n 9 || json_error "另一个手动节点操作正在进行，请稍后重试"
    manual_backup="$VAR_DIR/manual-node.backup.$$"
    if [ -s "$MANUAL_FILE" ]; then
        cp "$MANUAL_FILE" "$manual_backup"
    fi
    ensure_empty_provider "$MANUAL_FILE"
    ensure_empty_provider "$SUBSCRIPTION_FILE"
}

prepare_config_candidate() {
    config_tmp="$VAR_DIR/config.manual-node.$$"
    if grep -q '^# Managed by the Xiaomi Smart Storage Mihomo plugin' "$CONFIG_FILE" 2>/dev/null \
       && grep -q '^[[:space:]]*APP-MANUAL:' "$CONFIG_FILE" 2>/dev/null; then
        cp "$CONFIG_FILE" "$config_tmp"
    else
        write_managed_config "$config_tmp"
    fi
    chmod 0600 "$config_tmp"
}

validate_and_apply() {
    test_log="$VAR_DIR/manual-node-test.$$"
    if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
        restore_manual
        json_error "节点或受管配置无法通过 Mihomo 校验，未修改现有配置"
    fi

    config_backup="$VAR_DIR/config.manual-node.backup.$$"
    cp "$CONFIG_FILE" "$config_backup"
    if ! cmp -s "$CONFIG_FILE" "$config_tmp"; then
        if [ ! -f "$BEFORE_FILE" ]; then
            cp "$CONFIG_FILE" "$BEFORE_FILE"
            chmod 0600 "$BEFORE_FILE"
        fi
        cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
        mv -f "$config_tmp" "$CONFIG_FILE"
        config_tmp=""
        chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    fi

    if ! restart_core >/dev/null 2>&1; then
        cp "$config_backup" "$CONFIG_FILE"
        restore_manual
        restart_core >/dev/null 2>&1 || true
        json_error "节点通过校验但核心重启失败，已恢复原配置"
    fi
}

do_list() {
    if [ ! -s "$MANUAL_FILE" ] || ! jq empty "$MANUAL_FILE" >/dev/null 2>&1; then
        echo '{"ok":true,"nodes":[]}'
        return
    fi
    jq '{ok:true,nodes:[(.proxies // [])[] | {name:.name,type:.type}]}' "$MANUAL_FILE"
}

do_import() {
    raw_node=$(cat)
    [ -n "$raw_node" ] || json_error "请输入单节点分享链接或 Clash JSON"
    parse_log="$VAR_DIR/manual-node-parse.$$"
    mkdir -p "$VAR_DIR"
    if ! node_json=$(printf '%s' "$raw_node" | python3 "$PARSER" 2> "$parse_log"); then
        parse_error=$(tail -n 1 "$parse_log" 2>/dev/null || true)
        json_error "${parse_error:-单节点格式无效}"
    fi
    node_name=$(printf '%s' "$node_json" | jq -r '.name')
    node_type=$(printf '%s' "$node_json" | jq -r '.type')

    prepare_change
    replaced=false
    if jq -e --arg name "$node_name" 'any((.proxies // [])[]; .name == $name)' "$MANUAL_FILE" >/dev/null 2>&1; then
        replaced=true
    fi
    manual_tmp="$VAR_DIR/manual-node.provider.$$"
    jq --argjson node "$node_json" \
       '.proxies = ((((.proxies // []) | map(select(.name != $node.name)))) + [$node])' \
       "$MANUAL_FILE" > "$manual_tmp"
    mv -f "$manual_tmp" "$MANUAL_FILE"
    manual_tmp=""
    chmod 0600 "$MANUAL_FILE"

    prepare_config_candidate
    validate_and_apply
    jq -n --arg name "$node_name" --arg type "$node_type" --argjson replaced "$replaced" \
        '{ok:true,imported:true,replaced:$replaced,name:$name,type:$type}'
}

do_delete() {
    node_name=$(cat)
    [ -n "$node_name" ] || json_error "缺少节点名称"
    prepare_change
    jq -e --arg name "$node_name" 'any((.proxies // [])[]; .name == $name)' "$MANUAL_FILE" >/dev/null 2>&1 \
        || json_error "没有找到该手动节点"
    manual_tmp="$VAR_DIR/manual-node.provider.$$"
    jq --arg name "$node_name" '.proxies = ((.proxies // []) | map(select(.name != $name)))' \
       "$MANUAL_FILE" > "$manual_tmp"
    mv -f "$manual_tmp" "$MANUAL_FILE"
    manual_tmp=""
    chmod 0600 "$MANUAL_FILE"
    prepare_config_candidate
    validate_and_apply
    jq -n --arg name "$node_name" '{ok:true,deleted:true,name:$name}'
}

case "${1:-list}" in
    list) do_list ;;
    import) do_import ;;
    delete) do_delete ;;
    *) json_error "未知单节点操作" ;;
esac
