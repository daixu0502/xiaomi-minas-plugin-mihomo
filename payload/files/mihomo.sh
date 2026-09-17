#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
SRC_DIR=$(dirname "$SCRIPT_DIR")
PLUGIN_HOME=${PLUG_HOME_DIR:-}

if [ -z "$PLUGIN_HOME" ]; then
    plugin_user=$(printf '%s\n' "$SRC_DIR" | sed -n 's#^/nas/pool[^/]*/\(u[0-9][0-9]*\)/plugin/pluginsrc/mihomo$#\1#p')
    [ -n "$plugin_user" ] || plugin_user=$(id -un)
    PLUGIN_HOME="/home/$plugin_user/plugin/mihomo"
fi

BIN="$SCRIPT_DIR/mihomo"
ETC_DIR="$PLUGIN_HOME/etc"
VAR_DIR="$PLUGIN_HOME/var"
CONFIG_FILE="$ETC_DIR/config.yaml"
SECRET_FILE="$ETC_DIR/api.secret"
PORTS_FILE="$ETC_DIR/ports.env"
PID_FILE="$VAR_DIR/mihomo.pid"
LOG_FILE="$VAR_DIR/mihomo.log"
MIXED_PORT=7890
CONTROLLER_PORT=9090
if [ -r "$PORTS_FILE" ]; then
    saved_mixed=$(sed -n 's/^MIXED_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" | head -n 1)
    saved_controller=$(sed -n 's/^CONTROLLER_PORT=\([0-9][0-9]*\)$/\1/p' "$PORTS_FILE" | head -n 1)
    [ -n "$saved_mixed" ] && MIXED_PORT="$saved_mixed"
    [ -n "$saved_controller" ] && CONTROLLER_PORT="$saved_controller"
fi

log() {
    logger -t plugin.mihomo -p user.info "mihomo: $*"
}

is_managed_pid() {
    managed_pid=$1
    case "$managed_pid" in *[!0-9]*|'') return 1 ;; esac
    kill -0 "$managed_pid" 2>/dev/null || return 1
    [ -r "/proc/$managed_pid/cmdline" ] || return 1
    managed_cmdline=$(tr '\000' ' ' < "/proc/$managed_pid/cmdline" 2>/dev/null || true)
    managed_executable=${managed_cmdline%% *}
    case "$managed_executable" in
        "$BIN"|"$PLUGIN_HOME/src/files/mihomo")
            return 0
            ;;
    esac
    return 1
}

managed_pids() {
    for proc_dir in /proc/[0-9]*; do
        managed_pid=${proc_dir#/proc/}
        if is_managed_pid "$managed_pid"; then
            printf '%s\n' "$managed_pid"
        fi
    done
}

is_running() {
    if [ -s "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if is_managed_pid "$pid"; then
            return 0
        fi
    fi
    pid=$(managed_pids | head -n 1)
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid" > "$PID_FILE"
    chmod 0600 "$PID_FILE"
    return 0
}

start_core() {
    mkdir -p "$ETC_DIR" "$VAR_DIR"
    if is_running; then
        log "already running, pid $(cat "$PID_FILE")"
        return 0
    fi
    rm -f "$PID_FILE"

    [ -x "$BIN" ] || {
        log "binary not executable: $BIN"
        return 1
    }
    [ -s "$CONFIG_FILE" ] || {
        log "missing config: $CONFIG_FILE"
        return 1
    }
    [ -s "$SECRET_FILE" ] || {
        log "missing API secret: $SECRET_FILE"
        return 1
    }

    secret=$(tr -d '\r\n' < "$SECRET_FILE")
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 5242880 ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    export HOME="$(dirname "$(dirname "$PLUGIN_HOME")")"
    printf '\n[%s] starting Mihomo\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"

    nohup "$BIN" \
        -d "$ETC_DIR" \
        -f "$CONFIG_FILE" \
        -ext-ctl "127.0.0.1:$CONTROLLER_PORT" \
        -secret "$secret" \
        >> "$LOG_FILE" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    chmod 0600 "$PID_FILE"

    wait_count=0
    while [ "$wait_count" -lt 20 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            log "process exited during startup"
            return 1
        fi
        if curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
            -H "Authorization: Bearer $secret" \
            "http://127.0.0.1:$CONTROLLER_PORT/version" >/dev/null 2>&1; then
            log "started, pid $pid"
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    log "controller did not become ready; process stopped"
    return 1
}

stop_core() {
    pids=$(managed_pids)
    if [ -z "$pids" ]; then
        rm -f "$PID_FILE"
        return 0
    fi
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    wait_count=0
    while [ "$wait_count" -lt 10 ]; do
        still_running=false
        for pid in $pids; do
            if is_managed_pid "$pid"; then
                still_running=true
            fi
        done
        if [ "$still_running" = "false" ]; then
            rm -f "$PID_FILE"
            log "stopped"
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    for pid in $pids; do
        if is_managed_pid "$pid"; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    rm -f "$PID_FILE"
    log "force stopped"
}

case "${1:-}" in
    start|enable)
        start_core
        ;;
    stop|disable)
        stop_core
        ;;
    restart)
        stop_core
        start_core
        ;;
    status)
        if is_running; then
            printf 'running (pid %s)\n' "$(cat "$PID_FILE")"
            exit 0
        fi
        echo "stopped"
        exit 1
        ;;
    *)
        echo "用法：$0 {start|stop|restart|status}" >&2
        exit 2
        ;;
esac
