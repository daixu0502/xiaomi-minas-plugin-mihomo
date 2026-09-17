#!/bin/sh
set -u

# The Xiaomi plugin gateway executes this CGI through /data/plugin/www, which
# is a symlink to the installed UI directory. Resolve the physical path so
# sibling files (for example files/subscription.sh) are found reliably.
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
plugin_user=$(printf '%s\n' "$SCRIPT_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo/ui$#\1#p')
if [ -z "$plugin_user" ]; then
    plugin_user=$(stat -c '%U' "$0" 2>/dev/null || true)
fi
case "$plugin_user" in u[0-9]*) ;; *) plugin_user=$(id -un) ;; esac

PLUGIN_HOME="/home/$plugin_user/plugin/mihomo"
SRC_DIR=$(dirname "$SCRIPT_DIR")
BIN="$SRC_DIR/files/mihomo"
CONTROL="$PLUGIN_HOME/scripts/control"
SUBSCRIPTION="$SRC_DIR/files/subscription.sh"
NODE_MANAGER="$SRC_DIR/files/node.sh"
CORE_UPDATER="$SRC_DIR/files/core-update.sh"
GEODATA_MANAGER="$SRC_DIR/files/geodata.sh"
NETWORK_ACCESS="$SRC_DIR/files/network-access.sh"
RULE_PROVIDER_MANAGER="$SRC_DIR/files/rule-provider.sh"
DOCKER_PROXY_HELPER="/data/plugin/.mihomo-system/mihomo-docker-proxy"
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
CONFIG_FILE="$ETC_DIR/config.yaml"
SECRET_FILE="$ETC_DIR/api.secret"
PID_FILE="$VAR_DIR/mihomo.pid"
INFO_FILE="$PLUGIN_HOME/INFO"
API_BASE="http://127.0.0.1:9090"

json_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n\r\n'
}

static_header() {
    content_type=$1
    printf 'Content-Type: %s\r\n' "$content_type"
    printf 'Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n'
}

serve_frontend() {
    request_path=${REQUEST_URI:-/index.html}
    request_path=${request_path%%\?*}
    case "$request_path" in
        */app.js)
            static_header 'application/javascript; charset=utf-8'
            cat "$SCRIPT_DIR/app.js"
            ;;
        */style.css)
            static_header 'text/css; charset=utf-8'
            cat "$SCRIPT_DIR/style.css"
            ;;
        *)
            static_header 'text/html; charset=utf-8'
            cat "$SCRIPT_DIR/index.html"
            ;;
    esac
    exit 0
}

json_error() {
    message=$1
    json_header
    jq -n --arg message "$message" '{ok:false,error:$message}'
    exit 0
}

get_action() {
    printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^action=\([A-Za-z0-9_-]*\)$/\1/p' | head -n 1
}

read_json_body() {
    length=${CONTENT_LENGTH:-0}
    case "$length" in *[!0-9]*|'') return 1 ;; esac
    [ "$length" -le 65536 ] || return 2
    dd bs=1 count="$length" 2>/dev/null
}

api_call() {
    method=$1
    path=$2
    body=${3:-}
    [ -s "$SECRET_FILE" ] || return 1
    secret=$(tr -d '\r\n' < "$SECRET_FILE")
    if [ -n "$body" ]; then
        curl --noproxy '*' -fsS --connect-timeout 2 --max-time 20 \
            -X "$method" \
            -H "Authorization: Bearer $secret" \
            -H 'Content-Type: application/json' \
            --data-binary "$body" \
            "$API_BASE$path"
    else
        curl --noproxy '*' -fsS --connect-timeout 2 --max-time 20 \
            -X "$method" \
            -H "Authorization: Bearer $secret" \
            "$API_BASE$path"
    fi
}

is_running() {
    [ -s "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    case "$pid" in *[!0-9]*|'') return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" | grep -F "$BIN" >/dev/null 2>&1
}

require_post() {
    [ "${REQUEST_METHOD:-GET}" = "POST" ] || json_error "此操作只接受 POST"
}

action=$(get_action)

# Xiaomi's plugin gateway dispatches all files under this plugin to the
# plugin-named CGI. Serve the frontend assets here when no API action exists.
if [ -z "$action" ] && [ "${REQUEST_METHOD:-GET}" = "GET" ]; then
    serve_frontend
fi

case "$action" in
    status)
        running=false
        pid_value=""
        if is_running; then
            running=true
            pid_value=$(cat "$PID_FILE")
        fi
        version=$(api_call GET /version 2>/dev/null || echo 'null')
        configs=$(api_call GET /configs 2>/dev/null || echo 'null')
        printf '%s' "$version" | jq empty >/dev/null 2>&1 || version=null
        printf '%s' "$configs" | jq empty >/dev/null 2>&1 || configs=null
        plugin_version=$(jq -r '.version // ""' "$INFO_FILE" 2>/dev/null || true)
        json_header
        jq -n \
            --argjson running "$running" \
            --arg pid "$pid_value" \
            --argjson version "$version" \
            --argjson configs "$configs" \
            --arg pluginVersion "$plugin_version" \
            '{ok:true,running:$running,pid:$pid,version:$version,configs:$configs,pluginVersion:$pluginVersion}'
        ;;
    proxies)
        response=$(api_call GET /proxies 2>/dev/null) || json_error "无法连接 Mihomo 控制端"
        json_header
        printf '%s\n' "$response"
        ;;
    providers)
        response=$(api_call GET /providers/proxies 2>/dev/null) || json_error "无法读取代理提供者"
        json_header
        printf '%s\n' "$response"
        ;;
    rule_providers)
        response=$(api_call GET /providers/rules 2>/dev/null) || json_error "无法读取规则提供者"
        json_header
        printf '%s\n' "$response"
        ;;
    set_mode)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        mode=$(printf '%s' "$body" | jq -r '.mode // empty' 2>/dev/null || true)
        case "$mode" in rule|global|direct) ;; *) json_error "不支持的运行模式" ;; esac
        payload=$(jq -n --arg mode "$mode" '{mode:$mode}')
        api_call PATCH /configs "$payload" >/dev/null 2>&1 || json_error "模式切换失败"
        json_header
        jq -n --arg mode "$mode" '{ok:true,mode:$mode}'
        ;;
    select_proxy)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        group=$(printf '%s' "$body" | jq -r '.group // empty' 2>/dev/null || true)
        node=$(printf '%s' "$body" | jq -r '.node // empty' 2>/dev/null || true)
        [ -n "$group" ] && [ -n "$node" ] || json_error "缺少策略组或节点"
        encoded_group=$(jq -nr --arg value "$group" '$value | @uri')
        payload=$(jq -n --arg name "$node" '{name:$name}')
        api_call PUT "/proxies/$encoded_group" "$payload" >/dev/null 2>&1 || json_error "节点切换失败"
        json_header
        jq -n --arg group "$group" --arg node "$node" '{ok:true,group:$group,node:$node}'
        ;;
    update_provider)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        provider=$(printf '%s' "$body" | jq -r '.provider // empty' 2>/dev/null || true)
        [ -n "$provider" ] || json_error "缺少代理提供者名称"
        encoded_provider=$(jq -nr --arg value "$provider" '$value | @uri')
        api_call PUT "/providers/proxies/$encoded_provider" >/dev/null 2>&1 || json_error "代理提供者更新失败"
        json_header
        jq -n --arg provider "$provider" '{ok:true,provider:$provider}'
        ;;
    update_rule_provider)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        provider=$(printf '%s' "$body" | jq -r '.provider // empty' 2>/dev/null || true)
        [ -n "$provider" ] || json_error "缺少规则提供者名称"
        encoded_provider=$(jq -nr --arg value "$provider" '$value | @uri')
        api_call PUT "/providers/rules/$encoded_provider" >/dev/null 2>&1 || json_error "规则提供者更新失败"
        json_header
        jq -n --arg provider "$provider" '{ok:true,provider:$provider}'
        ;;
    rule_provider_import)
        require_post
        [ -x "$RULE_PROVIDER_MANAGER" ] || json_error "规则提供者导入组件尚未安装"
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        response=$(printf '%s' "$body" | "$RULE_PROVIDER_MANAGER" import 2>/dev/null) \
            || json_error "规则提供者导入脚本执行失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "规则提供者导入返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    subscription_status)
        response=$("$SUBSCRIPTION" status 2>/dev/null) || json_error "无法读取订阅状态"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "订阅状态返回异常"
        subscription_nodes='[]'
        provider_response=$(api_call GET /providers/proxies 2>/dev/null || true)
        if [ -n "$provider_response" ] && printf '%s' "$provider_response" | jq empty >/dev/null 2>&1; then
            subscription_nodes=$(printf '%s' "$provider_response" | jq \
                '[.providers["APP-SUBSCRIPTION"].proxies[]? | {name:(.name // ""),type:(.type // ""),alive:(.alive // null)}]')
            [ -n "$subscription_nodes" ] || subscription_nodes='[]'
        fi
        response=$(printf '%s' "$response" | jq --argjson nodes "$subscription_nodes" '. + {nodes:$nodes}')
        json_header
        printf '%s\n' "$response"
        ;;
    subscription_import)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        subscription_url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null || true)
        [ -n "$subscription_url" ] || json_error "请输入订阅 URL"
        response=$(printf '%s' "$subscription_url" | "$SUBSCRIPTION" import 2>/dev/null) \
            || json_error "订阅导入脚本执行失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "订阅导入返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    subscription_update)
        require_post
        response=$("$SUBSCRIPTION" update 2>/dev/null) || json_error "订阅更新脚本执行失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "订阅更新返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    manual_nodes)
        response=$("$NODE_MANAGER" list 2>/dev/null) || json_error "无法读取手动节点"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "手动节点状态返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    manual_node_import)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        node_value=$(printf '%s' "$body" | jq -r '.node // empty' 2>/dev/null || true)
        [ -n "$node_value" ] || json_error "请输入单节点分享链接或 Clash JSON"
        response=$(printf '%s' "$node_value" | "$NODE_MANAGER" import 2>/dev/null) \
            || json_error "单节点导入脚本执行失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "单节点导入返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    manual_node_delete)
        require_post
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        node_name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null || true)
        [ -n "$node_name" ] || json_error "缺少节点名称"
        response=$(printf '%s' "$node_name" | "$NODE_MANAGER" delete 2>/dev/null) \
            || json_error "删除手动节点脚本执行失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "删除手动节点返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    docker_proxy_status)
        [ -x "$DOCKER_PROXY_HELPER" ] || json_error "Docker 代理助手尚未安装"
        response=$(sudo -n "$DOCKER_PROXY_HELPER" status 2>/dev/null) \
            || json_error "无法读取 Docker 代理状态"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Docker 代理状态返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    docker_proxy_enable)
        require_post
        [ -x "$DOCKER_PROXY_HELPER" ] || json_error "Docker 代理助手尚未安装"
        response=$(sudo -n "$DOCKER_PROXY_HELPER" enable 2>/dev/null) \
            || json_error "启用 Docker 代理失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Docker 代理操作返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    docker_proxy_disable)
        require_post
        [ -x "$DOCKER_PROXY_HELPER" ] || json_error "Docker 代理助手尚未安装"
        response=$(sudo -n "$DOCKER_PROXY_HELPER" disable 2>/dev/null) \
            || json_error "关闭 Docker 代理失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Docker 代理操作返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    core_update_status)
        [ -x "$CORE_UPDATER" ] || json_error "核心更新组件尚未安装"
        response=$("$CORE_UPDATER" status 2>/dev/null) || json_error "无法读取核心更新状态"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "核心更新状态返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    core_update_check)
        [ -x "$CORE_UPDATER" ] || json_error "核心更新组件尚未安装"
        response=$("$CORE_UPDATER" check 2>/dev/null) || json_error "检查 Mihomo 更新失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "核心更新检查返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    core_update_apply)
        require_post
        [ -x "$CORE_UPDATER" ] || json_error "核心更新组件尚未安装"
        response=$("$CORE_UPDATER" update 2>/dev/null) || json_error "Mihomo 核心更新失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "核心更新返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    geodata_status)
        [ -x "$GEODATA_MANAGER" ] || json_error "Geo 数据组件尚未安装"
        response=$("$GEODATA_MANAGER" status 2>/dev/null) || json_error "无法读取 Geo 数据状态"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Geo 数据状态返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    geodata_update)
        require_post
        [ -x "$GEODATA_MANAGER" ] || json_error "Geo 数据组件尚未安装"
        response=$("$GEODATA_MANAGER" update 2>/dev/null) || json_error "GeoIP / GeoSite 更新失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Geo 数据更新返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    geodata_apply_policy)
        require_post
        [ -x "$GEODATA_MANAGER" ] || json_error "Geo 数据组件尚未安装"
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        policy=$(printf '%s' "$body" | jq -r '.policy // empty' 2>/dev/null || true)
        case "$policy" in cn_direct|lan_direct|direct) ;; *) json_error "不支持的 Geo 规则策略" ;; esac
        response=$("$GEODATA_MANAGER" apply "$policy" 2>/dev/null) || json_error "Geo 规则策略应用失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "Geo 规则策略返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    network_access_status)
        [ -x "$NETWORK_ACCESS" ] || json_error "网络访问设置组件尚未安装"
        response=$("$NETWORK_ACCESS" status 2>/dev/null) || json_error "无法读取网络访问范围"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "网络访问状态返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    network_access_set)
        require_post
        [ -x "$NETWORK_ACCESS" ] || json_error "网络访问设置组件尚未安装"
        body=$(read_json_body) || json_error "请求内容无效或超过 64 KiB"
        access_mode=$(printf '%s' "$body" | jq -r '.mode // empty' 2>/dev/null || true)
        case "$access_mode" in local|lan) ;; *) json_error "不支持的访问范围" ;; esac
        response=$("$NETWORK_ACCESS" set "$access_mode" 2>/dev/null) || json_error "切换网络访问范围失败"
        printf '%s' "$response" | jq empty >/dev/null 2>&1 || json_error "网络访问设置返回异常"
        json_header
        printf '%s\n' "$response"
        ;;
    start)
        require_post
        PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
        PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" start >/dev/null 2>&1 || json_error "Mihomo 启动失败，请查看日志"
        json_header
        echo '{"ok":true,"running":true}'
        ;;
    stop)
        require_post
        PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
        PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" stop >/dev/null 2>&1 || json_error "Mihomo 停止失败，请查看日志"
        json_header
        echo '{"ok":true,"running":false}'
        ;;
    restart)
        require_post
        PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
        PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" restart >/dev/null 2>&1 || json_error "Mihomo 重启失败，请查看日志"
        json_header
        echo '{"ok":true}'
        ;;
    config_get)
        [ -f "$CONFIG_FILE" ] || json_error "配置文件不存在"
        json_header
        jq -Rs '{ok:true,config:.}' < "$CONFIG_FILE"
        ;;
    config_save)
        require_post
        length=${CONTENT_LENGTH:-0}
        case "$length" in *[!0-9]*|'') json_error "无效的请求长度" ;; esac
        [ "$length" -gt 0 ] || json_error "配置不能为空"
        [ "$length" -le 2097152 ] || json_error "配置不能超过 2 MiB"
        mkdir -p "$VAR_DIR"
        config_tmp="$VAR_DIR/config.yaml.new.$$"
        test_log="$VAR_DIR/config-test.$$"
        trap 'rm -f "$config_tmp" "$test_log"' EXIT HUP INT TERM
        dd bs=1 count="$length" of="$config_tmp" 2>/dev/null
        chmod 0600 "$config_tmp"
        if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
            error_text=$(tail -n 20 "$test_log" 2>/dev/null || echo "配置校验失败")
            json_error "$error_text"
        fi
        cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak" 2>/dev/null || true
        mv -f "$config_tmp" "$CONFIG_FILE"
        chmod 0600 "$CONFIG_FILE"
        if ! PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
            PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
            "$CONTROL" restart >/dev/null 2>&1; then
            if [ -f "$ETC_DIR/config.yaml.bak" ]; then
                cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
                PLUG_USER="$plugin_user" PLUG_NAME=mihomo \
                PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
                "$CONTROL" restart >/dev/null 2>&1 || true
            fi
            json_error "新配置通过校验，但启动失败，已尝试恢复旧配置"
        fi
        json_header
        echo '{"ok":true,"restarted":true}'
        ;;
    logs)
        json_header
        if [ -f "$VAR_DIR/mihomo.log" ]; then
            tail -n 200 "$VAR_DIR/mihomo.log" | jq -Rs '{ok:true,log:.}'
        else
            echo '{"ok":true,"log":""}'
        fi
        ;;
    *)
        json_error "未知操作"
        ;;
esac
