# OrbitBash backups

_backend_archive_out() {
    local name="$1" guestpath="$2" out="$3"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_guest_ssh_common "$name" "tar -C / -cpf - -- $(shell_escape_arg "${guestpath#/}")" > "$out";;
        docker) docker exec "orbitbash-${name}" tar -C / -cpf - -- "$guestpath" > "$out";;
        lxc) command -v incus >/dev/null && incus exec "orbitbash-${name}" -- tar -C / -cpf - -- "$guestpath" > "$out";;
        remote) backend_remote_run "$name" exec "tar -C / -cpf - -- $(shell_escape_arg "${guestpath#/}")" > "$out";;
        *) return 1;;
    esac
}

_backend_archive_in() {
    local name="$1" in="$2"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_guest_ssh_common "$name" 'tar -C / -xpf -' < "$in";;
        docker) docker exec -i "orbitbash-${name}" tar -C / -xpf - < "$in";;
        lxc) command -v incus >/dev/null && incus exec "orbitbash-${name}" -- tar -C / -xpf - < "$in";;
        remote) backend_remote_run "$name" exec 'tar -C / -xpf -' < "$in";;
        *) return 1;;
    esac
}

_backup_compress() {
    local tarfile="$1" outbase="$2" out
    if (( ORBIT_ZSTD )); then out="${outbase}.tar.zst"; zstd -q -f "$tarfile" -o "$out" || return 1
    else out="${outbase}.tar.gz"; gzip -c "$tarfile" > "$out" || return 1; fi
    sha256sum "$out" > "$out.sha256"; chmod 600 "$out" "$out.sha256"; printf '%s\n' "$out"
}

_backup_create() {
    _files_pick || return
    local name="$FILES_VPS" guestpath temp outbase backup estimate
    ui_prompt 'Guest file/folder path to back up (e.g. /etc or /home/orbit/project)' guestpath; [[ "$guestpath" == /* ]] || return
    temp=$(mktemp "${BASE_DIR}/run/backup.XXXXXX.tar") || return
    echo 'Estimated time: size-dependent'
    estimate=$(backend_exec "$name" "du -sk -- $(shell_escape_arg "$guestpath") 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tail -1 || true)
    [[ "$estimate" =~ ^[0-9]+$ ]] && printf 'Estimated guest size: %s KB\n' "$estimate"
    if ! _backend_archive_out "$name" "$guestpath" "$temp"; then rm -f "$temp"; echo 'Backup archive could not be created.'; ui_pause; return; fi
    mkdir -p "${BASE_DIR}/backups/${name}"; outbase="${BASE_DIR}/backups/${name}/$(date +%Y%m%d-%H%M%S)"; backup=$(_backup_compress "$temp" "$outbase") || { rm -f "$temp"; return; }; rm -f "$temp"
    log_msg INFO "Backup created for VPS=${name}: ${backup}"; printf 'Backup: %s\nChecksum: %s.sha256\n' "$backup" "$backup"; ui_pause
}

_backup_create_auto() {
    local name="$1" temp outbase
    [[ -d "${BASE_DIR}/vps/${name}" ]] || return
    temp=$(mktemp "${BASE_DIR}/run/backupd.XXXXXX.tar") || return
    _backend_archive_out "$name" '/etc' "$temp" >/dev/null 2>&1 || { rm -f "$temp"; return; }
    mkdir -p "${BASE_DIR}/backups/${name}"; outbase="${BASE_DIR}/backups/${name}/$(date +%Y%m%d-%H%M%S-auto)"; _backup_compress "$temp" "$outbase" >/dev/null 2>&1 || true; rm -f "$temp"
}

_backup_pick() {
    local name="$1" d; local -a list=()
    for d in "${BASE_DIR}/backups/${name}/"*.tar.*; do [[ -f "$d" && "$d" != *.sha256 ]] && list+=("$d"); done
    list+=('Back'); (( ${#list[@]} > 1 )) || { echo 'No backups.'; ui_pause; return 1; }
    ui_menu "Backups — $name" "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return 1; BACKUP_PICK="${list[$c]}"
}

_backup_restore() {
    _files_pick || return
    local name="$FILES_VPS" temp
    ask_function_password restore || return
    _backup_pick "$name" || return
    echo 'Estimated time: size-dependent'; ui_confirm 'Restore this backup into the VPS? Existing files may be overwritten.' || return
    temp=$(mktemp "${BASE_DIR}/run/restore.XXXXXX.tar") || return
    case "$BACKUP_PICK" in *.tar.zst) zstd -q -d -f "$BACKUP_PICK" -o "$temp";; *.tar.gz) gzip -dc "$BACKUP_PICK" > "$temp";; esac || { rm -f "$temp"; return; }
    _backend_archive_in "$name" "$temp" || { rm -f "$temp"; echo 'Restore failed.'; ui_pause; return; }
    rm -f "$temp"; log_msg INFO "Backup restored for VPS=${name}: ${BACKUP_PICK}"; echo 'Restore complete.'; ui_pause
}

_backup_delete() {
    _files_pick || return; local name="$FILES_VPS"; _backup_pick "$name" || return; ask_function_password purge || return
    echo 'Estimated time: ~2s'; ui_confirm 'Permanently delete this backup and its checksum?' || return; rm -f "$BACKUP_PICK" "$BACKUP_PICK.sha256"; log_msg WARN "Backup deleted: ${BACKUP_PICK}"
}

_backup_download() {
    _files_pick || return; local name="$FILES_VPS" dst; _backup_pick "$name" || return; ui_prompt 'Local download destination directory' dst; dst="${dst/#\~/$HOME}"; mkdir -p "$dst" || return; echo 'Estimated time: file-size dependent'; cp -f "$BACKUP_PICK" "$BACKUP_PICK.sha256" "$dst/" || return; echo "Downloaded to $dst"; ui_pause
}

cmd_backups() {
    while true; do
        local -a opts=('Create backup' 'Restore backup' 'Delete backup' 'Download backup' 'Back')
        ui_menu 'Backups' "${opts[@]}"; local c=$?
        case "$c" in 0) _backup_create;; 1) _backup_restore;; 2) _backup_delete;; 3) _backup_download;; 4|255) return;; esac
    done
}
