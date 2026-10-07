# OrbitBash utility layer

_die() {
    printf 'OrbitBash: %s\n' "$*" >&2
    return 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || _die "Required command not found: $1"
}

config_get() {
    local key="$1" conf="${BASE_DIR}/config"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ -f "$conf" ]] || return 0
    awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$conf"
}

lock_acquire() {
    local name="$1" lockfile
    lockfile="${BASE_DIR}/run/lock/${name}.lock"
    mkdir -p "${BASE_DIR}/run/lock"
    if [[ -n "${ORBIT_LOCK_FD:-}" ]]; then
        return 0
    fi
    # Bash 4.4 dynamic FD; lock scope is one non-nested critical section.
    eval "exec {ORBIT_LOCK_FD}>\"${lockfile}\""
    if ! flock -x "$ORBIT_LOCK_FD"; then
        eval "exec ${ORBIT_LOCK_FD}>&-" || true
        ORBIT_LOCK_FD=""
        log_msg ERROR "Failed to acquire lock: ${name}"
        return 1
    fi
}

lock_release() {
    if [[ -n "${ORBIT_LOCK_FD:-}" ]]; then
        flock -u "$ORBIT_LOCK_FD" || true
        eval "exec ${ORBIT_LOCK_FD}>&-" || true
        ORBIT_LOCK_FD=""
    fi
}

config_set() {
    local key="$1" val="${2-}" conf="${BASE_DIR}/config" tmp
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    mkdir -p "${BASE_DIR}" "${BASE_DIR}/run/lock"
    lock_acquire config || return 1
    tmp=$(mktemp "${conf}.XXXXXX") || { lock_release; return 1; }
    chmod 600 "$tmp"
    touch "$conf"
    awk -v k="$key" 'index($0,k"=")!=1 {print}' "$conf" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$conf"
    chmod 600 "$conf"
    lock_release
}

log_msg() {
    local level="$1" msg="$2" log_file="${BASE_DIR}/logs/orbitbash.log" size i
    mkdir -p "${BASE_DIR}/logs"
    umask 077
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$msg" >> "$log_file"
    size=$(wc -c <"$log_file" 2>/dev/null || printf '0')
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1048576 )); then
        for ((i=4; i>=1; i--)); do
            [[ -f "${log_file}.${i}" ]] && mv -f "${log_file}.${i}" "${log_file}.$((i+1))"
        done
        mv -f "$log_file" "${log_file}.1"
    fi
    chmod 600 "${log_file}" "${log_file}".* 2>/dev/null || true
}

generate_id() {
    local raw
    raw=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || raw=""
    [[ "$raw" =~ ^[0-9a-f]{8,}$ ]] && { printf '%.12s\n' "$raw"; return 0; }
    printf '%s%s\n' "$(date +%s)" "$$" | sha256sum | cut -c1-12
}

random_range() {
    local min="$1" max="$2" n
    if [[ -r /dev/urandom ]]; then
        n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$(( min + n % (max - min + 1) ))"
            return 0
        fi
    fi
    printf '%s\n' "$(( min + RANDOM % (max - min + 1) ))"
}

valid_name() { [[ "$1" =~ ^[a-z0-9-]{3,32}$ && "$1" != -* && "$1" != *- ]]; }
valid_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_port() { valid_uint "$1" && (( $1 >= 1 && $1 <= 65535 )); }
valid_hours() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

list_vps() {
    local d
    for d in "${BASE_DIR}/vps/"*; do
        [[ -f "$d/meta.env" ]] || continue
        basename "$d"
    done | sort
}

list_trash() {
    local d
    for d in "${BASE_DIR}/trash/"*; do
        [[ -f "$d/meta.env" ]] || continue
        basename "$d"
    done | sort
}

vps_dir() { printf '%s/vps/%s\n' "$BASE_DIR" "$1"; }
vps_meta_file() { printf '%s/vps/%s/meta.env\n' "$BASE_DIR" "$1"; }

vps_get_meta() {
    local name="$1" key="$2" env_file
    env_file=$(vps_meta_file "$name")
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ -f "$env_file" ]] || return 0
    awk -v k="$key" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$env_file"
}

vps_set_meta() {
    local name="$1" key="$2" val="${3-}" env_file tmp dir
    valid_name "$name" || return 2
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    dir=$(vps_dir "$name")
    env_file="${dir}/meta.env"
    [[ -f "$env_file" ]] || return 1
    mkdir -p "${BASE_DIR}/run/lock"
    lock_acquire "vps_${name}" || return 1
    tmp=$(mktemp "${env_file}.XXXXXX") || { lock_release; return 1; }
    chmod 600 "$tmp"
    awk -v k="$key" 'index($0,k"=")!=1 {print}' "$env_file" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$env_file"
    chmod 600 "$env_file"
    lock_release
}

vps_log_transition() {
    local name="$1" from="$2" to="$3"
    log_msg INFO "VPS=${name} state ${from:-unknown} -> ${to}"
    printf '[%s] %s -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "${from:-unknown}" "$to" >> "$(vps_dir "$name")/log"
}

shell_escape_arg() {
    printf '%q' "$1"
}

seconds_human() {
    local s="${1:-0}" d h m
    [[ "$s" =~ ^-?[0-9]+$ ]] || s=0
    (( s < 0 )) && s=0
    d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60)); s=$((s%60))
    if (( d > 0 )); then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
    elif (( m > 0 )); then printf '%dm %ds' "$m" "$s"
    else printf '%ds' "$s"; fi
}

uri_safe() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }

host_free_disk_gb() {
    df -Pk "${BASE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

host_total_ram_mb() {
    free -m 2>/dev/null | awk '/^Mem:/ {print $2; exit}'
}

host_cpu_count() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'; }

host_root_or_sudo() {
    (( EUID == 0 )) || command -v sudo >/dev/null 2>&1
}

run_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=3s "$secs" "$@"
    else
        "$@"
    fi
}
