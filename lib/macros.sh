# OrbitBash macro keepalive

cmd_macros() {
    local -a list=(); local d
    for d in "${BASE_DIR}/vps/"*; do [[ -f "$d/meta.env" ]] && list+=("$(basename "$d")"); done
    list+=('Back'); (( ${#list[@]} > 1 )) || { echo 'No VPSes.'; ui_pause; return; }
    ui_menu 'Macro Keepalive — Select VPS' "${list[@]}"; local c=$?
    (( c == ${#list[@]}-1 || c == 255 )) && return
    _macro_run "${list[$c]}"
}

_macro_run() {
    local name key interval session key_display='CTRL-U'
    name="$1"
    key=${MACRO_STOP_KEY:-$'\x15'}
    interval=$(config_get macro_interval || printf '0.25')
    session="orbit-qemu-${name}"
    echo 'Estimated time: runs until stop key.'
    if [[ -n "$(config_get macro_stop_key || true)" ]]; then key=$(config_get macro_stop_key); key_display=$(config_get macro_stop_key); fi
    ui_clear; ui_paint_bg; c acc; ui_center_text "Keepalive Macro — ${name}"; c reset; echo
    printf 'Stop key: %s\n' "$key_display"
    if [[ "$ORBIT_BACKEND" == kvm || "$ORBIT_BACKEND" == qemu-tcg ]] && (( ORBIT_TMUX )); then
        tmux has-session -t "$session" 2>/dev/null || { echo 'VPS console session is not available.'; ui_pause; return; }
        stty_save=$(stty -g 2>/dev/null || true); stty -icanon min 0 time 10 2>/dev/null || true
        trap 'stty "$stty_save" 2>/dev/null || true; echo; exit 130' INT TERM HUP
        while true; do
            tmux send-keys -t "$session" C-l
            IFS= read -r -n1 -t 0.1 k < /dev/tty 2>/dev/null || k=''
            [[ "$k" == "$key" || ( "$key" == $'\x15' && "$k" == $'\x15' ) ]] && break
            sleep "$interval"
        done
        trap - INT TERM HUP; stty "$stty_save" 2>/dev/null || true
    elif [[ "$ORBIT_BACKEND" == docker ]]; then
        while true; do
            backend_exec "$name" 'printf "\\033[2J\\033[H"' >/dev/null 2>&1 || break
            IFS= read -rsn1 -t 0.2 k < /dev/tty 2>/dev/null || k=''
            [[ "$k" == "$key" ]] && break
            sleep "$interval"
        done
    else
        echo 'This backend does not expose a console channel suitable for macro keepalive.'
        ui_pause
    fi
}
