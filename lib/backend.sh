# OrbitBash backend interface: QEMU/KVM, Docker, LXC/Incus, or remote SSH.

backend_node_file() { printf '%s/nodes/%s.env\n' "$BASE_DIR" "$1"; }

backend_node_value() {
    local node="$1" key="$2" f
    f=$(backend_node_file "$node")
    [[ -f "$f" ]] || return 1
    awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$f"
}

backend_remote_ssh() {
    local node="$1" cmd="$2" host user key
    host=$(backend_node_value "$node" HOST) || return 1
    user=$(backend_node_value "$node" USER); [[ -n "$user" ]] || user=root
    key=$(backend_node_value "$node" KEY)
    local -a opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    ssh "${opts[@]}" "${user}@${host}" -- "$cmd"
}

backend_remote_scp_in() {
    local node="$1" src="$2" dst="$3" host user key
    host=$(backend_node_value "$node" HOST) || return 1
    user=$(backend_node_value "$node" USER); [[ -n "$user" ]] || user=root
    key=$(backend_node_value "$node" KEY)
    local -a opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    scp "${opts[@]}" "$src" "${user}@${host}:$dst"
}

backend_remote_scp_out() {
    local node="$1" src="$2" dst="$3" host user key
    host=$(backend_node_value "$node" HOST) || return 1
    user=$(backend_node_value "$node" USER); [[ -n "$user" ]] || user=root
    key=$(backend_node_value "$node" KEY)
    local -a opts=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    scp "${opts[@]}" "${user}@${host}:$src" "$dst"
}

backend_detect() {
    ORBIT_BACKEND="remote"
    ORBIT_SLOW=0
    ORBIT_IN_VPS=0
    ORBIT_KVM=0
    ORBIT_DOCKER=0
    ORBIT_LXC=0
    ORBIT_QEMU=0
    ORBIT_SYSTEMD=0
    ORBIT_CRON=0
    ORBIT_TMUX=0
    ORBIT_SCREEN=0
    ORBIT_ZSTD=0
    ORBIT_PYTHON3=0
    ORBIT_QRENCODE=0
    ORBIT_RCLONE=0
    ORBIT_OPENSSL=0
    ORBIT_CURL=0
    ORBIT_SSH=0
    ORBIT_ROOT=0
    ORBIT_SUDO=0
    ORBIT_LIBVIRT=0
    ORBIT_WGET=0
    ORBIT_SOCAT=0

    if [[ -f /.dockerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q; }; then ORBIT_IN_VPS=1; fi
    [[ -c /dev/kvm ]] && ORBIT_KVM=1
    command -v docker >/dev/null 2>&1 && ORBIT_DOCKER=1
    { command -v incus >/dev/null 2>&1 || command -v lxc >/dev/null 2>&1; } && ORBIT_LXC=1
    command -v qemu-system-x86_64 >/dev/null 2>&1 && ORBIT_QEMU=1
    command -v systemctl >/dev/null 2>&1 && ORBIT_SYSTEMD=1
    command -v crontab >/dev/null 2>&1 && ORBIT_CRON=1
    command -v tmux >/dev/null 2>&1 && ORBIT_TMUX=1
    command -v screen >/dev/null 2>&1 && ORBIT_SCREEN=1
    command -v zstd >/dev/null 2>&1 && ORBIT_ZSTD=1
    command -v python3 >/dev/null 2>&1 && ORBIT_PYTHON3=1
    command -v qrencode >/dev/null 2>&1 && ORBIT_QRENCODE=1
    command -v rclone >/dev/null 2>&1 && ORBIT_RCLONE=1
    command -v openssl >/dev/null 2>&1 && ORBIT_OPENSSL=1
    command -v curl >/dev/null 2>&1 && ORBIT_CURL=1
    command -v ssh >/dev/null 2>&1 && ORBIT_SSH=1
    [[ $(id -u) -eq 0 ]] && ORBIT_ROOT=1
    command -v sudo >/dev/null 2>&1 && ORBIT_SUDO=1
    { command -v virsh >/dev/null 2>&1 || command -v libvirtd >/dev/null 2>&1 || command -v virtqemud >/dev/null 2>&1; } && ORBIT_LIBVIRT=1
    command -v wget >/dev/null 2>&1 && ORBIT_WGET=1
    command -v socat >/dev/null 2>&1 && ORBIT_SOCAT=1

    if (( ORBIT_KVM && ORBIT_QEMU )); then ORBIT_BACKEND=kvm
    elif (( ORBIT_DOCKER )); then ORBIT_BACKEND=docker
    elif (( ORBIT_LXC )); then ORBIT_BACKEND=lxc
    elif (( ORBIT_QEMU )); then ORBIT_BACKEND=qemu-tcg; ORBIT_SLOW=1
    else ORBIT_BACKEND=remote
    fi
    export ORBIT_BACKEND ORBIT_SLOW ORBIT_IN_VPS ORBIT_KVM ORBIT_DOCKER ORBIT_LXC ORBIT_QEMU ORBIT_SYSTEMD ORBIT_CRON ORBIT_TMUX ORBIT_SCREEN ORBIT_ZSTD ORBIT_PYTHON3 ORBIT_QRENCODE ORBIT_RCLONE ORBIT_OPENSSL ORBIT_CURL ORBIT_SSH ORBIT_ROOT ORBIT_SUDO ORBIT_LIBVIRT ORBIT_WGET ORBIT_SOCAT
}

backend_first_run_host_os() {
    local cur det answer
    cur=$(config_get host_os || true)
    [[ -n "$cur" ]] && return 0
    det='Unknown'
    [[ -f /etc/os-release ]] && det=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/,"",$2); print $2; exit}' /etc/os-release)
    [[ -z "$det" ]] && det=$(uname -srm)
    ui_clear; ui_paint_bg
    c acc; ui_center_text 'First Run — Host OS'; c reset; echo
    printf 'Detected OS: %s\n' "$det"
    ui_prompt 'Press Enter to accept, or type another OS name' answer
    [[ -n "$answer" ]] && det="$answer"
    config_set host_os "$det"
}

backend_init() {
    backend_detect
    backend_first_run_host_os
    local nested='unknown' hostvirt='none'
    if [[ -r /sys/module/kvm_intel/parameters/nested ]]; then nested=$(cat /sys/module/kvm_intel/parameters/nested)
    elif [[ -r /sys/module/kvm_amd/parameters/nested ]]; then nested=$(cat /sys/module/kvm_amd/parameters/nested); fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then hostvirt=$(systemd-detect-virt 2>/dev/null || echo none); fi
    export ORBIT_NESTED="$nested" ORBIT_VIRT_KIND="$hostvirt"
}

backend_banner() {
    printf 'Backend: %s' "${ORBIT_BACKEND^^}"
    (( ORBIT_SLOW )) && printf ' — SLOW TCG emulation (no KVM)'
    [[ "$ORBIT_BACKEND" == remote ]] && printf ' — remote controller mode; add an SSH node'
    (( ORBIT_IN_VPS )) && printf ' — running inside a VPS/container; In-VPS tools are coming later'
    printf '\n'
    (( ORBIT_KVM )) && printf 'KVM: available  '
    (( ! ORBIT_KVM )) && printf 'KVM: unavailable  '
    [[ "$ORBIT_VIRT_KIND" != none && "$ORBIT_VIRT_KIND" != '' ]] && printf 'Outer virtualization: %s  ' "$ORBIT_VIRT_KIND"
    [[ "$ORBIT_NESTED" != unknown ]] && printf 'Nested: %s' "$ORBIT_NESTED"
    printf '\n'
}

_backend_qemu_dir() { vps_dir "$1"; }
_backend_qemu_pid() { printf '%s/qemu.pid\n' "$(_backend_qemu_dir "$1")"; }
_backend_qemu_session() { printf 'orbit-qemu-%s' "$1"; }

backend_allocate_port() {
    local start="${1:-2200}" p used=0 hex
    for ((p=start;p<65000;p++)); do
        used=0
        if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$" && used=1
        else
            hex=$(printf '%04X' "$p")
            if [[ -r /proc/net/tcp ]] && grep -qE ":${hex}[[:space:]]+[0-9]+:[0-9A-Fa-f]+[[:space:]]+0A" /proc/net/tcp 2>/dev/null; then used=1; fi
            if [[ -r /proc/net/tcp6 ]] && grep -qE ":${hex}[[:space:]]+[0-9]+:[0-9A-Fa-f]+[[:space:]]+0A" /proc/net/tcp6 2>/dev/null; then used=1; fi
        fi
        (( used == 0 )) && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
backend_image_for_docker() {
    local os="$1" ver="$2"
    case "$os" in
        Ubuntu) [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] && printf 'ubuntu:%s\n' "$ver" || printf 'ubuntu:24.04\n';;
        Debian) [[ "$ver" =~ ^[0-9]+$ ]] && printf 'debian:%s\n' "$ver" || printf 'debian:12\n';;
        Alpine) printf 'alpine:%s\n' "$ver" 2>/dev/null || printf 'alpine:latest\n';;
        Fedora) printf 'fedora:%s\n' "$ver" 2>/dev/null || printf 'fedora:latest\n';;
        Arch) printf 'archlinux:latest\n';;
        Rocky) printf 'rockylinux:%s\n' "$ver" 2>/dev/null || printf 'rockylinux:9\n';;
        Alma) printf 'almalinux:%s\n' "$ver" 2>/dev/null || printf 'almalinux:9\n';;
        openSUSE) printf 'opensuse/leap:%s\n' "$ver" 2>/dev/null || printf 'opensuse/leap:latest\n';;
        Kali) printf 'kalilinux/kali-rolling:latest\n';;
        *) return 1;;
    esac
}

backend_create() {
    local name="$1"
    case "${ORBIT_BACKEND}" in
        kvm|qemu-tcg) _backend_qemu_create "$name";;
        docker) _backend_docker_create "$name";;
        lxc) _backend_lxc_create "$name";;
        remote) _backend_remote_create "$name";;
        *) return 1;;
    esac
}

backend_start() {
    local name="$1"; case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_qemu_start "$name";;
        docker) docker start "orbitbash-${name}" >/dev/null;;
        lxc) { command -v incus >/dev/null && incus start "orbitbash-${name}" || lxc-start -n "orbitbash-${name}"; };;
        remote) backend_remote_run "$name" start;;
    esac
}

backend_stop() {
    local name="$1"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_qemu_acpi_stop "$name";;
        docker) docker stop -t 10 "orbitbash-${name}" >/dev/null;;
        lxc) { command -v incus >/dev/null && incus stop "orbitbash-${name}" --timeout 10 || lxc-stop -n "orbitbash-${name}"; };;
        remote) backend_remote_run "$name" stop;;
    esac
}

backend_force_stop() {
    local name="$1"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_qemu_force_stop "$name";;
        docker) docker kill "orbitbash-${name}" >/dev/null 2>&1 || true;;
        lxc) { command -v incus >/dev/null && incus stop -f "orbitbash-${name}" || lxc-stop -k -n "orbitbash-${name}"; };;
        remote) backend_remote_run "$name" force-stop;;
    esac
}

backend_restart() { backend_stop "$1" && sleep 1 && backend_start "$1"; }

backend_status() {
    local name="$1"; case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) local pid; pid=$(cat "$(_backend_qemu_pid "$name")" 2>/dev/null || true); [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null;;
        docker) [[ "$(docker inspect -f '{{.State.Running}}' "orbitbash-${name}" 2>/dev/null || echo false)" == true ]];;
        lxc) [[ "$(command -v incus >/dev/null && incus list "orbitbash-${name}" --format csv -c s || lxc-info -n "orbitbash-${name}" -s 2>/dev/null | awk '{print $2}')" == RUNNING ]];;
        remote) backend_remote_run "$name" status >/dev/null;;
    esac
}

_backend_qemu_pid_cpu() { ps -p "$1" -o %cpu= 2>/dev/null | awk '{printf "%.0f",$1}'; }
_backend_qemu_mem_mb() { ps -p "$1" -o rss= 2>/dev/null | awk '{printf "%.0f",$1/1024}'; }

backend_stats() {
    local name="$1" pid cpu ram disk netrx nettx
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg)
            pid=$(cat "$(_backend_qemu_pid "$name")" 2>/dev/null || true)
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                cpu=$(_backend_qemu_pid_cpu "$pid"); ram=$(_backend_qemu_mem_mb "$pid")
                disk=$(du -BG --apparent-size "$(vps_dir "$name")/disk.qcow2" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1; exit}' || printf '0')
                printf 'CPU %s%% | RAM %sMB | Disk %sGB | NET n/a\n' "${cpu:-0}" "${ram:-0}" "${disk:-0}"
            else printf 'CPU -- | RAM -- | Disk %sGB | NET --\n' "$(vps_get_meta "$name" DISK_GB)"; fi;;
        docker)
            docker stats --no-stream --format 'CPU {{.CPUPerc}} | RAM {{.MemUsage}} | Disk n/a | NET {{.NetIO}}' "orbitbash-${name}" 2>/dev/null || printf 'CPU -- | RAM -- | Disk %sGB | NET --\n' "$(vps_get_meta "$name" DISK_GB)";;
        lxc)
            local mem='n/a'
            if command -v incus >/dev/null 2>&1; then mem=$(incus info "orbitbash-${name}" 2>/dev/null | awk -F: '/Memory usage/{gsub(/ /,"",$2);print $2;exit}')
            fi
            printf 'CPU n/a | RAM %s | Disk %sGB | NET n/a\n' "$mem" "$(vps_get_meta "$name" DISK_GB)";;
        remote) backend_remote_run "$name" stats;;
    esac
}

backend_exec() {
    local name="$1"; shift
    local cmd="$*"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_guest_ssh_exec "$name" "$cmd";;
        docker) docker exec "orbitbash-${name}" sh -lc "$cmd";;
        lxc) { command -v incus >/dev/null && incus exec "orbitbash-${name}" -- sh -lc "$cmd" || lxc-attach -n "orbitbash-${name}" -- sh -lc "$cmd"; };;
        remote) backend_remote_run "$name" exec "$cmd";;
    esac
}

backend_copy_in() {
    local name="$1" src="$2" dst="$3"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_guest_scp_in "$name" "$src" "$dst";;
        docker) docker exec "orbitbash-${name}" sh -lc "mkdir -p -- \"$(dirname "$dst")\"" >/dev/null 2>&1 || true; docker cp "$src" "orbitbash-${name}:$dst";;
        lxc) { command -v incus >/dev/null && incus file push "$src" "orbitbash-${name}${dst}" || lxc-file push "$src" "${name}/${dst}"; };;
        remote) backend_remote_scp_in "$name" "$src" "$dst";;
    esac
}

backend_copy_out() {
    local name="$1" src="$2" dst="$3"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) _backend_guest_scp_out "$name" "$src" "$dst";;
        docker) docker exec "orbitbash-${name}" sh -lc "test -e -- '$src'" >/dev/null 2>&1 || return 1; docker cp "orbitbash-${name}:$src" "$dst";;
        lxc) { command -v incus >/dev/null && incus file pull "orbitbash-${name}${src}" "$dst" || lxc-file pull "${name}/${src}" "$dst"; };;
        remote) backend_remote_scp_out "$name" "$src" "$dst";;
    esac
}

backend_resize() {
    local name="$1" cpu="$2" ram="$3" disk="$4"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg)
            local dir old new
            dir=$(vps_dir "$name"); old=$(vps_get_meta "$name" DISK_GB)
            (( disk >= old )) || { echo 'Disk resize is grow-only.' >&2; return 1; }
            command -v qemu-img >/dev/null 2>&1 || { echo 'qemu-img is required for QEMU disk resize.' >&2; return 1; }
            qemu-img resize "$dir/disk.qcow2" "${disk}G" >/dev/null || return 1
            vps_set_meta "$name" CPU "$cpu"; vps_set_meta "$name" RAM_MB "$ram"; vps_set_meta "$name" DISK_GB "$disk";;
        docker)
            local old2; old2=$(vps_get_meta "$name" DISK_GB); (( disk >= old2 )) || { echo 'Disk resize is grow-only.' >&2; return 1; }
            if (( disk > old2 )); then docker update --storage-opt "size=${disk}G" "orbitbash-${name}" >/dev/null || { echo 'Docker runtime could not resize its storage quota; no metadata was changed.' >&2; return 1; }; fi
            docker update --cpus "$cpu" --memory "${ram}m" "orbitbash-${name}" >/dev/null || return 1
            vps_set_meta "$name" CPU "$cpu"; vps_set_meta "$name" RAM_MB "$ram"; vps_set_meta "$name" DISK_GB "$disk";;
        lxc)
            command -v incus >/dev/null || return 1
            incus config set "orbitbash-${name}" limits.cpu "$cpu" limits.memory "${ram}MB" || return 1
            local old3=$(vps_get_meta "$name" DISK_GB); (( disk >= old3 )) || { echo 'Disk resize is grow-only.' >&2; return 1; }
            incus config device override "orbitbash-${name}" root size="${disk}GiB" || true
            vps_set_meta "$name" CPU "$cpu"; vps_set_meta "$name" RAM_MB "$ram"; vps_set_meta "$name" DISK_GB "$disk";;
        remote) backend_remote_run "$name" resize "$cpu" "$ram" "$disk";;
    esac
}

backend_snapshot() {
    local name="$1" snap="$2"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg) qemu-img snapshot -c "$snap" "$(vps_dir "$name")/disk.qcow2";;
        docker) docker commit "orbitbash-${name}" "orbitbash-snapshot:${snap}" >/dev/null;;
        lxc) command -v incus >/dev/null && incus snapshot create "orbitbash-${name}" "$snap";;
        remote) backend_remote_run "$name" snapshot "$snap";;
    esac
}

backend_destroy() {
    local name="$1"
    backend_force_stop "$name" 2>/dev/null || true
    case "$ORBIT_BACKEND" in
        docker) docker rm -f "orbitbash-${name}" >/dev/null 2>&1 || true;;
        lxc) { command -v incus >/dev/null && incus delete -f "orbitbash-${name}" || lxc-destroy -f -n "orbitbash-${name}"; };;
        kvm|qemu-tcg) rm -f "$(vps_dir "$name")/seed.iso" "$(vps_dir "$name")/qemu.pid";;
        remote) backend_remote_run "$name" destroy || true;;
    esac
}

backend_console() {
    local name="$1"
    case "$ORBIT_BACKEND" in
        kvm|qemu-tcg)
            if (( ORBIT_TMUX )); then tmux attach-session -t "$(_backend_qemu_session "$name")"; elif (( ORBIT_SCREEN )); then screen -r "orbit-qemu-${name}"; else _backend_guest_ssh_shell "$name"; fi;;
        docker) docker exec -it "orbitbash-${name}" sh;;
        lxc) command -v incus >/dev/null && incus exec "orbitbash-${name}" -- sh || lxc-attach -n "orbitbash-${name}";;
        remote) backend_remote_run "$name" console;;
    esac
}

# ---- QEMU ----
_backend_qemu_create() {
    local name="$1" dir image cache vport
    dir=$(vps_dir "$name")
    image="$(vps_get_meta "$name" IMAGE_PATH || true)"
    mkdir -p "$dir"
    if [[ -f "$dir/disk.qcow2" ]]; then
        :
    elif [[ -n "$image" && -f "$image" ]]; then
        command -v qemu-img >/dev/null 2>&1 || { echo 'qemu-img is required to prepare a custom image.' >&2; return 1; }
        local fmt; fmt=$(qemu-img info --output=json "$image" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","raw"))' 2>/dev/null || printf 'raw')
        [[ "$fmt" == qcow2 || "$fmt" == raw || "$fmt" == vmdk || "$fmt" == vdi ]] || fmt=raw
        qemu-img create -f qcow2 -F "$fmt" -b "$image" "$dir/disk.qcow2" "$(vps_get_meta "$name" DISK_GB)G" >/dev/null || return 1
    elif [[ -f "${BASE_DIR}/images/${name}.img" ]]; then
        command -v qemu-img >/dev/null 2>&1 || { echo 'qemu-img is required to prepare a cloud image.' >&2; return 1; }
        qemu-img create -f qcow2 -F raw -b "${BASE_DIR}/images/${name}.img" "$dir/disk.qcow2" "$(vps_get_meta "$name" DISK_GB)G" >/dev/null || return 1
    elif [[ "$(vps_get_meta "$name" LIVE_ISO)" == 1 ]]; then
        command -v qemu-img >/dev/null 2>&1 || { echo 'qemu-img is required for a live ISO VPS.' >&2; return 1; }
        qemu-img create -f qcow2 "$dir/disk.qcow2" "$(vps_get_meta "$name" DISK_GB)G" >/dev/null || return 1
    else
        echo 'No verified disk image prepared for this VPS.' >&2; return 1
    fi
    if command -v qemu-img >/dev/null 2>&1 && ! qemu-img info "$dir/disk.qcow2" 2>/dev/null | grep -q '^file format: qcow2$'; then
        qemu-img convert -O qcow2 "$dir/disk.qcow2" "$dir/disk.qcow2.new" >/dev/null 2>&1 && mv -f "$dir/disk.qcow2.new" "$dir/disk.qcow2" || return 1
    fi
    qemu-img resize "$dir/disk.qcow2" "$(vps_get_meta "$name" DISK_GB)G" >/dev/null 2>&1 || true
    [[ -f "$dir/seed.iso" ]] || return 0
}

_backend_qemu_start() {
    local name="$1" dir pidfile disk seed iso cpu ram sshport net session cmd args phost pguest
    dir="$(vps_dir "$name")"; pidfile="$dir/qemu.pid"; disk="$dir/disk.qcow2"; seed="$dir/seed.iso"; iso="$dir/../does-not-exist"
    [[ -f "$disk" ]] || { echo 'QEMU disk image missing.' >&2; return 1; }
    backend_status "$name" && return 0
    cpu=$(vps_get_meta "$name" CPU); ram=$(vps_get_meta "$name" RAM_MB); sshport=$(vps_get_meta "$name" SSH_PORT)
    [[ "$sshport" =~ ^[0-9]+$ ]] || sshport=2222
    args=()
    (( ORBIT_KVM )) && args+=(-enable-kvm)
    local netdev="user,id=n0" ports x ph pg
    ports=$(vps_get_meta "$name" PORTS)
    IFS=',' read -ra _ports <<< "$ports"
    for x in "${_ports[@]}"; do
        [[ "$x" == *:* ]] || continue
        ph=${x%%:*}; pg=${x#*:}
        [[ "$ph" =~ ^[0-9]+$ && "$pg" =~ ^[0-9]+$ ]] || continue
        netdev+=",hostfwd=tcp::${ph}-:${pg}"
    done
    args+=( -smp "$cpu" -m "${ram}M" -drive "file=${disk},if=virtio,format=qcow2" -display none -serial mon:stdio -netdev "$netdev" -device virtio-net-pci,netdev=n0)
    [[ -f "$seed" ]] && args+=(-drive "file=${seed},media=cdrom,if=virtio")
    local live iso_path; live=$(vps_get_meta "$name" LIVE_ISO); iso_path=$(vps_get_meta "$name" ISO_PATH)
    if [[ "$live" == 1 && -f "$iso_path" ]]; then args+=(-cdrom "$iso_path" -boot d); fi
    if [[ "$(vps_get_meta "$name" NET_MODE)" == bridge ]]; then
        net=$(vps_get_meta "$name" BRIDGE)
        [[ -n "$net" ]] || { echo 'Bridge name not configured.' >&2; return 1; }
        args=()
        (( ORBIT_KVM )) && args+=(-enable-kvm)
        args+=( -smp "$cpu" -m "${ram}M" -drive "file=${disk},if=virtio,format=qcow2" -display none -serial mon:stdio -netdev "bridge,id=n0,br=${net}" -device virtio-net-pci,netdev=n0)
        [[ -f "$seed" ]] && args+=(-drive "file=${seed},media=cdrom,if=virtio")
    fi
    session=$(_backend_qemu_session "$name")
    if (( ORBIT_TMUX )); then
        tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session" || true
        tmux new-session -d -s "$session" -- qemu-system-x86_64 "${args[@]}"
        tmux pipe-pane -o -t "$session" "cat >> '$(vps_dir "$name")/log'"
        pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' | head -1)
        printf '%s\n' "$pid" > "$pidfile"
    elif (( ORBIT_SCREEN )); then
        screen -dmS "orbit-qemu-${name}" qemu-system-x86_64 "${args[@]}"
        pid=$(screen -S "orbit-qemu-${name}" -Q windows 2>/dev/null | awk -F. 'NR==1{print $1}') || pid=''
        [[ "$pid" =~ ^[0-9]+$ ]] || pid=$(pgrep -f "qemu-system-x86_64.*${disk}" | tail -1 || true)
        printf '%s\n' "$pid" > "$pidfile"
    else
        nohup qemu-system-x86_64 "${args[@]}" >>"$(vps_dir "$name")/log" 2>&1 &
        pid=$!; printf '%s\n' "$pid" > "$pidfile"
    fi
    sleep 1
    backend_status "$name" || { echo 'QEMU failed to start; check VPS log.' >&2; return 1; }
}

_backend_qemu_acpi_stop() {
    local name="$1" session pid
    session=$(_backend_qemu_session "$name")
    pid=$(cat "$(_backend_qemu_pid "$name")" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
    local deadline=$(( $(date +%s)+10 )); while backend_status "$name" && (( $(date +%s) < deadline )); do sleep 1; done
    if backend_status "$name"; then _backend_qemu_force_stop "$name"; fi
}

_backend_qemu_force_stop() {
    local name="$1" session pid
    pid=$(cat "$(_backend_qemu_pid "$name")" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    session=$(_backend_qemu_session "$name")
    (( ORBIT_TMUX )) && tmux kill-session -t "$session" 2>/dev/null || true
    (( ORBIT_SCREEN )) && screen -S "orbit-qemu-${name}" -X quit 2>/dev/null || true
    rm -f "$(_backend_qemu_pid "$name")"
}

_guest_host_port() { printf '%s\n' "$(vps_get_meta "$1" SSH_PORT)"; }
_guest_host() { printf '127.0.0.1\n'; }
_guest_user() { printf '%s\n' "$(vps_get_meta "$1" SSH_USER)"; }
_guest_key() { printf '%s\n' "$(vps_get_meta "$1" SSH_KEY)"; }

_backend_guest_ssh_common() {
    local name="$1" command="$2" port key user
    port=$(_guest_host_port "$name"); user=$(_guest_user "$name"); key=$(_guest_key "$name")
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    local -a opts=(-p "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    ssh "${opts[@]}" "${user}@127.0.0.1" -- "$command"
}
_backend_guest_ssh_exec() { _backend_guest_ssh_common "$1" "$2"; }
_backend_guest_ssh_shell() { local name="$1"; _backend_guest_ssh_common "$name" 'exec bash -l'; }
_backend_guest_scp_in() {
    local name="$1" src="$2" dst="$3" port key user
    port=$(_guest_host_port "$name"); key=$(_guest_key "$name"); user=$(_guest_user "$name")
    local -a opts=(-P "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    scp "${opts[@]}" "$src" "${user}@127.0.0.1:$dst"
}
_backend_guest_scp_out() {
    local name="$1" src="$2" dst="$3" port key user
    port=$(_guest_host_port "$name"); key=$(_guest_key "$name"); user=$(_guest_user "$name")
    local -a opts=(-P "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$key" ]] && opts+=(-i "${key/#\~/$HOME}")
    scp "${opts[@]}" "${user}@127.0.0.1:$src" "$dst"
}

# ---- Docker ----
_backend_docker_create() {
    local name="$1" image cpu ram disk ports hostssh
    image=$(backend_image_for_docker "$(vps_get_meta "$name" OS)" "$(vps_get_meta "$name" OS_VERSION)") || return 1
    docker pull "$image" >/dev/null || return 1
    cpu=$(vps_get_meta "$name" CPU); ram=$(vps_get_meta "$name" RAM_MB); disk=$(vps_get_meta "$name" DISK_GB); hostssh=$(vps_get_meta "$name" SSH_PORT); ports=$(vps_get_meta "$name" PORTS)
    local -a run_args=(--name "orbitbash-${name}" --cpus "$cpu" --memory "${ram}m" --storage-opt "size=${disk}G" --restart=no --hostname "$name")
    [[ -n "$hostssh" ]] && run_args+=(-p "${hostssh}:22")
    local x ph pg; IFS=',' read -ra _ports <<< "$ports"; for x in "${_ports[@]}"; do [[ "$x" == *:* ]] || continue; ph=${x%%:*}; pg=${x#*:}; run_args+=(-p "${ph}:${pg}"); done
    local cmd='(command -v /usr/sbin/sshd && /usr/sbin/sshd) 2>/dev/null || (command -v sshd && sshd) 2>/dev/null || true; exec sleep infinity'
    docker run -d "${run_args[@]}" "$image" sh -lc "$cmd" >/dev/null || return 1
    # Best-effort SSH daemon install + key setup. If it cannot be installed, exec/copy still work.
    local keyfile="$(vps_get_meta "$name" SSH_KEY)" pub=''
    [[ -n "$keyfile" && -f "${keyfile/#\~/$HOME}.pub" ]] && pub=$(cat "${keyfile/#\~/$HOME}.pub")
    docker exec "orbitbash-${name}" sh -lc 'mkdir -p /run/sshd /root/.ssh; chmod 700 /root/.ssh; command -v apt-get >/dev/null && { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server sudo curl; } || command -v apk >/dev/null && { apk add --no-cache openssh sudo curl; } || command -v dnf >/dev/null && { dnf -y install openssh-server sudo curl; }; ssh-keygen -A >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
    [[ -n "$pub" ]] && docker exec "orbitbash-${name}" sh -lc "printf '%s\\n' '$pub' >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys" || true
    docker exec "orbitbash-${name}" sh -lc "(command -v /usr/sbin/sshd && /usr/sbin/sshd) || (command -v sshd && sshd) || true" >/dev/null 2>&1 || true
    docker stop "orbitbash-${name}" >/dev/null 2>&1 || true
}

# ---- LXC/Incus ----
_backend_lxc_create() {
    local name="$1" os ver cpu ram disk image
    os=$(vps_get_meta "$name" OS); ver=$(vps_get_meta "$name" OS_VERSION); cpu=$(vps_get_meta "$name" CPU); ram=$(vps_get_meta "$name" RAM_MB); disk=$(vps_get_meta "$name" DISK_GB)
    command -v incus >/dev/null 2>&1 || { echo 'Incus is required for the LXC backend in this build.' >&2; return 1; }
    case "$os" in Ubuntu) image="images:ubuntu/26.04";; Debian) image="images:debian/13";; Alpine) image="images:alpine/3.20";; Fedora) image="images:fedora/40";; *) image='images:ubuntu/26.04';; esac
    incus launch "$image" "orbitbash-${name}" -c limits.cpu="$cpu" -c limits.memory="${ram}MB" >/dev/null || return 1
    incus config device override "orbitbash-${name}" root size="${disk}GiB" >/dev/null 2>&1 || true
}

# ---- Remote controller ----
backend_remote_target_detect() {
    local node="$1"
    if backend_remote_ssh "$node" 'test -e /dev/kvm && command -v qemu-system-x86_64 >/dev/null && echo kvm' | grep -qx kvm; then printf 'kvm\n'
    elif backend_remote_ssh "$node" 'command -v docker >/dev/null && echo docker' | grep -qx docker; then printf 'docker\n'
    elif backend_remote_ssh "$node" 'command -v incus >/dev/null && echo lxc' | grep -qx lxc; then printf 'lxc\n'
    else printf 'unknown\n'; fi
}
backend_remote_run() {
    local name="$1" action="$2"; shift 2
    local node; node=$(vps_get_meta "$name" NODE)
    [[ -n "$node" && "$node" != local ]] || node=$(config_get node_default || true)
    [[ -n "$node" ]] || { echo 'No remote node configured.' >&2; return 1; }
    local script=""
    case "$action" in
        start) script="docker start orbitbash-${name} 2>/dev/null || true";;
        stop) script="docker stop -t 10 orbitbash-${name} 2>/dev/null || true";;
        force-stop) script="docker kill orbitbash-${name} 2>/dev/null || true";;
        status) script="docker inspect -f '{{.State.Running}}' orbitbash-${name} 2>/dev/null | grep -qx true";;
        exec) script="docker exec orbitbash-${name} bash -lc $(shell_escape_arg "$*")";;
        stats) script="docker stats --no-stream --format 'CPU {{.CPUPerc}} | RAM {{.MemUsage}} | Disk n/a | NET {{.NetIO}}' orbitbash-${name}";;
        resize) script="docker update --cpus $(shell_escape_arg "$1") --memory $(shell_escape_arg "${2}m") --storage-opt $(shell_escape_arg "size=${3}G") orbitbash-${name}";;
        snapshot) script="docker commit orbitbash-${name} orbitbash-snapshot:${1}";;
        console) script="docker exec -it orbitbash-${name} sh";;
        destroy) script="docker rm -f orbitbash-${name}";;
        *) return 1;;
    esac
    backend_remote_ssh "$node" "$script"
}
_backend_remote_create() {
    local name="$1" node image cpu ram disk ports sshport run_args x ph pg args
    node=$(vps_get_meta "$name" NODE)
    [[ -n "$node" && "$node" != local ]] || return 1
    image=$(backend_image_for_docker "$(vps_get_meta "$name" OS)" "$(vps_get_meta "$name" OS_VERSION)") || return 1
    cpu=$(vps_get_meta "$name" CPU); ram=$(vps_get_meta "$name" RAM_MB); disk=$(vps_get_meta "$name" DISK_GB); ports=$(vps_get_meta "$name" PORTS); sshport=$(vps_get_meta "$name" SSH_PORT)
    run_args="--name $(shell_escape_arg "orbitbash-${name}") --cpus $(shell_escape_arg "$cpu") --memory $(shell_escape_arg "${ram}m") --storage-opt $(shell_escape_arg "size=${disk}G") --restart=no"
    [[ "$sshport" =~ ^[0-9]+$ ]] && run_args+=" -p $(shell_escape_arg "${sshport}:22")"
    IFS=',' read -ra _rports <<< "$ports"
    for x in "${_rports[@]}"; do
        [[ "$x" == *:* ]] || continue
        ph=${x%%:*}; pg=${x#*:}
        [[ "$ph" =~ ^[0-9]+$ && "$pg" =~ ^[0-9]+$ ]] || continue
        [[ "$ph:$pg" == "${sshport}:22" ]] && continue
        run_args+=" -p $(shell_escape_arg "${ph}:${pg}")"
    done
    args="docker pull $(shell_escape_arg "$image") >/dev/null && docker run -d $run_args $(shell_escape_arg "$image") sleep infinity"
    backend_remote_ssh "$node" "$args" >/dev/null
}
