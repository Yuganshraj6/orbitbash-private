# OrbitBash live dashboard

_live_runtime() {
    local name="$1" run last state now; run=$(vps_get_meta "$name" RUN_SECONDS || printf '0'); last=$(vps_get_meta "$name" LAST_START || printf '0'); state=$(vps_get_meta "$name" STATE || true); now=$(date +%s)
    if [[ "$state" == running && "$last" =~ ^[0-9]+$ && "$last" -gt 0 ]]; then run=$((run+now-last)); fi
    seconds_human "$run"
}

cmd_live() {
    local -a vps=(); local d choice selected_names name expiry left state created runtime stats x
    for d in "${BASE_DIR}/vps/"*; do [[ -f "$d/meta.env" ]] && vps+=("$(basename "$d")"); done
    (( ${#vps[@]} > 0 )) || { echo 'No VPSes.'; ui_pause; return; }
    ui_multiselect 'Live View — select VPSes' "${vps[@]}"; selected_names=$(cat)
    [[ -n "$selected_names" ]] || return
    IFS='|' read -ra selected <<< "$selected_names"
    ui_init
    local first=1
    while true; do
        ui_resize
        (( first )) && { ui_clear; ui_paint_bg; first=0; }
        tput cup 0 0 2>/dev/null || true
        c acc; printf 'OrbitBash Live — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"; c reset
        printf '%s\n' 'Press q/Esc to quit • refresh 1s'
        printf '\n%-18s %-9s %-35s %-16s %-18s\n' 'VPS' 'STATE' 'METRICS' 'TIME LEFT' 'RUNTIME'
        printf '%-18s %-9s %-35s %-16s %-18s\n' '------------------' '---------' '-----------------------------------' '----------------' '------------------'
        local row=4
        for name in "${selected[@]}"; do
            state=$(vps_get_meta "$name" STATE); stats=$(backend_stats "$name" 2>/dev/null || printf 'unavailable'); expiry=$(vps_get_meta "$name" EXPIRES || printf '0')
            if [[ "$expiry" =~ ^[0-9]+$ && "$expiry" -gt 0 ]]; then left=$((expiry-$(date +%s))); (( left < 0 )) && left=0; printf -v left '%s' "$(seconds_human "$left")"; else left='never'; fi
            runtime=$(_live_runtime "$name")
            tput cup "$row" 0 2>/dev/null || true
            printf '%-18.18s %-9.9s %-35.35s %-16.16s %-18.18s\033[K\n' "$name" "$state" "$stats" "$left" "$runtime"
            ((row++))
        done
        tput cup $((UI_LINES-1)) 0 2>/dev/null || true
        c dim; printf 'q/Esc to quit'; c reset
        local key
        IFS= read -rsn1 -t 1 key < /dev/tty || true
        [[ "$key" == q || "$key" == Q || "$key" == $'\e' ]] && break
    done
}
