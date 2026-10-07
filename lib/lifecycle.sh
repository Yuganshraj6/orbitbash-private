# OrbitBash lifecycle, management, scheduling and daemon.

_tunnel_start() {
    local name="$1" mode port hostport pid target logf
    mode=$(vps_get_meta "$name" URL_MODE || printf 'none')
    [[ "$mode" != none ]] || return 0
    hostport=$(vps_get_meta "$name" URL_HOST_PORT || printf '0')
    port=$(vps_get_meta "$name" URL_GUEST_PORT || printf '80')
    [[ "$hostport" =~ ^[0-9]+$ ]] || return 0
    target="http://127.0.0.1:${hostport}"
    logf="${BASE_DIR}/vps/${name}/tunnel.log"
    case "$mode" in
        cloudflared)
            command -v cloudflared >/dev/null 2>&1 || { log_msg WARN "VPS=${name} tunnel requested but cloudflared is unavailable"; return 0; }
            [[ -f "${BASE_DIR}/run/tunnel-${name}.pid" ]] && kill -0 "$(cat "${BASE_DIR}/run/tunnel-${name}.pid" 2>/dev/null)" 2>/dev/null && return 0
            nohup cloudflared tunnel --no-autoupdate --url "$target" >"$logf" 2>&1 &
            pid=$!; printf '%s\n' "$pid" > "${BASE_DIR}/run/tunnel-${name}.pid"
            ( sleep 3; local url; url=$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$logf" 2>/dev/null | head -1 || true); [[ -n "$url" ]] && vps_set_meta "$name" URL "$url" ) &
            ;;
        caddy)
            local domain; domain=$(config_get caddy_domain || true)
            command -v caddy >/dev/null 2>&1 && [[ -n "$domain" ]] || { log_msg WARN "VPS=${name} caddy tunnel requested but caddy_domain/caddy is missing"; return 0; }
            nohup caddy reverse-proxy --from "$domain" --to "$target" >"$logf" 2>&1 &
            pid=$!; printf '%s\n' "$pid" > "${BASE_DIR}/run/tunnel-${name}.pid"; vps_set_meta "$name" URL "https://${domain}"
            ;;
    esac
    log_msg INFO "VPS=${name} tunnel mode=${mode} target_port=${port}"
}

_tunnel_stop() {
    local name="$1" f pid; f="${BASE_DIR}/run/tunnel-${name}.pid"
    if [[ -f "$f" ]]; then pid=$(cat "$f" 2>/dev/null || true); [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true; rm -f "$f"; fi
}

_manage_pick_vps() {
    local -a list=(); local d
    for d in "${BASE_DIR}/vps/"*; do [[ -f "$d/meta.env" ]] && list+=("$(basename "$d")"); done
    list+=('Back');
    (( ${#list[@]} > 1 )) || { echo 'No VPSes.'; ui_pause; return 1; }
    ui_menu 'Select VPS' "${list[@]}"; local c=$?
    (( c == ${#list[@]}-1 || c == 255 )) && return 1
    MANAGE_VPS="${list[$c]}"
}

_manage_transition_start() {
    local name="$1" state; state=$(vps_get_meta "$name" STATE)
    [[ "$state" == created || "$state" == stopped || "$state" == renewed ]] || { echo "Cannot start from state: $state"; return 1; }
    echo 'Estimated time: ~5–30s'
    backend_start "$name" || return 1
    vps_set_meta "$name" STATE running; _tunnel_start "$name"
 vps_set_meta "$name" LAST_START "$(date +%s)"; vps_log_transition "$name" "$state" running
}

_manage_transition_stop() {
    local name="$1" state; state=$(vps_get_meta "$name" STATE)
    [[ "$state" == running ]] || { echo "VPS is not running."; return 0; }
    echo 'Estimated time: ~10s'
    ui_confirm 'Stop VPS gracefully, then force-stop if it does not exit?' || return 0
    local last run now
    _tunnel_stop "$name"; backend_stop "$name" || backend_force_stop "$name" || return 1
    run=$(vps_get_meta "$name" RUN_SECONDS || printf '0'); last=$(vps_get_meta "$name" LAST_START || printf '0'); now=$(date +%s)
    [[ "$last" =~ ^[0-9]+$ && "$run" =~ ^[0-9]+$ ]] && (( now > last )) && run=$((run+now-last)) || true
    vps_set_meta "$name" RUN_SECONDS "$run"; vps_set_meta "$name" LAST_START 0; vps_set_meta "$name" STATE stopped; vps_log_transition "$name" running stopped
}

_manage_transition_force() {
    local name="$1" state; state=$(vps_get_meta "$name" STATE)
    echo 'Estimated time: ~5s'
    ui_confirm 'Force stop this VPS?' || return 0
    _tunnel_stop "$name"; backend_force_stop "$name" || true
    [[ "$state" == running ]] && vps_set_meta "$name" LAST_START 0
    vps_set_meta "$name" STATE stopped; vps_log_transition "$name" "$state" stopped
}

_manage_transition_restart() {
    local name="$1"; echo 'Estimated time: ~15s'; ui_confirm 'Restart this VPS?' || return 0
    _tunnel_stop "$name"; backend_stop "$name" || true; sleep 1; backend_start "$name" || return 1; _tunnel_start "$name"
    vps_set_meta "$name" STATE running; vps_set_meta "$name" LAST_START "$(date +%s)"; log_msg INFO "VPS=${name} restarted"
}

_manage_schedule() {
    local name="$1" current entry type time new list=''
    current=$(vps_get_meta "$name" SCHEDULES || true)
    ui_clear; ui_paint_bg; c acc; ui_center_text "Schedules — $name"; c reset; echo
    printf 'Current: %s\n\n' "${current:-none}"
    local -a opts=('Add schedule' 'Remove schedule' 'Back'); ui_menu 'Schedule' "${opts[@]}"; local c=$?
    case "$c" in
        0)
            ui_prompt 'Action (start/stop/restart/backup)' type
            [[ "$type" == start || "$type" == stop || "$type" == restart || "$type" == backup ]] || { echo 'Invalid action.'; ui_pause; return; }
            ui_prompt 'Time HH:MM' time
            [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo 'Invalid time.'; ui_pause; return; }
            [[ -n "$current" ]] && new="${current}|"; new+="${type}@${time}"; vps_set_meta "$name" SCHEDULES "$new"; log_msg INFO "Schedule added for ${name}: ${type}@${time}";;
        1)
            [[ -n "$current" ]] || { echo 'No schedules.'; ui_pause; return; }
            ui_prompt 'Exact entry to remove (e.g. stop@22:00)' entry
            list=''; IFS='|' read -ra arr <<< "$current"; for x in "${arr[@]}"; do [[ "$x" == "$entry" ]] || { [[ -n "$list" ]] && list+='|'; list+="$x"; }; done
            vps_set_meta "$name" SCHEDULES "$list";;
    esac
}

_manage_auto_restart() {
    local name="$1" cur limit n
    cur=$(vps_get_meta "$name" AUTO_RESTART || printf '0'); limit=$(vps_get_meta "$name" RETRY_LIMIT || printf '3')
    ui_clear; ui_paint_bg; printf 'Auto-restart: %s\nRetry limit: %s\n' "$cur" "$limit"
    ui_prompt 'Enable auto-restart? (1/0)' n; [[ "$n" == 1 || "$n" == 0 ]] || { ui_pause; return; }
    if [[ "$n" == 1 ]]; then ui_prompt "Retry limit [${limit}]" limit; valid_uint "$limit" || limit=3; fi
    vps_set_meta "$name" AUTO_RESTART "$n"; vps_set_meta "$name" RETRY_LIMIT "$limit"; vps_set_meta "$name" RESTART_RETRIES 0; echo 'Saved.'; ui_pause
}

_daemon_schedule_due() {
    local name="$1" schedules="$2" datekey nowtime entry type time lastkey key
    nowtime=$(date +%H:%M); datekey=$(date +%F)
    IFS='|' read -ra arr <<< "$schedules"
    for entry in "${arr[@]}"; do
        [[ "$entry" == *@* ]] || continue; type=${entry%@*}; time=${entry#*@}; [[ "$time" == "$nowtime" ]] || continue
        key="${name}|${datekey}|${nowtime}|${type}"
        [[ "$(grep -Fx "$key" "${BASE_DIR}/run/schedule.last" 2>/dev/null || true)" == "$key" ]] && continue
        printf '%s\n' "$key" >> "${BASE_DIR}/run/schedule.last"
        case "$type" in start) _manage_transition_start "$name";; stop) backend_force_stop "$name" 2>/dev/null || true; vps_set_meta "$name" STATE stopped; vps_set_meta "$name" LAST_START 0;; restart) backend_restart "$name";; backup) _backup_create_auto "$name";; esac
    done
}

_daemon_expiry() {
    local name="$1" now exp state left marker
    now=$(date +%s); exp=$(vps_get_meta "$name" EXPIRES || printf '0'); state=$(vps_get_meta "$name" STATE || true)
    [[ "$exp" =~ ^[0-9]+$ && "$exp" != 0 ]] || return 0
    left=$((exp-now))
    if (( left <= 0 )) && [[ "$state" != expired ]]; then
        _tunnel_stop "$name"; backend_force_stop "$name" 2>/dev/null || true
        vps_set_meta "$name" STATE expired; vps_set_meta "$name" LAST_START 0; log_msg WARN "VPS=${name} expired"
        vps_log_transition "$name" "$state" expired
        return 0
    fi
    local threshold
    for threshold in 86400 3600 600; do
        if (( left > 0 && left <= threshold )); then
            marker="${BASE_DIR}/run/expiry-${name}-${threshold}"
            [[ -f "$marker" ]] || { printf '%s\n' "$now" > "$marker"; log_msg WARN "VPS=${name} expires in ${threshold}s"; }
        fi
    done
}

_daemon_watchdog() {
    local name="$1" state auto retries limit
    state=$(vps_get_meta "$name" STATE || true); auto=$(vps_get_meta "$name" AUTO_RESTART || printf '0'); retries=$(vps_get_meta "$name" RESTART_RETRIES || printf '0'); limit=$(vps_get_meta "$name" RETRY_LIMIT || printf '3')
    [[ "$state" == running && "$auto" == 1 ]] || return 0
    if ! backend_status "$name"; then
        if (( retries < limit )); then
            retries=$((retries+1)); vps_set_meta "$name" RESTART_RETRIES "$retries"; log_msg WARN "VPS=${name} watchdog restart ${retries}/${limit}"; backend_start "$name" || true
        else log_msg ERROR "VPS=${name} watchdog retry limit reached (${limit})"; vps_set_meta "$name" AUTO_RESTART 0; vps_set_meta "$name" STATE stopped; fi
    else
        (( retries > 0 )) && vps_set_meta "$name" RESTART_RETRIES 0
    fi
}

cmd_daemon() {
    [[ "${ORBIT_DAEMON:-0}" == 1 ]] || ORBIT_DAEMON=1
    mkdir -p "${BASE_DIR}/run"; printf '%s\n' "$$" > "${BASE_DIR}/run/daemon.pid"; chmod 600 "${BASE_DIR}/run/daemon.pid"
    log_msg INFO 'Daemon started'
    trap 'rm -f "${BASE_DIR}/run/daemon.pid"; exit 0' INT TERM HUP EXIT
    while true; do
        local d name
        for d in "${BASE_DIR}/vps/"*; do
            [[ -f "$d/meta.env" ]] || continue
            name=$(basename "$d")
            _daemon_expiry "$name"
            _daemon_watchdog "$name"
            [[ -n "$(vps_get_meta "$name" SCHEDULES || true)" ]] && _daemon_schedule_due "$name" "$(vps_get_meta "$name" SCHEDULES)"
        done
        trash_auto_purge
        exports_auto_purge 2>/dev/null || true
        sleep 1
    done
}

cmd_manage() {
    while true; do
        local -a opts=('Start' 'Stop (graceful → force)' 'Restart' 'Force stop' 'Schedule' 'Auto-restart watchdog' 'Start daemon' 'Console' 'Back')
        ui_menu 'Manage VPS' "${opts[@]}"; local choice=$?
        (( choice == 8 || choice == 255 )) && return
        _manage_pick_vps || continue
        case "$choice" in
            0) _manage_transition_start "$MANAGE_VPS";;
            1) _manage_transition_stop "$MANAGE_VPS";;
            2) _manage_transition_restart "$MANAGE_VPS";;
            3) _manage_transition_force "$MANAGE_VPS";;
            4) _manage_schedule "$MANAGE_VPS";;
            5) _manage_auto_restart "$MANAGE_VPS";;
            6) echo 'Estimated time: ~1s'; "${BASE_DIR}/orbitbash" --daemon >/dev/null 2>&1 & echo "Daemon PID: $!"; ui_pause;;
            7) echo 'Estimated time: console attach'; backend_console "$MANAGE_VPS"; ui_pause;;
        esac
    done
}
