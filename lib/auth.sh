# OrbitBash authentication. This is a soft lock because Bash scripts are readable.

auth_hash() {
    local pass="$1" salt="$2" out
    if command -v openssl >/dev/null 2>&1; then
        out=$(openssl passwd -6 -salt "$salt" "$pass" 2>/dev/null) || out=''
        [[ "$out" == '$6$'* ]] && { printf '%s\n' "$out"; return 0; }
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s:%s' "$salt" "$pass" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s:%s' "$salt" "$pass" | shasum -a 256 | awk '{print $1}'
    else
        return 1
    fi
}

auth_ct_equal() {
    local a="$1" b="$2" i diff=0 x y
    (( ${#a} == ${#b} )) || return 1
    for ((i=0;i<${#a};i++)); do
        printf -v x '%d' "'${a:i:1}"
        printf -v y '%d' "'${b:i:1}"
        diff=$(( diff | (x ^ y) ))
    done
    (( diff == 0 ))
}

auth_store_password() {
    local pass="$1" file="$2" salt hash tmp
    salt=$(generate_id)
    hash=$(auth_hash "$pass" "$salt") || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    chmod 600 "$tmp"
    printf '%s:%s\n' "$salt" "$hash" > "$tmp"
    mv -f "$tmp" "$file"
    chmod 600 "$file"
}

auth_verify_value() {
    local pass="$1" record="$2" salt expected got
    [[ "$record" == *:* ]] || return 1
    salt="${record%%:*}"; expected="${record#*:}"
    got=$(auth_hash "$pass" "$salt") || return 1
    auth_ct_equal "$got" "$expected"
}

auth_setup() {
    ui_clear; ui_paint_bg
    ui_logo; echo
    c acc; ui_center_text 'One-Time Password Setup'; c reset
    echo
    c dim; ui_center_text 'Set the private master password. It is stored only as a salted hash.'; c reset
    echo
    local p1 p2
    while true; do
        ui_prompt_secret 'Enter master password' p1
        [[ -n "$p1" ]] || { echo 'Password cannot be empty.'; continue; }
        ui_prompt_secret 'Confirm password' p2
        [[ "$p1" == "$p2" ]] || { echo 'Passwords do not match.'; continue; }
        break
    done
    auth_store_password "$p1" "${BASE_DIR}/auth/main.hash" || return 1
    printf 'Password initialized.\n'
}

auth_get_main_record() { cat "${BASE_DIR}/auth/main.hash"; }

auth_check() {
    [[ -f "${BASE_DIR}/auth/main.hash" ]] || auth_setup || return 1
    local lockfile="${BASE_DIR}/run/lockout" now locked_at remain record p tries=0
    if [[ -f "$lockfile" ]]; then
        locked_at=$(cat "$lockfile" 2>/dev/null || printf '0')
        now=$(date +%s)
        if [[ "$locked_at" =~ ^[0-9]+$ ]] && (( now-locked_at < 60 )); then
            remain=$((60-(now-locked_at)))
            printf 'Locked out. Try again in %ss.\n' "$remain"
            return 1
        fi
        rm -f "$lockfile"
    fi
    record=$(auth_get_main_record) || return 1
    while (( tries < 3 )); do
        ui_start_page || return 2
        p="$AUTH_INPUT"
        if auth_verify_value "$p" "$record"; then
            rm -f "$lockfile"
            return 0
        fi
        ((tries++))
        c err; printf 'Incorrect password. Attempt %d/3.\n' "$tries"; c reset
        sleep 2
    done
    printf '%s\n' "$(date +%s)" > "$lockfile"
    chmod 600 "$lockfile"
    printf 'Too many failures. Locked for 60 seconds.\n'
    return 1
}


auth_set_password() {
    local old new1 new2 record
    record=$(auth_get_main_record 2>/dev/null || true)
    if [[ -n "$record" ]]; then
        ui_prompt_secret 'Current master password' old
        auth_verify_value "$old" "$record" || { echo 'Incorrect current password.'; return 1; }
    fi
    ui_prompt_secret 'New master password' new1
    [[ -n "$new1" ]] || { echo 'Password cannot be empty.'; return 1; }
    ui_prompt_secret 'Confirm new password' new2
    [[ "$new1" == "$new2" ]] || { echo 'Passwords do not match.'; return 1; }
    auth_store_password "$new1" "${BASE_DIR}/auth/main.hash" || return 1
    c ok; echo 'Master password updated.'; c reset
}

ask_function_password() {
    local name="$1" file="${BASE_DIR}/auth/${1}.hash" record p
    [[ "$name" =~ ^[a-z0-9_-]+$ ]] || return 1
    [[ -f "$file" ]] || return 0
    record=$(cat "$file") || return 1
    ui_prompt_secret "Password for ${name}" p
    if auth_verify_value "$p" "$record"; then return 0; fi
    c err; echo 'Authorization failed.'; c reset
    return 1
}
