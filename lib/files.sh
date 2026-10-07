# OrbitBash VPS files, specs, SFTP and web file manager

_files_pick() {
    local -a list=(); local d
    for d in "${BASE_DIR}/vps/"*; do [[ -f "$d/meta.env" ]] && list+=("$(basename "$d")"); done
    list+=('Back'); (( ${#list[@]} > 1 )) || { echo 'No VPSes.'; ui_pause; return 1; }
    ui_menu 'Select VPS' "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return 1; FILES_VPS="${list[$c]}"
}

_files_specs() {
    _files_pick || return
    local name="$FILES_VPS" cpu ram disk net ports state newcpu newram newdisk newnet newports olddisk
    cpu=$(vps_get_meta "$name" CPU); ram=$(vps_get_meta "$name" RAM_MB); disk=$(vps_get_meta "$name" DISK_GB); net=$(vps_get_meta "$name" NET_MODE); ports=$(vps_get_meta "$name" PORTS); state=$(vps_get_meta "$name" STATE)
    ui_clear; ui_paint_bg; printf 'Edit VPS Specs: %s\n\nCPU=%s  RAM=%sMB  Disk=%sGB  Network=%s  Ports=%s\n' "$name" "$cpu" "$ram" "$disk" "$net" "${ports:-none}"
    ui_prompt 'New CPU (blank keep)' newcpu; [[ -z "$newcpu" ]] && newcpu="$cpu"
    ui_prompt 'New RAM MB (blank keep)' newram; [[ -z "$newram" ]] && newram="$ram"
    ui_prompt 'New Disk GB (blank keep; grow-only)' newdisk; [[ -z "$newdisk" ]] && newdisk="$disk"
    ui_prompt 'Network (nat/bridge; blank keep)' newnet; [[ -z "$newnet" ]] && newnet="$net"
    ui_prompt 'Ports host:guest list (blank keep)' newports; [[ -z "$newports" ]] && newports="$ports"
    valid_uint "$newcpu" && valid_uint "$newram" && valid_uint "$newdisk" || { echo 'Invalid resource value.'; ui_pause; return; }
    (( newcpu>=1 && newcpu<=host_cpu_count )) || { echo 'CPU exceeds host.'; ui_pause; return; }
    (( newram>=256 && newram<=host_total_ram_mb )) || { echo 'RAM exceeds host.'; ui_pause; return; }
    (( newdisk>=disk )) || { echo 'Disk resize is grow-only.'; ui_pause; return; }
    [[ "$newnet" == nat || "$newnet" == bridge ]] || { echo 'Invalid network mode.'; ui_pause; return; }
    create_parse_ports "$newports" || { echo 'Invalid ports.'; ui_pause; return; }
    echo 'Estimated time: ~10s'
    (( newdisk != disk || newcpu != cpu || newram != ram )) && { ui_confirm 'Apply changed specs? A restart may be required.' || return; backend_resize "$name" "$newcpu" "$newram" "$newdisk" || { echo 'Backend resize failed.'; ui_pause; return; }; }
    vps_set_meta "$name" NET_MODE "$newnet"; vps_set_meta "$name" PORTS "$newports"
    echo 'Specs updated.'; ui_pause
}

_files_edit() {
    _files_pick || return
    local name="$FILES_VPS" guest path tmpdir localfile editor
done=false
    ui_clear; ui_paint_bg; printf 'File edit on %s\n' "$name"
    ui_prompt 'Guest file path (e.g. /etc/hosts)' path
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { echo 'Use an absolute guest path.'; ui_pause; return; }
    tmpdir=$(mktemp -d "${BASE_DIR}/run/edit.XXXXXX") || return
    localfile="${tmpdir}/$(basename "$path")"
    echo 'Estimated time: ~5–30s'
    if ! backend_copy_out "$name" "$path" "$localfile"; then rm -rf "$tmpdir"; echo 'Could not copy the guest file out.'; ui_pause; return; fi
    editor=$(config_get editor || printf 'nano')
    local -a eargs; read -r -a eargs <<< "$editor"; ((${#eargs[@]})) || eargs=(nano)
    ui_cleanup; "${eargs[@]}" "$localfile"; ui_init
    backend_copy_in "$name" "$localfile" "$path" || { rm -rf "$tmpdir"; echo 'Copy back failed.'; ui_pause; return; }
    rm -rf "$tmpdir"; echo 'File updated.'; ui_pause
}

_files_copy_in() {
    _files_pick || return
    local name="$FILES_VPS" src dst; ui_prompt 'Local source file' src; src="${src/#\~/$HOME}"; [[ -f "$src" ]] || { echo 'Source not found.'; ui_pause; return; }
    ui_prompt 'Guest destination path' dst; [[ "$dst" == /* ]] || return
    echo 'Estimated time: file-size dependent'; backend_copy_in "$name" "$src" "$dst" || echo 'Copy failed.'; ui_pause
}

_files_copy_out() {
    _files_pick || return
    local name="$FILES_VPS" src dst; ui_prompt 'Guest source path' src; [[ "$src" == /* ]] || return
    ui_prompt 'Local destination file/directory' dst; dst="${dst/#\~/$HOME}"
    echo 'Estimated time: file-size dependent'; backend_copy_out "$name" "$src" "$dst" || echo 'Copy failed.'; ui_pause
}

_files_sftp() {
    _files_pick || return
    local name="$FILES_VPS" port user key host
    port=$(vps_get_meta "$name" SSH_PORT); user=$(vps_get_meta "$name" SSH_USER); key=$(vps_get_meta "$name" SSH_KEY)
    ui_clear; ui_paint_bg; printf 'SFTP / SSH access for %s\n\n' "$name"
    printf 'sftp -P %s -o StrictHostKeyChecking=no' "$port"; [[ -n "$key" ]] && printf ' -i %q' "${key/#\~/$HOME}"; printf ' %s@127.0.0.1\n' "$user"
    if [[ "$ORBIT_BACKEND" == docker ]]; then
        printf '\nDocker filesystem copy is available through the Files menu even when guest SSH is not installed.\n'
    fi
    ui_pause
}

_files_web() {
    _files_pick || return
    local name="$FILES_VPS" guestdir hostport port pid
    [[ "$ORBIT_PYTHON3" == 1 ]] || { echo 'python3 is required.'; ui_pause; return; }
    ui_prompt 'Guest directory to serve' guestdir; [[ "$guestdir" == /* ]] || return
    hostport=$(backend_allocate_port 2800) || return
    echo 'Estimated time: ~2s'
    if backend_exec "$name" "cd $(shell_escape_arg "$guestdir") && nohup python3 -m http.server 8090 --bind 0.0.0.0 >/tmp/orbitbash-http.log 2>&1 &"; then
        printf 'File manager server started on guest port 8090.\n'
        printf 'Expose it with an SSH tunnel (run locally):\nssh -p %s -L %s:127.0.0.1:8090 %s@127.0.0.1\n' "$(vps_get_meta "$name" SSH_PORT)" "$hostport" "$(vps_get_meta "$name" SSH_USER)"
    else echo 'Could not start guest web server.'; fi
    ui_pause
}

cmd_files() {
    while true; do
        local -a opts=('Edit VPS Specs' 'Edit a file' 'Copy file into VPS' 'Copy file out of VPS' 'SFTP setup' 'Web file manager' 'Quick file export' 'Backups' 'Back')
        ui_menu 'Files / Configs' "${opts[@]}"; local c=$?
        case "$c" in
            0) _files_specs;; 1) _files_edit;; 2) _files_copy_in;; 3) _files_copy_out;; 4) _files_sftp;; 5) _files_web;; 6) _files_export;; 7) cmd_backups;; 8|255) return;;
        esac
    done
}

_export_http_server() {
    local dir="$1" token="$2" expires="$3" authfile="$4" port="$5" pidfile="$6" script
    script="$dir/server.py"
    cat > "$script" <<PY
#!/usr/bin/env python3
import base64, hashlib, http.server, os, time
ROOT=os.environ['EXPORT_ROOT']
TOKEN=os.environ['EXPORT_TOKEN']
EXPIRES=int(os.environ['EXPORT_EXPIRES'])
AUTH_FILE=os.environ['EXPORT_AUTH_FILE']
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if EXPIRES and time.time()>EXPIRES:
            self.send_error(410, 'Export expired'); return
        prefix='/download/'+TOKEN
        if self.path.split('?',1)[0] != prefix:
            self.send_error(404); return
        expected=''
        try:
            with open(AUTH_FILE,'r',encoding='ascii') as f: expected=f.read().strip()
        except OSError: pass
        if expected:
            h=self.headers.get('Authorization','')
            ok=False
            if h.startswith('Basic '):
                try:
                    raw=base64.b64decode(h[6:]).decode('utf-8')
                    pw=raw.split(':',1)[1] if ':' in raw else raw
                    ok=hashlib.sha256(pw.encode()).hexdigest()==expected
                except Exception: ok=False
            if not ok:
                self.send_response(401); self.send_header('WWW-Authenticate','Basic realm="OrbitBash export"'); self.end_headers(); return
        name=os.path.basename(ROOT)
        if not os.path.isfile(ROOT): self.send_error(404); return
        size=os.path.getsize(ROOT); self.send_response(200); self.send_header('Content-Length',str(size)); self.send_header('Content-Disposition',f'attachment; filename="{name}"'); self.end_headers()
        with open(ROOT,'rb') as src:
            while True:
                buf=src.read(1024*128)
                if not buf: break
                self.wfile.write(buf)
    def log_message(self,*args): return
class Server(http.server.ThreadingHTTPServer): daemon_threads=True
Server(('0.0.0.0',int(os.environ['EXPORT_PORT'])),Handler).serve_forever()
PY
    chmod 700 "$script"
    EXPORT_ROOT="$dir/file" EXPORT_TOKEN="$token" EXPORT_EXPIRES="$expires" EXPORT_AUTH_FILE="$authfile" EXPORT_PORT="$port" nohup python3 "$script" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pidfile"; chmod 600 "$pidfile"
}

_files_export() {
    _files_pick || return
    local name="$FILES_VPS" guestpath stage file token port expires default_exp pass authfile exp_dir pidfile url
    ask_function_password export || return
    ui_clear; ui_paint_bg; printf 'Quick file export — %s\n\n' "$name"
    ui_prompt 'Guest file path to export' guestpath; [[ "$guestpath" == /* ]] || return
    stage=$(mktemp -d "${BASE_DIR}/run/export.XXXXXX") || return
    file="${stage}/file"; echo 'Estimated time: file-size dependent'
    backend_copy_out "$name" "$guestpath" "$file" || { rm -rf "$stage"; echo 'Export source could not be copied.'; ui_pause; return; }
    token=$(generate_id)$(generate_id); exp_dir="${BASE_DIR}/exports/${token}"; mkdir -p "$exp_dir"; mv "$file" "$exp_dir/file"; rm -rf "$stage"; chmod 700 "$exp_dir"; chmod 600 "$exp_dir/file"
    default_exp=$(config_get default_export_expiry || printf '24'); ui_prompt "Expiry hours (0=never) [${default_exp}]" expires; [[ -n "$expires" ]] || expires="$default_exp"; valid_uint "$expires" || expires=24
    if (( expires > 0 )); then expires=$(( $(date +%s)+expires*3600 )); else expires=0; fi
    ui_prompt_secret 'Optional download password (blank for token-only)' pass
    authfile="${exp_dir}/auth.sha256"
    [[ -n "$pass" ]] && printf '%s' "$pass" | sha256sum | awk '{print $1}' > "$authfile" || : > "$authfile"
    chmod 600 "$authfile"
    port=$(backend_allocate_port 9000) || { rm -rf "$exp_dir"; return; }
    printf '%s\n' "$expires" > "${exp_dir}/expires"; chmod 600 "${exp_dir}/expires"
    pidfile="${exp_dir}/server.pid"; _export_http_server "$exp_dir" "$token" "$expires" "$authfile" "$port" "$pidfile" || { rm -rf "$exp_dir"; return; }
    url="http://127.0.0.1:${port}/download/${token}"
    printf '\nExport URL:\n%s\n' "$url"
    printf 'Token: %s\nExpires: %s\n' "$token" "$( [[ "$expires" == 0 ]] && printf never || date -d "@$expires" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf "$expires" )"
    if (( ORBIT_QRENCODE )); then printf '\nASCII QR:\n'; qrencode -t UTF8 "$url" 2>/dev/null || qrencode -t ANSIUTF8 "$url" 2>/dev/null || true
    elif (( ORBIT_PYTHON3 )) && python3 -c 'import qrcode' >/dev/null 2>&1; then printf '\nASCII QR:\n'; python3 - "$url" <<'PY'
import qrcode,sys
q=qrcode.QRCode(border=1); q.add_data(sys.argv[1]); q.make(fit=True); q.print_ascii(invert=True)
PY
    else printf '\nQR fallback: qrencode/qrcode is unavailable; the token URL above is the usable fallback.\n'; fi
    log_msg INFO "Export created for VPS=${name} token=${token} port=${port}"
    ui_pause
}

_files_export_stop() {
    local d pid
    for d in "${BASE_DIR}/exports/"*; do
        [[ -f "$d/server.pid" ]] || continue
        pid=$(cat "$d/server.pid" 2>/dev/null || true); [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done
}

exports_auto_purge() {
    local d exp pid now; now=$(date +%s)
    for d in "${BASE_DIR}/exports/"*; do
        [[ -d "$d" ]] || continue
        exp=$(cat "$d/expires" 2>/dev/null || printf '0')
        pid=$(cat "$d/server.pid" 2>/dev/null || true)
        if { [[ "$exp" =~ ^[0-9]+$ ]] && [[ "$exp" != 0 ]] && (( now >= exp )); } || { [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; }; then
            [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
            rm -rf "$d"
        fi
    done
}
