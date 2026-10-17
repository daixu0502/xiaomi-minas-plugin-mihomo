# Shared bounded update helpers; source after defining plugin paths/json_error.
task_progress() {
    [ -n "${MIHOMO_TASK_ID:-}" ] || return 0
    python3 -B "$SCRIPT_DIR/update_tasks.py" progress "$1" "$2" "$3" >/dev/null 2>&1 || true
}
operation_lock() {
    mkdir -p "$VAR_DIR"
    [ "${MIHOMO_TASK_LOCKED:-}" != 1 ] || return 0
    exec 8>"$RUNTIME_DIR/update-operation.lock"
    flock -n 8 || json_error "已有更新或配置应用任务正在执行，请等待完成"
}
hot_apply() {
    python3 -B "$SCRIPT_DIR/update_tasks.py" hot "$1"
}
download_failure() {
    case "$1" in
        22) json_error "$3：HTTP $2（请检查订阅状态、权限或服务端限流）" ;;
        6) json_error "$3：DNS 解析失败" ;;
        7) json_error "$3：无法连接服务器或代理端口" ;;
        28) json_error "$3：连接或下载超时（已执行有限重试）" ;;
        35|51|58|60) json_error "$3：TLS 握手或证书验证失败（curl $1）" ;;
        *) json_error "$3：网络下载失败（curl $1，HTTP $2）" ;;
    esac
}
