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
PORTS_FILE="$ETC_DIR/ports.env"
MIXED_PORT=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" 2>/dev/null | head -n 1)
[ -n "$MIXED_PORT" ] || MIXED_PORT=7890
META_FILE="$ETC_DIR/core-update.meta.json"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

api_tmp=""
archive_tmp=""
binary_tmp=""
test_log=""
meta_tmp=""

cleanup() {
    for cleanup_file in "$api_tmp" "$archive_tmp" "$binary_tmp" "$test_log" "$meta_tmp"; do
        [ -n "$cleanup_file" ] && rm -f "$cleanup_file"
    done
    return 0
}
trap cleanup EXIT HUP INT TERM

json_error() {
    jq -n --arg message "$1" '{ok:false,error:$message}'
    exit 0
}

current_version() {
    [ -x "$BIN" ] || {
        echo unknown
        return
    }
    version_text=$($BIN -v 2>/dev/null || true)
    version_value=$(printf '%s\n' "$version_text" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' | head -n 1 || true)
    printf '%s\n' "${version_value:-unknown}"
}

download_https() {
    download_url=$1
    download_target=$2
    user_agent=$3

    if curl --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 \
        --user-agent "$user_agent" \
        --proxy "http://127.0.0.1:$MIXED_PORT" \
        --output "$download_target" -- "$download_url" >/dev/null 2>&1; then
        return 0
    fi

    rm -f "$download_target"
    curl --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 180 --retry 2 \
        --user-agent "$user_agent" \
        --output "$download_target" -- "$download_url" >/dev/null 2>&1
}

fetch_latest() {
    mkdir -p "$VAR_DIR"
    umask 077
    api_tmp="$VAR_DIR/mihomo-release.$$"
    download_https "$API_URL" "$api_tmp" 'xiaomi-storage-mihomo-plugin/1.5.0' \
        || json_error "无法连接 GitHub 检查 Mihomo 更新"
    [ -s "$api_tmp" ] || json_error "GitHub 返回了空的版本信息"
    [ "$(wc -c < "$api_tmp")" -le 2097152 ] || json_error "GitHub 版本信息异常"
    jq empty "$api_tmp" >/dev/null 2>&1 || json_error "GitHub 版本信息无法解析"

    latest_version=$(jq -r '.tag_name // empty' "$api_tmp")
    case "$latest_version" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) json_error "GitHub 返回了无效的 Mihomo 版本号" ;;
    esac

    asset_name="mihomo-linux-arm64-$latest_version.gz"
    asset_count=$(jq --arg name "$asset_name" '[.assets[]? | select(.name == $name)] | length' "$api_tmp")
    [ "$asset_count" = "1" ] || json_error "官方 Release 中没有唯一的 ARM64 核心文件"
    asset_url=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$api_tmp")
    asset_digest=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | (.digest // "")' "$api_tmp")
    expected_url="https://github.com/MetaCubeX/mihomo/releases/download/$latest_version/$asset_name"
    [ "$asset_url" = "$expected_url" ] || json_error "官方核心下载地址校验失败"
    case "$asset_digest" in
        sha256:[0-9a-fA-F][0-9a-fA-F]*) ;;
        *) json_error "官方 Release 未提供可验证的 SHA-256，已停止更新" ;;
    esac
    expected_sha=$(printf '%s' "${asset_digest#sha256:}" | tr 'A-F' 'a-f')
    [ "${#expected_sha}" = "64" ] || json_error "官方核心 SHA-256 格式无效"
    case "$expected_sha" in *[!0-9a-f]*) json_error "官方核心 SHA-256 格式无效" ;; esac
}

write_check_metadata() {
    current=$1
    latest=$2
    checked_at=$(date '+%Y-%m-%d %H:%M:%S %z')
    meta_tmp="$VAR_DIR/core-update.meta.$$"
    jq -n --arg currentVersion "$current" --arg latestVersion "$latest" \
        --arg checkedAt "$checked_at" \
        '{currentVersion:$currentVersion,latestVersion:$latestVersion,checkedAt:$checkedAt}' > "$meta_tmp"
    mv -f "$meta_tmp" "$META_FILE"
    meta_tmp=""
    chmod 0600 "$META_FILE"
}

control_command() (
    control_action=$1
    [ ! -e "/proc/$$/fd/9" ] || exec 9>&-
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" "$control_action"
)

do_status() {
    current=$(current_version)
    if [ -s "$META_FILE" ] && jq empty "$META_FILE" >/dev/null 2>&1; then
        latest=$(jq -r '.latestVersion // ""' "$META_FILE")
        checked=$(jq -r '.checkedAt // ""' "$META_FILE")
    else
        latest=""
        checked=""
    fi
    update_available=false
    [ -n "$latest" ] && [ "$latest" != "$current" ] && update_available=true
    jq -n --arg currentVersion "$current" --arg latestVersion "$latest" \
        --arg checkedAt "$checked" --argjson updateAvailable "$update_available" \
        '{ok:true,currentVersion:$currentVersion,latestVersion:$latestVersion,checkedAt:$checkedAt,updateAvailable:$updateAvailable}'
}

do_check() {
    fetch_latest
    current=$(current_version)
    write_check_metadata "$current" "$latest_version"
    update_available=false
    [ "$latest_version" != "$current" ] && update_available=true
    jq -n --arg currentVersion "$current" --arg latestVersion "$latest_version" \
        --argjson updateAvailable "$update_available" \
        '{ok:true,currentVersion:$currentVersion,latestVersion:$latestVersion,updateAvailable:$updateAvailable}'
}

do_update() {
    command -v flock >/dev/null 2>&1 || json_error "设备缺少 flock，无法安全更新核心"
    mkdir -p "$VAR_DIR"
    exec 9>"$VAR_DIR/core-update.lock"
    flock -n 9 || json_error "另一个核心更新任务正在运行"

    fetch_latest
    current=$(current_version)
    if [ "$current" = "$latest_version" ]; then
        write_check_metadata "$current" "$latest_version"
        jq -n --arg version "$current" '{ok:true,updated:false,currentVersion:$version,latestVersion:$version}'
        return
    fi

    if [ "$current" != "unknown" ]; then
        newest=$(printf '%s\n%s\n' "$current" "$latest_version" | sort -V | tail -n 1)
        [ "$newest" = "$latest_version" ] || json_error "设备核心版本比 GitHub 最新稳定版更新，拒绝自动降级"
    fi

    umask 077
    archive_tmp="$VAR_DIR/mihomo-$latest_version.gz.$$"
    binary_tmp="$VAR_DIR/mihomo-$latest_version.$$"
    test_log="$VAR_DIR/core-update-test.$$"
    download_https "$asset_url" "$archive_tmp" 'xiaomi-storage-mihomo-plugin/1.5.0' \
        || json_error "Mihomo 核心下载失败，请检查网络或代理节点"
    archive_size=$(wc -c < "$archive_tmp")
    [ "$archive_size" -gt 1048576 ] && [ "$archive_size" -le 104857600 ] \
        || json_error "下载的 Mihomo 核心大小异常"
    actual_sha=$(sha256sum "$archive_tmp" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] || json_error "Mihomo 核心 SHA-256 校验失败"
    gzip -t "$archive_tmp" >/dev/null 2>&1 || json_error "下载的 Mihomo 核心压缩包损坏"
    gzip -dc "$archive_tmp" > "$binary_tmp" || json_error "Mihomo 核心解压失败"
    chmod 0755 "$binary_tmp"
    binary_arch=$(file "$binary_tmp" 2>/dev/null || true)
    case "$binary_arch" in *ARM*aarch64*|*ARM64*) ;; *) json_error "下载的核心不是 ARM64 程序" ;; esac
    candidate_version=$($binary_tmp -v 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' | head -n 1 || true)
    [ "$candidate_version" = "$latest_version" ] || json_error "下载的核心版本与 Release 不一致"
    "$binary_tmp" -t -d "$ETC_DIR" -f "$CONFIG_FILE" > "$test_log" 2>&1 \
        || json_error "新核心无法通过当前配置校验，未执行替换"

    was_running=false
    if control_command status >/dev/null 2>&1; then
        was_running=true
    fi

    rollback="$VAR_DIR/mihomo.core.rollback"
    cp "$BIN" "$rollback" || json_error "无法备份当前 Mihomo 核心"
    chmod 0700 "$rollback"
    if [ "$was_running" = "true" ]; then
        control_command stop >/dev/null 2>&1 || json_error "无法停止当前 Mihomo 核心"
    fi
    if ! mv -f "$binary_tmp" "$BIN"; then
        [ "$was_running" = "true" ] && control_command start >/dev/null 2>&1 || true
        json_error "无法替换 Mihomo 核心"
    fi
    binary_tmp=""
    chmod 0755 "$BIN"

    if [ "$was_running" = "true" ] && ! control_command start >/dev/null 2>&1; then
        cp "$rollback" "$BIN"
        chmod 0755 "$BIN"
        control_command start >/dev/null 2>&1 || true
        json_error "新核心启动失败，已恢复旧核心"
    fi

    write_check_metadata "$latest_version" "$latest_version"
    jq -n --arg previousVersion "$current" --arg currentVersion "$latest_version" \
        '{ok:true,updated:true,previousVersion:$previousVersion,currentVersion:$currentVersion,latestVersion:$currentVersion}'
}

case "${1:-status}" in
    status) do_status ;;
    check) do_check ;;
    update) do_update ;;
    *) json_error "未知核心更新操作" ;;
esac
