# OrbitBash settings and polish

_set_themes() {
    local -a themes=('Dark Purple Pastel Pink' 'Mono Black' 'Midnight Blue' 'Neon Green' 'Sunset Orange' 'Ocean Teal' 'Rose Gold' 'Light Paper' 'Back')
    while true; do
        ui_menu 'Themes' "${themes[@]}"; local c=$?
        (( c == ${#themes[@]}-1 || c == 255 )) && return
        config_set theme "${themes[$c]}"; theme_load; theme_sample
    done
}

_set_defaults() {
    local editor os cpu ram disk exp key cur
    cur=$(config_get editor || printf 'nano'); ui_clear; ui_paint_bg; printf 'Defaults\n\nCurrent editor: %s\n' "$cur"
    ui_prompt 'Editor command' editor; [[ -n "$editor" ]] && config_set editor "$editor"
    ui_prompt 'Default OS (Ubuntu/Debian/etc.)' os; [[ -n "$os" ]] && config_set default_os "$os"
    ui_prompt 'Default CPU' cpu; if [[ -n "$cpu" && "$cpu" =~ ^[0-9]+$ ]]; then config_set default_cpu "$cpu"; fi
    ui_prompt 'Default RAM MB' ram; if [[ -n "$ram" && "$ram" =~ ^[0-9]+$ ]]; then config_set default_ram "$ram"; fi
    ui_prompt 'Default Disk GB' disk; if [[ -n "$disk" && "$disk" =~ ^[0-9]+$ ]]; then config_set default_disk "$disk"; fi
    ui_prompt 'Default export expiry hours (0=off)' exp; if [[ -n "$exp" && "$exp" =~ ^[0-9]+$ ]]; then config_set default_export_expiry "$exp"; fi
    ui_prompt 'Default SSH key path (base, .pub beside it)' key; [[ -n "$key" ]] && config_set ssh_key "${key/#\~/$HOME}"
    echo 'Defaults saved.'; ui_pause
}

_set_tz() {
    local -a cont=('Africa' 'America' 'Asia' 'Australia' 'Europe' 'Pacific' 'UTC' 'Back')
    ui_menu 'Timezone — continent/region' "${cont[@]}"; local c=$?
    (( c == ${#cont[@]}-1 || c == 255 )) && return
    local region="${cont[$c]}" city combined
    if [[ "$region" == UTC ]]; then combined=UTC
    else
        local -a city_opts
        case "$region" in
            Asia) city_opts=('Kolkata' 'Tokyo' 'Singapore' 'Dubai' 'Shanghai' 'Back');;
            Europe) city_opts=('London' 'Berlin' 'Paris' 'Moscow' 'Back');;
            America) city_opts=('New_York' 'Los_Angeles' 'Chicago' 'Toronto' 'Back');;
            Africa) city_opts=('Cairo' 'Johannesburg' 'Lagos' 'Back');;
            Australia) city_opts=('Sydney' 'Perth' 'Melbourne' 'Back');;
            Pacific) city_opts=('Auckland' 'Honolulu' 'Fiji' 'Back');;
        esac
        ui_menu "Timezone — $region" "${city_opts[@]}"; c=$?
        (( c == ${#city_opts[@]}-1 || c == 255 )) && return
        city="${city_opts[$c]}"; city=${city//_//}; combined="${region}/${city}"
    fi
    config_set tz "$combined"; export TZ="$combined"; echo "Timezone saved: $combined"; ui_pause
}

_set_func_pass() {
    local fn="$1" p1 p2
    ui_clear; ui_paint_bg; printf 'Function password: %s\n\n' "$fn"
    ui_prompt_secret 'New password (empty removes it)' p1
    if [[ -z "$p1" ]]; then rm -f "${BASE_DIR}/auth/${fn}.hash"; echo 'Removed.'; ui_pause; return; fi
    ui_prompt_secret 'Confirm password' p2; [[ "$p1" == "$p2" ]] || { echo 'Passwords do not match.'; ui_pause; return; }
    auth_store_password "$p1" "${BASE_DIR}/auth/${fn}.hash" || return
    echo 'Saved.'; ui_pause
}

_set_security() {
    while true; do
        local -a opts=('Change main password' 'Delete function password' 'Restore function password' 'Export function password' 'Purge function password' 'Modify Bash password' 'Back')
        ui_menu 'Security' "${opts[@]}"; local c=$?
        case "$c" in
            0) ui_clear; ui_paint_bg; auth_set_password; ui_pause;;
            1) _set_func_pass delete;; 2) _set_func_pass restore;; 3) _set_func_pass export;; 4) _set_func_pass purge;; 5) _set_func_pass modify;; 6|255) return;;
        esac
    done
}

_set_cloud() {
    (( ORBIT_RCLONE )) || { echo 'rclone is not installed.'; ui_pause; return; }
    local remote direction
    ui_clear; ui_paint_bg; printf 'Cloud config sync via rclone\n\n'
    ui_prompt 'Remote path (e.g. gdrive:OrbitBash)' remote; [[ -n "$remote" ]] || return
    ui_menu 'Sync direction' 'Backup local -> cloud' 'Restore cloud -> local' 'Back'; local c=$?; (( c == 2 || c == 255 )) && return
    echo 'Estimated time: network dependent'
    if (( c == 0 )); then
        ui_confirm 'Upload config/auth/nodes to the remote?' || return
        rclone copyto "${BASE_DIR}/config" "${remote%/}/config" || return
        rclone sync "${BASE_DIR}/auth" "${remote%/}/auth" || return
        rclone sync "${BASE_DIR}/nodes" "${remote%/}/nodes" || return
        echo 'Cloud backup complete.'
    else
        ui_confirm 'Restore config/auth/nodes and overwrite local copies?' || return
        rclone copyto "${remote%/}/config" "${BASE_DIR}/config" || return
        rclone sync "${remote%/}/auth" "${BASE_DIR}/auth" || return
        rclone sync "${remote%/}/nodes" "${BASE_DIR}/nodes" || return
        find "${BASE_DIR}/auth" -type f -exec chmod 600 {} + 2>/dev/null || true
        find "${BASE_DIR}/nodes" -type f -exec chmod 600 {} + 2>/dev/null || true
        chmod 600 "${BASE_DIR}/config"
        echo 'Cloud restore complete.'
    fi
    ui_pause
}

_modify_bash() {
    ask_function_password modify || return
    local bak="${BASE_DIR}/.modify-backup" editor
    editor=$(config_get editor || printf 'nano')
    mkdir -p "$bak/lib"
    echo 'Estimated time: ~2s'
    cp -a "${BASE_DIR}/orbitbash" "$bak/orbitbash" || return
    cp -a "${BASE_DIR}/lib/"*.sh "$bak/lib/" || return
    chmod -R go-rwx "$bak"
    local -a eargs; read -r -a eargs <<< "$editor"; ((${#eargs[@]})) || eargs=(nano)
    ui_cleanup; "${eargs[@]}" "${BASE_DIR}/orbitbash" "${BASE_DIR}/lib/"*.sh; ui_init
    local ok=1 f
    bash -n "${BASE_DIR}/orbitbash" || ok=0
    for f in "${BASE_DIR}/lib/"*.sh; do bash -n "$f" || ok=0; done
    if (( ! ok )); then echo 'Syntax validation failed. Use Rollback.'; ui_pause; return; fi
    echo 'Scripts validated after edit.'; ui_pause
}

_modify_rollback() {
    ask_function_password modify || return
    local bak="${BASE_DIR}/.modify-backup"
    [[ -f "$bak/orbitbash" ]] || { echo 'No edit backup exists.'; ui_pause; return; }
    echo 'Estimated time: ~2s'; ui_confirm 'Rollback the last Modify Bash backup?' || return
    cp -a "$bak/orbitbash" "${BASE_DIR}/orbitbash"; cp -a "$bak/lib/"*.sh "${BASE_DIR}/lib/"; echo 'Rollback complete.'
}

cmd_settings() {
    while true; do
        local -a opts=('Themes' 'Defaults (OS/specs/editor/export)' 'Timezone & Host OS' 'Security & passwords' 'Cloud config sync' 'Modify Bash — edit' 'Modify Bash — rollback' 'Manage SSH nodes' 'AI provider config' 'System report' 'Back')
        ui_menu 'Settings' "${opts[@]}"; local c=$?
        case "$c" in
            0) _set_themes;; 1) _set_defaults;; 2) _set_tz;; 3) _set_security;; 4) _set_cloud;; 5) _modify_bash;; 6) _modify_rollback;; 7) nodes_menu;; 8) cmd_ai_config;; 9) cmd_report;; 10|255) return;;
        esac
    done
}
# Report implementation; sourced by orbitbash directly.
cmd_report() {
    ui_clear 2>/dev/null || true; ui_paint_bg 2>/dev/null || true
    c acc; printf 'OrbitBash Final Report\n'; c reset; echo
    printf '%-34s %-12s %s\n' 'Checklist' 'Status' 'Notes'
    printf '%-34s %-12s %s\n' '----------------------------------' '------------' '---------------------------------------'
    printf '%-34s %-12s %s\n' 'Bash 4.4+ / safe shell' 'implemented' "$BASH_VERSION"
    printf '%-34s %-12s %s\n' 'Atomic config + flock + logs' 'implemented' 'Per-write lock and 1MB rotation x5'
    printf '%-34s %-12s %s\n' 'Password hashing / lockout' 'implemented' 'Salted hash only; soft lock'
    printf '%-34s %-12s %s\n' 'Themes / fallback UI' 'implemented' '8 themes; truecolor/256/8/mono'
    printf '%-34s %-12s %s\n' 'QEMU/KVM backend' "$([[ "$ORBIT_BACKEND" == kvm || "$ORBIT_BACKEND" == qemu-tcg ]] && echo implemented || echo limited)" "${ORBIT_BACKEND}"
    printf '%-34s %-12s %s\n' 'Docker backend' "$([[ "$ORBIT_DOCKER" == 1 ]] && echo implemented || echo unavailable)" 'CPU/RAM/process/copy support'
    printf '%-34s %-12s %s\n' 'LXC/Incus backend' "$([[ "$ORBIT_LXC" == 1 ]] && echo implemented || echo unavailable)" 'Incus preferred'
    printf '%-34s %-12s %s\n' 'Remote controller mode' 'implemented' 'SSH nodes and remote Docker path'
    printf '%-34s %-12s %s\n' 'Verified official cloud images' 'limited' 'Ubuntu + Debian resolvers; others use custom image or containers'
    printf '%-34s %-12s %s\n' 'Schedules / expiry / watchdog' 'implemented' 'Daemon fallback with retry limit'
    printf '%-34s %-12s %s\n' 'Live dashboard' 'implemented' '1s in-place redraw'
    printf '%-34s %-12s %s\n' 'Soft delete / recovery / purge' 'implemented' 'Trash retains metadata + disk'
    printf '%-34s %-12s %s\n' 'Macros / files / SFTP' 'implemented' 'Backend-dependent console/SSH'
    printf '%-34s %-12s %s\n' 'Backups / checksums' 'implemented' 'tar.zst/tar.gz + sha256'
    printf '%-34s %-12s %s\n' 'Export links / QR / password / expiry' 'implemented' 'Host-side token relay with password + expiry'
    printf '%-34s %-12s %s\n' 'Cloud config sync' "$([[ "$ORBIT_RCLONE" == 1 ]] && echo implemented || echo unavailable)" 'rclone'
    printf '%-34s %-12s %s\n' 'AI helper' "$([[ -n "$(config_get ai_url || true)" ]] && echo configured || echo optional)" 'OpenAI-compatible API'
    printf '%-34s %-12s %s\n' 'In-VPS tools' 'not yet' 'Per original scope: coming later'
    echo
    printf '10-line usage summary:\n'
    printf '1. Start with: orbitbash\n'
    printf '2. First run creates a salted master-password hash.\n'
    printf '3. Use Create to build a VPS and set its delete password.\n'
    printf '4. Use Manage for lifecycle, schedules and watchdogs.\n'
    printf '5. Use Live for 1-second multi-VPS telemetry.\n'
    printf '6. Delete moves VPSes to trash instead of destroying them.\n'
    printf '7. Files handles specs, copy, SFTP and web access.\n'
    printf '8. Backups create compressed archives with SHA-256 checksums.\n'
    printf '9. Settings controls themes, security, nodes, cloud sync and AI.\n'
    printf '10. Logs live at %s/logs/orbitbash.log\n' "$BASE_DIR"
    ui_pause
}
