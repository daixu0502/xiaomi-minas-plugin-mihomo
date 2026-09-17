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
GEOIP_FILE="$ETC_DIR/GeoIP.dat"
GEOSITE_FILE="$ETC_DIR/GeoSite.dat"
META_FILE="$ETC_DIR/geodata.meta.json"
POLICY_FILE="$ETC_DIR/geodata-policy.meta.json"
RELEASE_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
RELEASE_API="https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest"

geoip_tmp=""
geosite_tmp=""
release_tmp=""
config_tmp=""
test_log=""
meta_tmp=""

cleanup() {
    for cleanup_file in "$geoip_tmp" "$geosite_tmp" "$release_tmp" "$config_tmp" "$test_log" "$meta_tmp"; do
        [ -n "$cleanup_file" ] && rm -f "$cleanup_file"
    done
    return 0
}
trap cleanup EXIT HUP INT TERM

json_error() {
    jq -n --arg message "$1" '{ok:false,error:$message}'
    exit 0
}

download_https() {
    download_url=$1
    download_target=$2
    curl --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 \
        --user-agent 'xiaomi-storage-mihomo-plugin/1.5.0' \
        --proxy http://127.0.0.1:7890 \
        --output "$download_target" -- "$download_url" >/dev/null 2>&1
}

fetch_release_metadata() {
    release_tmp="$VAR_DIR/geodata-release.$$"
    download_https "$RELEASE_API" "$release_tmp" \
        || json_error "无法连接 GitHub 获取 Geo 数据发布信息"
    [ -s "$release_tmp" ] || json_error "GitHub 返回了空的 Geo 数据发布信息"
    [ "$(wc -c < "$release_tmp")" -le 2097152 ] || json_error "Geo 数据发布信息异常"
    jq empty "$release_tmp" >/dev/null 2>&1 || json_error "Geo 数据发布信息无法解析"
}

download_verified_file() {
    remote_name=$1
    output_file=$2
    asset_count=$(jq --arg name "$remote_name" '[.assets[]? | select(.name == $name)] | length' "$release_tmp")
    [ "$asset_count" = "1" ] || json_error "官方 Release 中没有唯一的 $remote_name"
    asset_url=$(jq -r --arg name "$remote_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_tmp")
    asset_digest=$(jq -r --arg name "$remote_name" '.assets[] | select(.name == $name) | (.digest // "")' "$release_tmp")
    [ "$asset_url" = "$RELEASE_BASE/$remote_name" ] || json_error "$remote_name 官方下载地址校验失败"
    case "$asset_digest" in
        sha256:[0-9a-fA-F][0-9a-fA-F]*) ;;
        *) json_error "官方 Release 未提供 $remote_name 的 SHA-256，已停止更新" ;;
    esac
    expected_sha=$(printf '%s' "${asset_digest#sha256:}" | tr 'A-F' 'a-f')
    [ "${#expected_sha}" = "64" ] || json_error "$remote_name 的 SHA-256 格式无效"
    case "$expected_sha" in *[!0-9a-f]*) json_error "$remote_name 的 SHA-256 格式无效" ;; esac
    download_https "$asset_url" "$output_file" \
        || json_error "$remote_name 通过 PROXY 下载失败，请检查 Mihomo 节点"
    file_size=$(wc -c < "$output_file")
    [ "$file_size" -gt 1024 ] && [ "$file_size" -le 134217728 ] \
        || json_error "$remote_name 文件大小异常"
    actual_sha=$(sha256sum "$output_file" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] || json_error "$remote_name SHA-256 校验失败"
}

control_status() (
    [ ! -e "/proc/$$/fd/9" ] || exec 9>&-
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" status >/dev/null 2>&1
)

control_restart() (
    [ ! -e "/proc/$$/fd/9" ] || exec 9>&-
    PLUG_USER="$plugin_user" PLUG_NAME=mihomo PLUG_HOME_DIR="$PLUGIN_HOME" PLUG_SRC_DIR="$SRC_DIR" \
        "$CONTROL" restart >/dev/null 2>&1
)

do_status() {
    geoip_present=false
    geosite_present=false
    geoip_size=0
    geosite_size=0
    [ -s "$GEOIP_FILE" ] && geoip_present=true && geoip_size=$(wc -c < "$GEOIP_FILE")
    [ -s "$GEOSITE_FILE" ] && geosite_present=true && geosite_size=$(wc -c < "$GEOSITE_FILE")
    updated_at=""
    if [ -s "$META_FILE" ] && jq empty "$META_FILE" >/dev/null 2>&1; then
        updated_at=$(jq -r '.updatedAt // ""' "$META_FILE")
    fi
    policy="custom"
    applied_at=""
    if [ -s "$POLICY_FILE" ] && jq empty "$POLICY_FILE" >/dev/null 2>&1; then
        policy=$(jq -r '.policy // "custom"' "$POLICY_FILE")
        applied_at=$(jq -r '.appliedAt // ""' "$POLICY_FILE")
    fi
    jq -n --argjson geoipPresent "$geoip_present" --argjson geositePresent "$geosite_present" \
        --argjson geoipSize "$geoip_size" --argjson geositeSize "$geosite_size" \
        --arg updatedAt "$updated_at" --arg policy "$policy" --arg appliedAt "$applied_at" \
        '{ok:true,geoipPresent:$geoipPresent,geositePresent:$geositePresent,geoipSize:$geoipSize,geositeSize:$geositeSize,updatedAt:$updatedAt,policy:$policy,appliedAt:$appliedAt}'
}

restore_file() {
    restore_backup=$1
    restore_target=$2
    restore_had=$3
    if [ "$restore_had" = "true" ]; then
        cp "$restore_backup" "$restore_target"
        chmod 0600 "$restore_target"
    else
        rm -f "$restore_target"
    fi
}

do_update() {
    command -v flock >/dev/null 2>&1 || json_error "设备缺少 flock，无法安全更新 Geo 数据"
    mkdir -p "$ETC_DIR" "$VAR_DIR"
    exec 9>"$VAR_DIR/geodata-update.lock"
    flock -n 9 || json_error "另一个 Geo 数据更新任务正在运行"
    umask 077
    geoip_tmp="$VAR_DIR/GeoIP.dat.$$"
    geosite_tmp="$VAR_DIR/GeoSite.dat.$$"
    test_log="$VAR_DIR/geodata-test.$$"
    fetch_release_metadata
    download_verified_file geoip.dat "$geoip_tmp"
    geoip_sha=$actual_sha
    download_verified_file geosite.dat "$geosite_tmp"
    geosite_sha=$actual_sha

    geoip_backup="$VAR_DIR/GeoIP.dat.backup.$$"
    geosite_backup="$VAR_DIR/GeoSite.dat.backup.$$"
    geoip_had=false
    geosite_had=false
    [ -f "$GEOIP_FILE" ] && cp "$GEOIP_FILE" "$geoip_backup" && geoip_had=true
    [ -f "$GEOSITE_FILE" ] && cp "$GEOSITE_FILE" "$geosite_backup" && geosite_had=true
    mv -f "$geoip_tmp" "$GEOIP_FILE"
    geoip_tmp=""
    mv -f "$geosite_tmp" "$GEOSITE_FILE"
    geosite_tmp=""
    chmod 0600 "$GEOIP_FILE" "$GEOSITE_FILE"

    if ! "$BIN" -t -d "$ETC_DIR" -f "$CONFIG_FILE" > "$test_log" 2>&1; then
        restore_file "$geoip_backup" "$GEOIP_FILE" "$geoip_had"
        restore_file "$geosite_backup" "$GEOSITE_FILE" "$geosite_had"
        rm -f "$geoip_backup" "$geosite_backup"
        json_error "新 Geo 数据无法通过当前配置校验，已保留旧文件"
    fi
    was_running=false
    control_status && was_running=true
    if [ "$was_running" = "true" ] && ! control_restart; then
        restore_file "$geoip_backup" "$GEOIP_FILE" "$geoip_had"
        restore_file "$geosite_backup" "$GEOSITE_FILE" "$geosite_had"
        control_restart || true
        rm -f "$geoip_backup" "$geosite_backup"
        json_error "Geo 数据更新后核心启动失败，已恢复旧文件"
    fi
    rm -f "$geoip_backup" "$geosite_backup"

    updated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
    meta_tmp="$VAR_DIR/geodata.meta.$$"
    jq -n --arg updatedAt "$updated_at" --arg geoipSha256 "$geoip_sha" \
        --arg geositeSha256 "$geosite_sha" \
        '{updatedAt:$updatedAt,geoipSha256:$geoipSha256,geositeSha256:$geositeSha256}' > "$meta_tmp"
    mv -f "$meta_tmp" "$META_FILE"
    meta_tmp=""
    chmod 0600 "$META_FILE"
    jq -n --arg updatedAt "$updated_at" '{ok:true,updated:true,updatedAt:$updatedAt,restarted:true}'
}

do_apply_policy() {
    policy=${1:-}
    case "$policy" in
        cn_direct|lan_direct|direct) ;;
        *) json_error "不支持的 Geo 规则策略" ;;
    esac
    if [ "$policy" != "direct" ]; then
        [ -s "$GEOIP_FILE" ] && [ -s "$GEOSITE_FILE" ] \
            || json_error "请先更新 GeoIP 和 GeoSite 数据"
    fi
    mkdir -p "$VAR_DIR"
    umask 077
    config_tmp="$VAR_DIR/config.geodata.$$"
    test_log="$VAR_DIR/geodata-policy-test.$$"
    awk -v policy="$policy" '
        function emit_rules() {
            print "rules:"
            if (policy == "cn_direct") {
                print "  - GEOSITE,private,DIRECT"
                print "  - GEOIP,private,DIRECT,no-resolve"
                print "  - GEOSITE,cn,DIRECT"
                print "  - GEOIP,cn,DIRECT,no-resolve"
                print "  - MATCH,PROXY"
            } else if (policy == "lan_direct") {
                print "  - GEOSITE,private,DIRECT"
                print "  - GEOIP,private,DIRECT,no-resolve"
                print "  - MATCH,PROXY"
            } else {
                print "  - MATCH,DIRECT"
            }
        }
        BEGIN { in_rules=0; seen_rules=0; seen_mode=0; seen_geo_mode=0; seen_geo_loader=0 }
        /^mode:[[:space:]]*/ { print "mode: rule"; seen_mode=1; next }
        /^geodata-mode:[[:space:]]*/ { print "geodata-mode: true"; seen_geo_mode=1; next }
        /^geodata-loader:[[:space:]]*/ { print "geodata-loader: memconservative"; seen_geo_loader=1; next }
        /^rules:[[:space:]]*/ { emit_rules(); in_rules=1; seen_rules=1; next }
        in_rules {
            if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*/) in_rules=0
            else next
        }
        { print }
        END {
            if (!seen_mode) print "mode: rule"
            if (!seen_geo_mode) print "geodata-mode: true"
            if (!seen_geo_loader) print "geodata-loader: memconservative"
            if (!seen_rules) emit_rules()
        }
    ' "$CONFIG_FILE" > "$config_tmp" || json_error "生成 Geo 规则配置失败"
    chmod 0600 "$config_tmp"
    if ! "$BIN" -t -d "$ETC_DIR" -f "$config_tmp" > "$test_log" 2>&1; then
        json_error "Geo 规则无法通过 Mihomo 校验；请确认配置中存在 PROXY 策略组"
    fi

    before_file="$ETC_DIR/config.before-geodata-policy.yaml"
    [ -f "$before_file" ] || cp "$CONFIG_FILE" "$before_file"
    cp "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak"
    mv -f "$config_tmp" "$CONFIG_FILE"
    config_tmp=""
    chmod 0600 "$CONFIG_FILE" "$ETC_DIR/config.yaml.bak" "$before_file"
    was_running=false
    control_status && was_running=true
    if [ "$was_running" = "true" ] && ! control_restart; then
        cp "$ETC_DIR/config.yaml.bak" "$CONFIG_FILE"
        control_restart || true
        json_error "Geo 规则应用后核心启动失败，已恢复旧配置"
    fi

    applied_at=$(date '+%Y-%m-%d %H:%M:%S %z')
    meta_tmp="$VAR_DIR/geodata-policy.meta.$$"
    jq -n --arg policy "$policy" --arg appliedAt "$applied_at" \
        '{policy:$policy,appliedAt:$appliedAt}' > "$meta_tmp"
    mv -f "$meta_tmp" "$POLICY_FILE"
    meta_tmp=""
    chmod 0600 "$POLICY_FILE"
    jq -n --arg policy "$policy" --arg appliedAt "$applied_at" \
        '{ok:true,applied:true,policy:$policy,appliedAt:$appliedAt,restarted:true}'
}

case "${1:-status}" in
    status) do_status ;;
    update) do_update ;;
    apply) do_apply_policy "${2:-}" ;;
    *) json_error "未知 Geo 数据操作" ;;
esac
