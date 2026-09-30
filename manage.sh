#!/usr/bin/env bash
# Single-file install/uninstall entry point. NAS backends are emitted into a temporary bundle.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME='mihomo'
PLUGIN_LABEL='Mihomo'
PLUGIN_VERSION='1.7.20'
UNINSTALL_NOTE='卸载会停止该用户的代理；若 Docker 正使用此代理，会撤销它并重启 Docker。其他用户插件和普通文件保留。'

# Shared frontend; keep this section consistent across the four manage.sh files.
set -Eeuo pipefail

installer_error() { printf '[错误] %s\n' "$*" >&2; exit 2; }
installer_info() { printf '[信息] %s\n' "$*"; }
installer_usage() {
    cat <<EOF
$PLUGIN_LABEL — $ACTION_LABEL

用法：
  bash $ENTRY [设备IP] [用户1,用户2]
  bash $ENTRY [--ip 192.168.31.100] [--users u123456789,u987654321]
  bash $ENTRY [--ip 192.168.31.100] --all-users

选项：
  --ip IP        远程 NAS 的 IPv4 地址；未填写时交互输入
  --users LIST   指定一个或多个用户，以逗号分隔
  --all-users    选择扫描到的全部符合条件的用户
  --list-users   仅显示用户及安装状态
  --dry-run      校验环境和用户，显示计划，不执行安装卸载
  --yes, -y      跳过卸载确认；非交互卸载必须明确提供
  --help, -h     显示此说明

NAS 本机自动直接执行，必须以 root 运行；WSL/Linux 自动使用 root SSH。
不指定用户时列出用户，支持序号多选（如 1,3）或输入 all。
仅扫描到一个用户时自动选择；非交互多用户场景必须指定用户。
安装会保留已有配置；卸载范围与保留数据会在执行前显示。
EOF
}
installer_ipv4() {
    local ip=$1 part
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local -a parts
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
}
installer_valid_user() { [[ $1 =~ ^u[0-9]+$ ]]; }
installer_require() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || installer_error "缺少命令：$command_name"
    done
}
installer_target_script() {
    if [[ $DIRECT == true ]]; then
        installer_emit_probe | /bin/sh -s -- "$@"
    else
        installer_emit_probe | ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" /bin/sh -s -- "$@"
    fi
}
installer_cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n ${REMOTE_DIR:-} && $REMOTE_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]]; then
        ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes "root@$NAS_IP" "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1 ||
            printf '[提示] 远端暂存目录未清理，可手动删除：%s\n' "$REMOTE_DIR" >&2
    fi
    if [[ -n ${WORK_DIR:-} && $WORK_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$rc"
}
installer_select_users() {
    local raw=$1 row user state token found index
    USERS=(); STATES=(); SELECTED=()
    while IFS=$'\t' read -r user state; do
        [[ -n $user ]] || continue
        installer_valid_user "$user" || installer_error "设备返回了无效用户；请检查 SSH 输出。"
        [[ $state == installed || $state == available ]] || installer_error "设备返回了无效安装状态。"
        USERS+=("$user"); STATES+=("$state")
    done <<< "$raw"
    printf '\n可%s的用户：\n' "$ACTION_LABEL"
    for ((index=0; index<${#USERS[@]}; index++)); do
        state=未安装; [[ ${STATES[index]} != installed ]] || state=已安装
        printf '  %d) %s  [%s]\n' "$((index+1))" "${USERS[index]}" "$state"
    done
    if (("${#USERS[@]}" == 0)); then
        [[ $ACTION != uninstall ]] || { installer_info "没有已安装$PLUGIN_LABEL的用户，无需卸载。"; exit 0; }
        installer_error "没有可安装用户，请先在小米客户端创建用户并初始化存储池。"
    fi
    [[ $LIST_ONLY != true ]] || return 0
    if [[ $ALL_USERS == true ]]; then
        SELECTED=("${USERS[@]}")
        return
    fi
    if [[ -z $USER_SPEC ]]; then
        if (("${#USERS[@]}" == 1)); then
            USER_SPEC="${USERS[0]}"
            installer_info "自动选择唯一用户：$USER_SPEC"
        else
            [[ -t 0 ]] || installer_error "存在多个用户，请使用 --users 或 --all-users。"
            read -r -p '请选择用户序号（可用逗号多选，all 表示全部，q 退出）：' USER_SPEC || installer_error "输入已结束。"
            [[ $USER_SPEC != q ]] || exit 0
        fi
    fi
    if [[ $USER_SPEC == all ]]; then SELECTED=("${USERS[@]}"); return; fi
    [[ -n $USER_SPEC && $USER_SPEC != ,* && $USER_SPEC != *, && $USER_SPEC != *,,* ]] || installer_error "用户列表不能为空或包含空项。"
    local -a tokens
    IFS=', ' read -r -a tokens <<< "$USER_SPEC"
    for token in "${tokens[@]}"; do
        if [[ $token =~ ^[0-9]+$ && ${#token} -le 6 ]]; then
            index=$((10#$token))
            ((index >= 1 && index <= ${#USERS[@]})) || installer_error "用户序号超出范围：$token"
            user=${USERS[index-1]}
        else
            installer_valid_user "$token" || installer_error "无效用户：$token"
            user=$token
        fi
        found=false
        for row in "${USERS[@]}"; do [[ $row != "$user" ]] || found=true; done
        [[ $found == true ]] || installer_error "用户 $user 不在本次可$ACTION_LABEL列表中。"
        found=false
        for row in "${SELECTED[@]}"; do [[ $row != "$user" ]] || found=true; done
        [[ $found == true ]] || SELECTED+=("$user")
    done
    (("${#SELECTED[@]}" > 0)) || installer_error "未选择用户。"
}
installer_main() {
    ACTION=$1; shift
    case $ACTION in install) ACTION_LABEL=安装; ENTRY="manage.sh install";; uninstall) ACTION_LABEL=卸载; ENTRY="manage.sh uninstall";; *) installer_error "无效操作。";; esac
    NAS_IP=; USER_SPEC=; ALL_USERS=false; LIST_ONLY=false; DRY_RUN=false; ASSUME_YES=false
    DIRECT=false; WORK_DIR=; REMOTE_DIR=
    local arg raw answer user rc failures=0
    while (($#)); do
        arg=$1; shift
        case $arg in
            -h|--help) installer_usage; return;;
            --ip|--users)
                (($#)) && [[ -n $1 && $1 != --* ]] || installer_error "$arg 缺少参数。"
                if [[ $arg == --ip ]]; then
                    [[ -z $NAS_IP ]] || installer_error "设备 IP 重复指定。"; NAS_IP=$1
                else
                    [[ -z $USER_SPEC ]] || installer_error "用户重复指定。"; USER_SPEC=$1
                fi
                shift;;
            --all-users) ALL_USERS=true;;
            --list-users) LIST_ONLY=true;;
            --dry-run) DRY_RUN=true;;
            --yes|-y) ASSUME_YES=true;;
            --*) installer_error "未知选项：$arg";;
            *)
                if [[ $arg == *.* && -z $NAS_IP ]]; then NAS_IP=$arg
                elif [[ -z $USER_SPEC ]]; then USER_SPEC=$arg
                else installer_error "多余参数：$arg"; fi;;
        esac
    done
    [[ $ALL_USERS != true || -z $USER_SPEC ]] || installer_error "--all-users 不能与用户列表同时使用。"
    [[ -z $NAS_IP ]] || installer_ipv4 "$NAS_IP" || installer_error "无效 IPv4 地址：$NAS_IP"
    printf '\n%s — %s\n' "$PLUGIN_LABEL" "$ACTION_LABEL"
    printf '[1/5] 识别运行环境\n'
    if [[ -f /etc/config/plugin ]] && command -v plugincenter >/dev/null 2>&1; then
        [[ $(id -u) == 0 ]] || installer_error "已识别为 NAS 本机，请使用 root 运行。"
        DIRECT=true; installer_info "小米智能存储本机，直接执行。"
        [[ -z $NAS_IP ]] || installer_error "本机模式无需设备 IP；请移除 IP，避免误操作目标。"
    else
        if [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
            installer_info "WSL，通过 root SSH 连接 NAS。"
        else
            installer_info "Linux/兼容终端，通过 root SSH 连接 NAS。"
        fi
        installer_require ssh
        if [[ -z $NAS_IP ]]; then
            [[ -t 0 ]] || installer_error "非交互环境请使用 --ip 指定设备 IP。"
            read -r -p '请输入小米智能存储 IPv4 地址：' NAS_IP || installer_error "输入已结束。"
        fi
        installer_ipv4 "$NAS_IP" || installer_error "无效 IPv4 地址：$NAS_IP"
    fi
    SSH_OPTIONS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
    [[ -t 0 ]] || SSH_OPTIONS+=(-o BatchMode=yes)
    printf '[2/5] 扫描用户与安装状态\n'
    if ! raw=$(installer_target_script --scan "$PLUGIN_NAME" "$ACTION"); then
        installer_error "设备检查或用户扫描失败；请检查 SSH 连接、root 权限及上方错误。"
    fi
    installer_select_users "$raw"
    [[ $LIST_ONLY != true ]] || return 0
    printf '\n[3/5] 核对执行计划\n'
    printf '  插件：%s\n  操作：%s\n  目标：%s\n' "$PLUGIN_LABEL" "$ACTION_LABEL" "${NAS_IP:-NAS 本机}"
    printf '  用户：%s\n' "${SELECTED[*]}"
    if [[ $ACTION == uninstall ]]; then
        printf '  范围：仅删除所选用户的本插件；配置及记录先备份到 plugin/.reserve/%s/。\n' "$PLUGIN_NAME"
        printf '  说明：%s\n' "$UNINSTALL_NOTE"
    else
        printf '  说明：保留已有配置；多用户独立注册，按插件需要分配独立端口。\n'
    fi
    installer_target_script --check "$PLUGIN_NAME" "$ACTION" "${SELECTED[@]}" ||
        installer_error "预检查失败，尚未执行$ACTION_LABEL。"
    if [[ $DRY_RUN == true ]]; then installer_info "预检查通过。仅显示计划，未执行$ACTION_LABEL。"; return; fi
    if [[ $ACTION == uninstall && $ASSUME_YES != true ]]; then
        [[ -t 0 ]] || installer_error "非交互卸载请检查计划后添加 --yes。"
        read -r -p '确认卸载以上用户的插件？输入 yes 继续：' answer || installer_error "输入已结束。"
        [[ $answer == yes ]] || { installer_info "已取消卸载。"; return; }
    fi
    installer_require mktemp tar cp
    [[ $DIRECT == true ]] || installer_require scp
    WORK_DIR=$(mktemp -d "/tmp/xiaomi-plugin.$PLUGIN_NAME.XXXXXX")
    trap installer_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    mkdir "$WORK_DIR/bundle"
    if [[ $ACTION == install ]]; then installer_emit_install > "$WORK_DIR/bundle/remote-install.sh"
    else installer_emit_uninstall > "$WORK_DIR/bundle/remote-uninstall.sh"; fi
    if [[ $ACTION == install ]]; then
        [[ -d $SCRIPT_DIR/payload ]] || installer_error "安装包缺少 payload 目录。"
        cp -R "$SCRIPT_DIR/payload" "$WORK_DIR/bundle/payload"
        if declare -F installer_prepare_payload >/dev/null; then installer_prepare_payload "$WORK_DIR/bundle"; fi
    fi
    printf '\n[4/5] 执行%s\n' "$ACTION_LABEL"
    if [[ $DIRECT != true ]]; then
        REMOTE_DIR=$(ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "mktemp -d /tmp/xiaomi-plugin.$PLUGIN_NAME.XXXXXX") ||
            installer_error "无法创建 NAS 暂存目录。"
        [[ $REMOTE_DIR =~ ^/tmp/xiaomi-plugin\.[a-z]+\.[a-zA-Z0-9]+$ ]] || installer_error "NAS 返回了异常暂存路径。"
        tar -czf "$WORK_DIR/bundle.tgz" -C "$WORK_DIR" bundle
        scp "${SSH_OPTIONS[@]}" "$WORK_DIR/bundle.tgz" "root@$NAS_IP:$REMOTE_DIR/bundle.tgz"
        ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "tar -xzf '$REMOTE_DIR/bundle.tgz' -C '$REMOTE_DIR'"
    fi
    local -a successes=() failed=()
    for user in "${SELECTED[@]}"; do
        printf '\n[用户 %s] 正在%s%s……\n' "$user" "$ACTION_LABEL" "$PLUGIN_LABEL"
        # Each backend runs in its own sh process: an error cannot be hidden by this if.
        if [[ $DIRECT == true ]]; then
            if /bin/sh "$WORK_DIR/bundle/remote-$ACTION.sh" "$user"; then rc=0; else rc=$?; fi
        else
            if ssh "${SSH_OPTIONS[@]}" "root@$NAS_IP" "/bin/sh '$REMOTE_DIR/bundle/remote-$ACTION.sh' '$user'"; then rc=0; else rc=$?; fi
        fi
        if ((rc == 0)); then successes+=("$user")
        else failed+=("$user"); failures=$((failures+1)); printf '[错误] %s %s失败（退出码 %s），请查看上方日志。\n' "$user" "$ACTION_LABEL" "$rc" >&2; fi
    done
    printf '\n[5/5] 执行结果\n'
    printf '  成功（%s）：%s\n' "${#successes[@]}" "${successes[*]:-无}"
    printf '  失败（%s）：%s\n' "${#failed[@]}" "${failed[*]:-无}"
    if ((failures > 0)); then
        printf '[提示] 已成功用户不回滚；请解决错误后只重试失败用户。\n' >&2
        return 1
    fi
    installer_info "$ACTION_LABEL完成。请重新打开手机 APP 或电脑客户端的插件列表。"
}

# Download once per batch and verify before placing the core in the install bundle.
installer_prepare_payload() {
    local stage=$1 version=v1.19.31
    local expected=9e0f11afbf38426b8bd88fdc594678f8161c57eccb4e1b77acb12b493904f1d4
    local asset="mihomo-linux-arm64-$version.gz"
    local cache="$SCRIPT_DIR/.cache" archive
    archive="$cache/$asset"
    installer_require gzip sha256sum
    mkdir -p "$cache"
    if [[ ! -f $archive ]] || ! printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        installer_info "下载 Mihomo $version ARM64 核心……"
        local download="$WORK_DIR/$asset"
        local url="https://github.com/MetaCubeX/mihomo/releases/download/$version/$asset"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --retry 3 --connect-timeout 15 --output "$download" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$download" "$url"
        else
            installer_error "下载核心需要 curl 或 wget。"
        fi
        printf '%s  %s\n' "$expected" "$download" | sha256sum -c - >/dev/null 2>&1 || installer_error "Mihomo 核心 SHA-256 校验失败。"
        mv -f "$download" "$archive"
    fi
    installer_info "Mihomo 核心校验通过；同一批用户复用此安装包。"
    gzip -dc "$archive" > "$stage/payload/files/mihomo"
    chmod 0755 "$stage/payload/files/mihomo"
}

installer_emit_metadata() {
    printf '%s\n' '#!/bin/sh' 'set -eu' "PLUGIN_NAME='$PLUGIN_NAME'" "PLUGIN_LABEL='$PLUGIN_LABEL'" "PLUGIN_VERSION='$PLUGIN_VERSION'" "UNINSTALL_NOTE='$UNINSTALL_NOTE'"
}
installer_emit_nas_common() {
    cat <<'NAS_COMMON_SCRIPT'
#!/bin/sh
# Shared NAS checks and uninstall workflow; identical in all standalone packages.
nas_fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
nas_log() { printf '[信息] %s\n' "$*"; }
nas_valid_user() {
    case "$1" in u*) ;; *) return 1;; esac
    case "${1#u}" in ''|*[!0-9]*) return 1;; esac
}
nas_metadata() {
    NAS_PLUGIN=$1
    case "$NAS_PLUGIN" in
        mihomo) NAS_LABEL=Mihomo;;
        dockermanager) NAS_LABEL=docker;;
        quickshare) NAS_LABEL=文件快传;;
        nascenter) NAS_LABEL=控制中心;;
        *) nas_fail "无效插件名称。";;
    esac
}
nas_require() {
    for nas_cmd in "$@"; do command -v "$nas_cmd" >/dev/null 2>&1 || nas_fail "NAS 缺少命令：$nas_cmd"; done
}
nas_environment() {
    [ "$(id -u)" = 0 ] || nas_fail "请以 root 身份在小米智能存储上执行。"
    [ -f /etc/config/plugin ] || nas_fail "未检测到小米智能存储配置。"
    nas_require jq plugincenter sort readlink mountpoint flock
}
nas_is_installed() {
    [ -d "/home/$1/plugin/$NAS_PLUGIN" ] || [ -L "/home/$1/plugin/$NAS_PLUGIN" ] ||
        { [ -f "/data/plugin/$1.list" ] && jq -e --arg p "$NAS_PLUGIN" '.[$p].install == true' "/data/plugin/$1.list" >/dev/null 2>&1; }
}
nas_scan() {
    nas_metadata "$1"; nas_action=$2
    nas_environment
    # Include accounts whose registration or home exists; never rely on find following symlinks.
    {
        for nas_item in /data/plugin/u*.list; do
            [ -f "$nas_item" ] || continue
            nas_candidate=${nas_item##*/}; nas_candidate=${nas_candidate%.list}
            nas_valid_user "$nas_candidate" && printf '%s\n' "$nas_candidate"
        done
        for nas_item in /home/u*; do
            [ -d "$nas_item" ] || continue
            nas_candidate=${nas_item##*/}
            nas_valid_user "$nas_candidate" && printf '%s\n' "$nas_candidate"
        done
    } | LC_ALL=C sort -u | while IFS= read -r nas_candidate; do
        nas_state=available
        if nas_is_installed "$nas_candidate"; then nas_state=installed; fi
        if [ "$nas_action" = uninstall ]; then
            [ "$nas_state" = installed ] || continue
        else
            id "$nas_candidate" >/dev/null 2>&1 || continue
            [ -d "/home/$nas_candidate" ] && [ -f "/data/plugin/$nas_candidate.list" ] || continue
        fi
        printf '%s\t%s\n' "$nas_candidate" "$nas_state"
    done
}
nas_pool_path() {
    # Strictly validate the whole path before creating, moving or removing anything.
    nas_path=$1; nas_kind=$2
    nas_pool=${nas_path#/nas/}; nas_pool=${nas_pool%%/*}
    case "$nas_pool" in pool*) ;; *) nas_fail "异常存储池路径：$nas_path";; esac
    case "${nas_pool#pool}" in ''|*[!0-9]*) nas_fail "异常存储池路径：$nas_path";; esac
    [ "$nas_path" = "/nas/$nas_pool/$NAS_USER/plugin/$nas_kind/$NAS_PLUGIN" ] || nas_fail "异常插件路径：$nas_path"
    mountpoint -q "/nas/$nas_pool" || nas_fail "存储池 /nas/$nas_pool 尚未挂载，请恢复硬盘挂载后重试。"
    [ -d "/nas/$nas_pool/$NAS_USER" ] || nas_fail "存储池内不存在用户 $NAS_USER。"
    nas_real=$(readlink -f "$nas_path" 2>/dev/null || true)
    [ -z "$nas_real" ] || [ "$nas_real" = "$nas_path" ] || nas_fail "插件路径重定向到其他位置：$nas_path"
}
nas_check_user() {
    NAS_USER=$1
    nas_valid_user "$NAS_USER" || nas_fail "无效用户：$NAS_USER（应为 u 后接数字）"
    [ -d "/home/$NAS_USER" ] || nas_fail "用户主目录不存在：$NAS_USER"
    id "$NAS_USER" >/dev/null 2>&1 || nas_fail "系统账户不存在：$NAS_USER"
    NAS_HOME="/home/$NAS_USER/plugin/$NAS_PLUGIN"
    [ ! -L "$NAS_HOME" ] || nas_fail "插件主目录不能为符号链接：$NAS_HOME"
    NAS_LIST="/data/plugin/$NAS_USER.list"
    if [ -f "$NAS_LIST" ]; then
        jq -e 'type == "object"' "$NAS_LIST" >/dev/null 2>&1 || nas_fail "插件清单损坏：$NAS_LIST"
    elif [ "$NAS_ACTION" = install ]; then
        nas_fail "插件清单不存在：$NAS_LIST"
    fi
    NAS_SRC="/nas/pool0/$NAS_USER/plugin/pluginsrc/$NAS_PLUGIN"
    NAS_TMP="/nas/pool0/$NAS_USER/plugin/plugintmp/$NAS_PLUGIN"
    if [ -L "$NAS_HOME/src" ]; then NAS_SRC=$(readlink "$NAS_HOME/src"); fi
    if [ -L "$NAS_HOME/tmp" ]; then NAS_TMP=$(readlink "$NAS_HOME/tmp"); else NAS_TMP="${NAS_SRC%/pluginsrc/*}/plugintmp/$NAS_PLUGIN"; fi
    nas_pool_path "$NAS_SRC" pluginsrc
    nas_pool_path "$NAS_TMP" plugintmp
    if [ "$NAS_ACTION" = uninstall ]; then nas_is_installed "$NAS_USER" || nas_fail "$NAS_USER 尚未安装$NAS_LABEL。"; fi
    NAS_WEB_ROOT=$(jq -r '.settings.nginx_plugin // "/data/plugin/www"' /etc/config/plugin)
    case "$NAS_WEB_ROOT" in /*) ;; *) nas_fail "插件网页根目录配置无效。";; esac
}
nas_prepare() {
    NAS_ACTION=$1; nas_metadata "$PLUGIN_NAME"
    nas_environment
    [ -n "${2:-}" ] || nas_fail "请显式指定插件用户；推荐运行 manage.sh install 或 manage.sh uninstall。"
    # Serialize installer operations across users and plugins that share helpers and icons.
    exec 7>/data/plugin/.local-plugin-installer.lock
    flock -w 60 -x 7 || nas_fail "另一个安装或卸载任务仍在执行，请稍后重试。"
    trap 'flock -u 7 2>/dev/null || true' 0
    nas_check_user "$2"
    nas_log "$NAS_LABEL：已校验用户 $NAS_USER、插件目录和存储池。"
}
nas_remove_entry() {
    [ -f "$NAS_LIST" ] || return 0
    exec 9>"/data/plugin/.$NAS_USER.plugins.lock"
    flock -x 9
    nas_next="$NAS_LIST.$NAS_PLUGIN-uninstall.$$"
    cp -p "$NAS_LIST" "$NAS_BACKUP/plugin-list.json"
    jq --arg p "$NAS_PLUGIN" 'del(.[$p])' "$NAS_LIST" > "$nas_next"
    chmod --reference="$NAS_LIST" "$nas_next"
    chown --reference="$NAS_LIST" "$nas_next"
    mv -f "$nas_next" "$NAS_LIST"
    flock -u 9
}
nas_other_users() {
    for nas_d in /home/u*/plugin/"$NAS_PLUGIN"; do
        [ ! -d "$nas_d" ] && [ ! -L "$nas_d" ] || return 0
    done
    for nas_f in /data/plugin/u*.list; do
        [ -f "$nas_f" ] || continue
        # If another user's registry is unreadable, preserve shared files.
        jq empty "$nas_f" >/dev/null 2>&1 || return 0
        if jq -e --arg p "$NAS_PLUGIN" '.[$p].install == true' "$nas_f" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}
nas_uninstall() {
    nas_prepare uninstall "${1:-}"
    nas_require cp date chmod chown rm
    NAS_BACKUP="/home/$NAS_USER/plugin/.reserve/$NAS_PLUGIN/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$NAS_BACKUP"
    chmod 0700 "$NAS_BACKUP"
    nas_log "停止所选用户的插件并备份配置……"
    plugincenter -u "$NAS_USER" -p "$NAS_PLUGIN" disable >/dev/null 2>&1 || true
    if [ -x "$NAS_HOME/scripts/control" ]; then
        PLUG_USER="$NAS_USER" PLUG_NAME="$NAS_PLUGIN" PLUG_HOME_DIR="$NAS_HOME" PLUG_SRC_DIR="$NAS_SRC" \
            "$NAS_HOME/scripts/control" disable || nas_fail "插件停止失败，保留安装文件，请检查服务状态后重试。"
    fi
    for nas_data in etc var INFO; do
        if [ -e "$NAS_HOME/$nas_data" ]; then cp -a "$NAS_HOME/$nas_data" "$NAS_BACKUP/"; fi
    done
    nas_remove_entry
    case "$NAS_PLUGIN" in
        mihomo)
            nas_port=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$NAS_HOME/etc/ports.env" 2>/dev/null | head -n 1)
            nas_helper=/data/plugin/.mihomo-system/mihomo-docker-proxy
            if [ -x "$nas_helper" ] && [ -n "$nas_port" ]; then
                "$nas_helper" disable "$nas_port" >/dev/null || nas_fail "无法撤销该用户的 Docker 代理。"
            fi
            rm -f "/etc/sudoers.d/mihomo-docker-proxy-$NAS_USER" "/etc/cron.d/mihomo-plugin-$NAS_USER"
            if [ -f /etc/sudoers.d/mihomo-docker-proxy ] && grep -q "^$NAS_USER[[:space:]]" /etc/sudoers.d/mihomo-docker-proxy; then rm -f /etc/sudoers.d/mihomo-docker-proxy; fi
            if [ -f /etc/cron.d/mihomo-plugin ] && grep -Fq "boot.sh $NAS_USER" /etc/cron.d/mihomo-plugin; then rm -f /etc/cron.d/mihomo-plugin; fi
            nas_hotplug=$(jq -r '.settings.system_hotplug // empty' /etc/config/plugin)
            if [ -n "$nas_hotplug" ]; then rm -f "$nas_hotplug/net/$NAS_USER.$NAS_PLUGIN"; fi;;
        dockermanager)
            rm -f "/etc/sudoers.d/dockermanager-$NAS_USER" "/etc/cron.d/dockermanager-$NAS_USER";;
        quickshare)
            rm -f "/etc/cron.d/quickshare-$NAS_USER";;
        nascenter)
            rm -f "/etc/sudoers.d/nascenter-$NAS_USER";;
    esac
    rm -f "$NAS_WEB_ROOT/$NAS_USER/$NAS_PLUGIN"
    # Paths were checked in full by nas_check_user; repeat immediately before removal.
    nas_pool_path "$NAS_SRC" pluginsrc; nas_pool_path "$NAS_TMP" plugintmp
    rm -rf "$NAS_SRC" "$NAS_TMP" "$NAS_HOME"
    if ! nas_other_users; then
        case "$NAS_PLUGIN" in
            mihomo)
                if ! ls /etc/sudoers.d/mihomo-docker-proxy* >/dev/null 2>&1; then
                    rm -f /data/plugin/.mihomo-system/mihomo-docker-proxy
                    rmdir /data/plugin/.mihomo-system 2>/dev/null || true
                fi;;
            dockermanager)
                if ! ls /etc/sudoers.d/dockermanager-u* >/dev/null 2>&1; then
                    rm -f /data/plugin/.dockermanager-system/docker-manager-helper
                    rmdir /data/plugin/.dockermanager-system 2>/dev/null || true
                fi;;
            nascenter)
                if ! ls /etc/sudoers.d/nascenter-u* >/dev/null 2>&1; then
                    rm -f /data/plugin/.nascenter-system/nas-center-helper
                    rmdir /data/plugin/.nascenter-system 2>/dev/null || true
                fi;;
        esac
        rm -f "/data/plugin/www/icon/$NAS_PLUGIN.icon"
    fi
    systemctl reload crond.service >/dev/null 2>&1 || true
    nas_log "$NAS_USER 的$NAS_LABEL已卸载。"
    nas_log "配置及记录备份：$NAS_BACKUP"
    nas_log "$UNINSTALL_NOTE"
}
# Direct read-only entry points used by the frontend over SSH.
case "${1:-}" in
    --scan)
        set -eu
        [ "$#" = 3 ] || nas_fail "扫描参数错误。"
        case "$3" in install|uninstall) ;; *) nas_fail "无效操作。";; esac
        nas_scan "$2" "$3";;
    --check)
        set -eu
        nas_metadata "$2"; NAS_ACTION=$3; shift 3
        case "$NAS_ACTION" in install|uninstall) ;; *) nas_fail "无效操作。";; esac
        nas_environment
        for nas_selected in "$@"; do nas_check_user "$nas_selected"; done;;
esac
NAS_COMMON_SCRIPT
}
installer_emit_probe() {
    installer_emit_metadata
    installer_emit_nas_common
}
installer_emit_install() {
    installer_emit_probe
    cat <<'NAS_INSTALL_SCRIPT'
INSTALLER_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
nas_prepare install "${1:-}"
PLUGIN_USER=$NAS_USER
fail() { nas_fail "$@"; }
CORE_VERSION="v1.19.31"
BUNDLE_DIR=$INSTALLER_DIR
PAYLOAD_DIR="$BUNDLE_DIR/payload"
nas_require jq sha256sum plugincenter runuser flock curl openssl python3 file cmp sudo systemctl ss visudo sort grep tail

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
LOCK_FILE="/data/plugin/.$PLUGIN_USER.plugins.lock"
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
# than the core bundled with manage.sh, so reinstalling the plugin UI never
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
chmod 0644 "$stage_src/ui/index.html" "$stage_src/ui/app.js" "$stage_src/ui/client-bridge.js" "$stage_src/ui/style.css" "$stage_src/ui/palette.css" "$stage_src/ui/config"

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
      changelog:"统一六插件视觉规范、全宽桌面布局、手机深色主题与样式隔离",
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

flock -x 9
list_running="$LIST_FILE.mihomo-status.$"
jq --argjson now "$(date +%s)" \
   '.mihomo.status="running" | .mihomo.enable=true | .mihomo.changetime=$now' \
   "$LIST_FILE" > "$list_running"
chmod --reference="$LIST_FILE" "$list_running" 2>/dev/null || chmod 0644 "$list_running"
chown --reference="$LIST_FILE" "$list_running" 2>/dev/null || chown "$PLUGIN_USER:$PLUGIN_USER" "$list_running"
mv -f "$list_running" "$LIST_FILE"
flock -u 9

echo "Mihomo $INSTALLED_CORE_VERSION 已启动。"
echo "APP 插件清单：$LIST_FILE"
echo "配置文件：$ETC_DIR/config.yaml"
echo "代理端口：$MIXED_PORT；控制端口：$CONTROLLER_PORT"
echo "运行日志：$VAR_DIR/mihomo.log"
echo "清单安装前备份：$backup_file"
NAS_INSTALL_SCRIPT
}
installer_emit_uninstall() {
    installer_emit_probe
    printf '%s\n' 'nas_uninstall "${1:-}"'
}
manage_usage() {
    cat <<EOF
$PLUGIN_LABEL — 安装与卸载
  bash manage.sh                         交互菜单
  bash manage.sh install [选项]           安装或更新
  bash manage.sh uninstall [选项]         卸载
  bash manage.sh install --help           查看安装参数
  bash manage.sh uninstall --help         查看卸载参数

NAS 本机自动直接执行；WSL/Linux 自动通过 root SSH 连接。
支持 --ip、--users、--all-users、--list-users、--dry-run 和 --yes。
EOF
}
if (($# == 0)); then
    [[ -t 0 ]] || { manage_usage; installer_error "非交互运行请指定 install 或 uninstall。"; }
    printf '\n%s — 安装与卸载\n  1) 安装 / 更新\n  2) 卸载\n  0) 退出\n' "$PLUGIN_LABEL"
    read -r -p '请选择操作：' choice || installer_error "输入已结束。"
    case $choice in 1) set -- install;; 2) set -- uninstall;; 0|q) exit 0;; *) installer_error "无效选项。";; esac
fi
case $1 in
    install|uninstall) operation=$1; shift; installer_main "$operation" "$@";;
    -h|--help) manage_usage;;
    *) manage_usage; installer_error "未知操作：$1";;
esac
