# OrbitBash soft-delete countdown

_delete_countdown() {
    local name="$1" wait=60 interrupted i key
    while true; do
        interrupted=0
        trap 'interrupted=1' INT
        for ((i=wait;i>0;i--)); do
            ui_resize; ui_clear; ui_paint_bg
            c err; ui_center_text "DANGER — DELETE VPS: ${name}"; c reset
            printf '\n'
            c warn; ui_center_text "Time remaining: ${i}s"; c reset
            c dim; ui_center_text 'Any key or Ctrl+C interrupts and adds a random 60–120s penalty.'; c reset
            IFS= read -rsn1 -t 1 key < /dev/tty && { interrupted=1; break; }
        done
        trap - INT
        if (( interrupted )); then wait=$(random_range 60 120); c err; printf '\nInterrupted. Penalty: %ss.\n' "$wait"; c reset; sleep 1; else break; fi
    done
}

_delete_single() {
    local name="$1" record password state
    record=$(vps_get_meta "$name" DELETE_HASH) || return 1
    [[ -n "$record" ]] || { echo 'This VPS has no delete password record; deletion refused.'; return 1; }
    ask_function_password delete || return 1
    ui_clear; ui_paint_bg; printf 'Delete VPS: %s\n' "$name"
    ui_prompt_secret 'Enter VPS delete password' password
    auth_verify_value "$password" "$record" || { c err; echo 'Incorrect delete password.'; c reset; ui_pause; return 1; }
    echo 'Estimated time: ~60s minimum'
    ui_confirm 'Begin the mandatory delete countdown?' || return 0
    _delete_countdown "$name" || return 1
    echo 'Estimated time: ~5s'
    state=$(vps_get_meta "$name" STATE)
    backend_force_stop "$name" 2>/dev/null || true
    vps_set_meta "$name" STATE deleted
    vps_set_meta "$name" LAST_START 0
    vps_log_transition "$name" "$state" deleted
    local stamp dest
    stamp=$(date +%s)
    dest="${BASE_DIR}/trash/${name}-${stamp}"
    mkdir -p "${BASE_DIR}/trash"
    mv "${BASE_DIR}/vps/${name}" "$dest" || return 1
    chmod 700 "$dest"; chmod 600 "$dest/meta.env" 2>/dev/null || true
    log_msg INFO "VPS=${name} soft-deleted to trash=${dest}"
    echo 'VPS moved to trash; disk and metadata were kept.'
    ui_pause
}

cmd_delete() {
    while true; do
        local -a list=(); local d
        for d in "${BASE_DIR}/vps/"*; do [[ -f "$d/meta.env" ]] && list+=("$(basename "$d")"); done
        list+=('Back')
        ui_menu 'Delete VPS' "${list[@]}"; local c=$?
        (( c == ${#list[@]}-1 || c == 255 )) && return
        _delete_single "${list[$c]}"
    done
}
