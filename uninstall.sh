#!/usr/bin/env bash
set -Eeuo pipefail

NAS_IP="${1:-}"
PLUGIN_USER="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIRECT_UNINSTALL=false
if [[ "$(id -u)" == "0" ]] \
   && command -v plugincenter >/dev/null 2>&1 \
   && [[ -f /etc/config/plugin ]]; then
    DIRECT_UNINSTALL=true
    if [[ "${1:-}" =~ ^u[0-9]+$ ]]; then
        PLUGIN_USER="$1"
        NAS_IP=""
    fi
fi

if [[ "$DIRECT_UNINSTALL" != "true" && -z "$NAS_IP" ]]; then
    if [[ ! -t 0 ]]; then
        echo "错误：未提供小米智能存储 IP；非交互环境请运行：bash uninstall.sh <设备IP> [插件用户]" >&2
        exit 2
    fi
    read -r -p "请输入小米智能存储 IP：" NAS_IP
fi

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

choose_plugin_user() {
    local choices=("$@")
    if (( ${#choices[@]} == 0 )); then
        echo "没有扫描到已安装 Mihomo 插件的用户。" >&2
        exit 2
    fi
    if (( ${#choices[@]} == 1 )); then
        PLUGIN_USER="${choices[0]}"
        echo "自动选择唯一已安装用户：$PLUGIN_USER"
        return
    fi
    if [[ ! -t 0 ]]; then
        echo "错误：扫描到多个已安装用户，非交互环境请显式指定用户。" >&2
        exit 2
    fi
    echo "请选择要卸载 Mihomo 插件的用户："
    PS3="请输入序号："
    select selected_user in "${choices[@]}"; do
        if [[ -n "$selected_user" ]]; then
            PLUGIN_USER="$selected_user"
            break
        fi
        echo "无效序号，请重新选择。"
    done
}

if [[ "$DIRECT_UNINSTALL" != "true" ]]; then
    if [[ ! "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "错误：无效的 IPv4 地址：$NAS_IP" >&2
        exit 2
    fi
    for command_name in ssh sort; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "错误：未找到命令：$command_name" >&2
            exit 3
        }
    done
fi

if [[ -z "$PLUGIN_USER" ]]; then
    installed_users=()
    if [[ "$DIRECT_UNINSTALL" == "true" ]]; then
        shopt -s nullglob
        for list_file in /data/plugin/u*.list; do
            candidate="${list_file##*/}"
            candidate="${candidate%.list}"
            if [[ "$candidate" =~ ^u[0-9]+$ ]] && \
               { jq -e '.mihomo.install == true' "$list_file" >/dev/null 2>&1 || [[ -d "/home/$candidate/plugin/mihomo" ]]; }; then
                installed_users+=("$candidate")
            fi
        done
        shopt -u nullglob
    else
        mapfile -t installed_users < <(ssh "${ssh_options[@]}" "root@$NAS_IP" \
            'for list_file in /data/plugin/u*.list; do candidate=${list_file##*/}; candidate=${candidate%.list}; case "$candidate" in u[0-9]*) if jq -e ".mihomo.install == true" "$list_file" >/dev/null 2>&1 || [ -d "/home/$candidate/plugin/mihomo" ]; then printf "%s\n" "$candidate"; fi ;; esac; done' | sort -u)
    fi
    choose_plugin_user "${installed_users[@]}"
fi

if [[ "$DIRECT_UNINSTALL" == "true" ]]; then
    if [[ ! "$PLUGIN_USER" =~ ^u[0-9]+$ ]]; then
        echo "错误：插件用户应类似 u123456789。" >&2
        exit 2
    fi
    if [[ ! -f "$SCRIPT_DIR/remote-uninstall.sh" ]]; then
        echo "错误：缺少 $SCRIPT_DIR/remote-uninstall.sh" >&2
        exit 3
    fi
    echo "检测到正在小米智能存储本机运行，将直接卸载（不使用 SSH）。"
    exec /bin/sh "$SCRIPT_DIR/remote-uninstall.sh" "$PLUGIN_USER"
fi

if [[ ! "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "错误：无效的 IPv4 地址：$NAS_IP" >&2
    exit 2
fi
if [[ ! "$PLUGIN_USER" =~ ^u[0-9]+$ ]]; then
    echo "错误：插件用户应类似 u123456789。" >&2
    exit 2
fi

echo "将卸载 $PLUGIN_USER 的 Mihomo 插件；配置、订阅和手动节点会备份到该用户的 plugin/.reserve/mihomo。"
ssh "${ssh_options[@]}" "root@$NAS_IP" /bin/sh -s -- "$PLUGIN_USER" < "$SCRIPT_DIR/remote-uninstall.sh"
