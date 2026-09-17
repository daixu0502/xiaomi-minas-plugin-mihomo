#!/usr/bin/env bash
set -Eeuo pipefail

CORE_VERSION="v1.19.31"
CORE_ASSET="mihomo-linux-arm64-${CORE_VERSION}.gz"
CORE_SHA256="9e0f11afbf38426b8bd88fdc594678f8161c57eccb4e1b77acb12b493904f1d4"
CORE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${CORE_VERSION}/${CORE_ASSET}"

NAS_IP="${1:-}"
PLUGIN_USER="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
CORE_GZ="$CACHE_DIR/$CORE_ASSET"

usage() {
    cat <<'EOF'
用法：
  bash deploy.sh [小米智能存储IP] [插件用户]

示例：
  bash deploy.sh
  bash deploy.sh 192.168.31.100 u123456789

未指定小米智能存储 IP 时，远程安装会在终端提示输入。
未指定插件用户时，脚本会扫描设备上的用户并让你选择。
脚本会下载并校验官方 Mihomo ARM64 核心，然后通过 root SSH 安装。
如果脚本正以 root 身份运行在小米智能存储本机，则自动直接安装，
不再通过 SSH 连接设备自身。
不会重启设备，也不会默认接管 NAS 或局域网流量。
EOF
}

if [[ "$NAS_IP" == "-h" || "$NAS_IP" == "--help" ]]; then
    usage
    exit 0
fi

DIRECT_INSTALL=false
if [[ "$(id -u)" == "0" ]] \
   && command -v plugincenter >/dev/null 2>&1 \
   && [[ -f /etc/config/plugin ]]; then
    DIRECT_INSTALL=true
    if [[ "${1:-}" =~ ^u[0-9]+$ ]]; then
        PLUGIN_USER="$1"
        NAS_IP=""
    fi
fi

if [[ "$DIRECT_INSTALL" != "true" && -z "$NAS_IP" ]]; then
    if [[ ! -t 0 ]]; then
        echo "错误：未提供小米智能存储 IP；非交互环境请运行：bash deploy.sh <设备IP> [插件用户]" >&2
        exit 2
    fi
    read -r -p "请输入小米智能存储 IP：" NAS_IP
fi

required_commands=(gzip sha256sum mktemp)
if [[ "$DIRECT_INSTALL" != "true" ]]; then
    required_commands+=(ssh scp tar)
fi

for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "错误：未找到命令：$command_name" >&2
        exit 3
    fi
done

ssh_target="${NAS_IP:+root@$NAS_IP}"
ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

choose_plugin_user() {
    local heading=$1
    shift
    local choices=("$@")
    if (( ${#choices[@]} == 0 )); then
        echo "错误：没有扫描到可安装插件的 u 数字用户。" >&2
        exit 2
    fi
    if (( ${#choices[@]} == 1 )); then
        PLUGIN_USER="${choices[0]}"
        echo "自动选择唯一用户：$PLUGIN_USER"
        return
    fi
    if [[ ! -t 0 ]]; then
        echo "错误：扫描到多个用户，非交互环境请显式指定用户，例如：bash deploy.sh $NAS_IP ${choices[0]}" >&2
        exit 2
    fi
    echo "$heading"
    PS3="请输入序号："
    select selected_user in "${choices[@]}"; do
        if [[ -n "$selected_user" ]]; then
            PLUGIN_USER="$selected_user"
            break
        fi
        echo "无效序号，请重新选择。"
    done
}

if [[ "$DIRECT_INSTALL" != "true" ]]; then
    if [[ ! "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "错误：无效的 IPv4 地址：$NAS_IP" >&2
        exit 2
    fi
    IFS='.' read -r -a ip_octets <<< "$NAS_IP"
    for octet in "${ip_octets[@]}"; do
        if (( 10#$octet > 255 )); then
            echo "错误：无效的 IPv4 地址：$NAS_IP" >&2
            exit 2
        fi
    done
fi

if [[ -z "$PLUGIN_USER" ]]; then
    scanned_users=()
    if [[ "$DIRECT_INSTALL" == "true" ]]; then
        shopt -s nullglob
        for list_file in /data/plugin/u*.list; do
            candidate="${list_file##*/}"
            candidate="${candidate%.list}"
            [[ "$candidate" =~ ^u[0-9]+$ ]] && [[ -d "/home/$candidate" ]] && scanned_users+=("$candidate")
        done
        shopt -u nullglob
    else
        mapfile -t scanned_users < <(ssh "${ssh_options[@]}" "$ssh_target" \
            'for list_file in /data/plugin/u*.list; do candidate=${list_file##*/}; candidate=${candidate%.list}; case "$candidate" in u[0-9]*) [ -d "/home/$candidate" ] && printf "%s\n" "$candidate" ;; esac; done' | sort -u)
    fi
    choose_plugin_user "请选择要安装 Mihomo 插件的用户：" "${scanned_users[@]}"
fi

if [[ ! "$PLUGIN_USER" =~ ^u[0-9]+$ ]]; then
    echo "错误：插件用户应类似 u123456789，当前值：$PLUGIN_USER" >&2
    exit 2
fi

mkdir -p "$CACHE_DIR"

verify_core() {
    printf '%s  %s\n' "$CORE_SHA256" "$CORE_GZ" | sha256sum -c - >/dev/null 2>&1
}

if [[ ! -f "$CORE_GZ" ]] || ! verify_core; then
    rm -f "$CORE_GZ.tmp"
    echo "正在下载 Mihomo $CORE_VERSION ARM64 核心……"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$CORE_GZ.tmp" "$CORE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$CORE_GZ.tmp" "$CORE_URL"
    else
        echo "错误：需要 curl 或 wget 下载核心。" >&2
        exit 3
    fi
    mv -f "$CORE_GZ.tmp" "$CORE_GZ"
fi

if ! verify_core; then
    echo "错误：Mihomo 核心 SHA-256 校验失败，已停止安装。" >&2
    echo "期望：$CORE_SHA256" >&2
    sha256sum "$CORE_GZ" >&2 || true
    exit 4
fi

work_dir="$(mktemp -d)"
cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == /tmp/* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT HUP INT TERM

stage_dir="$work_dir/mihomo-plugin"
mkdir -p "$stage_dir"
cp -R "$SCRIPT_DIR/payload" "$stage_dir/payload"
cp "$SCRIPT_DIR/remote-install.sh" "$stage_dir/remote-install.sh"
gzip -dc "$CORE_GZ" > "$stage_dir/payload/files/mihomo"
chmod 0755 "$stage_dir/payload/files/mihomo"

if [[ "$DIRECT_INSTALL" == "true" ]]; then
    echo "检测到正在小米智能存储本机运行，将直接安装（不使用 SSH）……"
    /bin/sh "$stage_dir/remote-install.sh" "$PLUGIN_USER"
    echo
    echo "安装完成。请刷新小米智能存储 APP，在插件列表中打开“Mihomo”。"
    echo "本机代理使用安装器分配的用户专属端口；未开启 TUN，也未对局域网开放。"
    exit 0
fi

archive="$work_dir/mihomo-plugin.tgz"
tar -C "$work_dir" -czf "$archive" mihomo-plugin

remote_suffix="$$-$RANDOM"
remote_archive="/tmp/mihomo-plugin-$remote_suffix.tgz"
remote_dir="/tmp/mihomo-plugin-$remote_suffix"

echo "正在上传到 $ssh_target……"
scp "${ssh_options[@]}" "$archive" "$ssh_target:$remote_archive"

echo "正在安装 APP 插件……"
ssh "${ssh_options[@]}" "$ssh_target" \
    "REMOTE_ARCHIVE='$remote_archive' REMOTE_DIR='$remote_dir' PLUGIN_USER='$PLUGIN_USER' /bin/sh -s" <<'REMOTE_WRAPPER'
set -eu

cleanup_remote() {
    case "$REMOTE_DIR" in
        /tmp/mihomo-plugin-*) rm -rf "$REMOTE_DIR" ;;
    esac
    case "$REMOTE_ARCHIVE" in
        /tmp/mihomo-plugin-*.tgz) rm -f "$REMOTE_ARCHIVE" ;;
    esac
}
trap cleanup_remote EXIT HUP INT TERM

mkdir -p "$REMOTE_DIR"
tar -xzf "$REMOTE_ARCHIVE" -C "$REMOTE_DIR"
/bin/sh "$REMOTE_DIR/mihomo-plugin/remote-install.sh" "$PLUGIN_USER"
REMOTE_WRAPPER

echo
echo "安装完成。请刷新小米智能存储 APP，在插件列表中打开“Mihomo”。"
echo "本机代理使用安装器分配的用户专属端口；未开启 TUN，也未对局域网开放。"
