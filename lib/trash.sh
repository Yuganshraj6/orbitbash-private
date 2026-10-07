# OrbitBash trash and expiry tools

_trash_pick() {
    local -a list=(); local d
    for d in "${BASE_DIR}/trash/"*; do [[ -f "$d/meta.env" ]] && list+=("$(basename "$d")"); done
    list+=('Back')
    (( ${#list[@]} > 1 )) || { echo 'Trash is empty.'; ui_pause; return 1; }
    ui_menu 'Deleted VPSes' "${list[@]}"; local c=$?
    (( c == ${#list[@]}-1 || c == 255 )) && return 1
    TRASH_PICK="${list[$c]}"
}

_trash_list() {
    ui_clear; ui_paint_bg; c acc; ui_center_text 'Deleted VPSes'; c reset; echo
    local d name state
    for d in "${BASE_DIR}/trash/"*; do
        [[ -f "$d/meta.env" ]] || continue
        name=$(vps_get_meta_trash "$(basename "$d")" NAME)
        state=$(vps_get_meta_trash "$(basename "$d")" STATE)
        printf '%-24s %-10s\n' "$(basename "$d")" "${state:-deleted}"
    done
    ui_pause
}

vps_get_meta_trash() {
    local dir="$1" key="$2"
    awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "${BASE_DIR}/trash/${dir}/meta.env" 2>/dev/null || true
}

_trash_perm_delete() {
    _trash_pick || return
    ask_function_password purge || return
    echo 'Estimated time: depends on disk size.'
    ui_confirm 'PERMANENTLY destroy this deleted VPS and its disk? This cannot be undone.' || return
    rm -rf "${BASE_DIR}/trash/${TRASH_PICK}"
    log_msg WARN "Trash permanently purged: ${TRASH_PICK}"
}

_trash_recover() {
    _trash_pick || return
    local src="${BASE_DIR}/trash/${TRASH_PICK}" name conflict newname
    name=$(vps_get_meta_trash "$TRASH_PICK" NAME)
    if [[ -e "${BASE_DIR}/vps/${name}" ]]; then
        ui_prompt "Name '${name}' exists. Enter new name for recovered VPS" newname
        valid_name "$newname" || { echo 'Invalid name.'; ui_pause; return; }
        [[ ! -e "${BASE_DIR}/vps/${newname}" ]] || { echo 'Name still exists.'; ui_pause; return; }
        vps_set_meta_trash "$TRASH_PICK" NAME "$newname" || return
        name="$newname"
    fi
    echo 'Estimated time: ~5s'
    mv "$src" "${BASE_DIR}/vps/${name}" || return 1
    vps_set_meta "$name" STATE stopped
    vps_log_transition "$name" deleted stopped
    log_msg INFO "VPS=${name} recovered from trash"
}

vps_set_meta_trash() {
    local dir="$1" key="$2" val="$3" file tmp
    file="${BASE_DIR}/trash/${dir}/meta.env"
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk -v k="$key" 'index($0,k"=")!=1 {print}' "$file" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$file"; chmod 600 "$file"
}

_trash_settings() {
    local cur enabled days
    cur=$(config_get trash_auto_days || printf '0')
    ui_clear; ui_paint_bg; printf 'Auto-delete: %s days after trash (0=off)\n' "$cur"
    ui_prompt 'Days (0 to disable)' days
    valid_uint "$days" || return
    config_set trash_auto_days "$days"
    echo 'Auto-delete setting saved.'; ui_pause
}

_trash_status() {
    local days; days=$(config_get trash_auto_days || printf '0')
    printf 'Auto-delete: %s\n' "$([[ "$days" == 0 ]] && echo off || echo "after ${days} days")"
    ui_pause
}

_trash_expired() {
    local d name state exp
    ui_clear; ui_paint_bg; c acc; ui_center_text 'Expired VPSes'; c reset; echo
    for d in "${BASE_DIR}/vps/"*; do
        [[ -f "$d/meta.env" ]] || continue
        name=$(basename "$d"); state=$(vps_get_meta "$name" STATE); exp=$(vps_get_meta "$name" EXPIRES)
        if [[ "$state" == expired || ( "$exp" =~ ^[0-9]+$ && "$exp" -gt 0 && "$exp" -le $(date +%s) ) ]]; then printf '%s\n' "$name"; fi
    done
    ui_pause
}

_trash_expired_action() {
    _trash_expired
}

_trash_renew() {
    _manage_pick_expired || return
    local name="$MANAGE_VPS" hours cur new
    ui_prompt 'Renew by hours' hours; valid_uint "$hours" || return
    echo 'Estimated time: ~2s'
    cur=$(vps_get_meta "$name" EXPIRES); new=$(( $(date +%s) + hours*3600 )); vps_set_meta "$name" EXPIRES "$new"; vps_set_meta "$name" STATE stopped
    log_msg INFO "VPS=${name} renewed for ${hours}h"
}

_manage_pick_expired() {
    local -a list=(); local d name state exp now=$(date +%s)
    for d in "${BASE_DIR}/vps/"*; do
        [[ -f "$d/meta.env" ]] || continue
        name=$(basename "$d"); state=$(vps_get_meta "$name" STATE); exp=$(vps_get_meta "$name" EXPIRES)
        if [[ "$state" == expired || ( "$exp" =~ ^[0-9]+$ && "$exp" -gt 0 && "$exp" -le "$now" ) ]]; then list+=("$name"); fi
    done
    list+=('Back'); (( ${#list[@]} > 1 )) || { echo 'No expired VPSes.'; ui_pause; return 1; }
    ui_menu 'Select expired VPS' "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return 1; MANAGE_VPS="${list[$c]}"
}

trash_auto_purge() {
    local days=$(config_get trash_auto_days || printf '0') d dir mtime now=$(( $(date +%s) )) age name
    valid_uint "$days" || return
    (( days > 0 )) || return
    for d in "${BASE_DIR}/trash/"*; do
        [[ -d "$d" && -f "$d/meta.env" ]] || continue
        mtime=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || printf '%s' "$now")
        age=$((now-mtime)); (( age >= days*86400 )) || continue
        log_msg WARN "Auto-purging trash=${d}"
        rm -rf -- "$d"
    done
}

cmd_trash() {
    while true; do
        local -a opts=('List deleted VPSes' 'Permanently delete' 'Recover VPS' 'Auto-delete settings' 'Auto-delete status' 'Expired VPSes' 'Renew expired VPS' 'Move expired VPS to trash' 'Back')
        ui_menu 'Deleted VPSes' "${opts[@]}"; local c=$?
        case "$c" in
            0) _trash_list;;
            1) _trash_perm_delete;;
            2) _trash_recover;;
            3) _trash_settings;;
            4) _trash_status;;
            5) _trash_expired;;
            6) _trash_renew;;
            7) _manage_pick_expired && _delete_expired_to_trash "$MANAGE_VPS";;
            8|255) return;;
        esac
    done
}

_delete_expired_to_trash() {
    local name="$1" state
    state=$(vps_get_meta "$name" STATE); [[ "$state" == expired ]] || { vps_set_meta "$name" STATE expired; }
    echo 'Estimated time: ~5s'; ui_confirm "Move expired VPS '$name' to trash?" || return
    vps_set_meta "$name" STATE deleted; vps_log_transition "$name" expired deleted
    mkdir -p "${BASE_DIR}/trash"; mv "${BASE_DIR}/vps/${name}" "${BASE_DIR}/trash/${name}-$(date +%s)"; log_msg INFO "Expired VPS=${name} moved to trash"
}
