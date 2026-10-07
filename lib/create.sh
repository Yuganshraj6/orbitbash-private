# OrbitBash VPS creation wizard

create_image_dir() { mkdir -p "${BASE_DIR}/images"; }

os_codename_to_ubuntu() {
    case "$1" in
        20.04|focal) printf 'focal\n';; 22.04|jammy) printf 'jammy\n';; 24.04|noble) printf 'noble\n';; 26.04|resolute) printf 'resolute\n';; 25.10|questing) printf 'questing\n';; *) return 1;;
    esac
}

resolve_official_image() {
    local os="$1" ver="$2" arch='amd64' work url sha_url file sum expected
    create_image_dir
    case "$os" in
        Ubuntu)
            if [[ "$ver" == latest ]]; then
                command -v python3 >/dev/null 2>&1 || { echo 'Ubuntu latest discovery requires python3.' >&2; return 1; }
                local streams stream_hash
                streams=$(curl --fail --silent --show-error --location --connect-timeout 8 --max-time 30 https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json) || return 1
                read -r url stream_hash file <<PY
$(STREAMS_DATA="$streams" python3 - <<'PY3'
import json, os
j=json.loads(os.environ['STREAMS_DATA'])
items=[]
for k,v in j.get('products',{}).items():
    if v.get('arch')=='amd64' and 'cloudimg' in k:
        for rel in v.get('versions',{}).values():
            for item in rel.get('items',{}).values():
                if item.get('path','').endswith('.img') and item.get('ftype')=='disk1.img':
                    items.append((item.get('version',''),item.get('url',''),item.get('sha256',''),item.get('path','')))
if not items: raise SystemExit(1)
items.sort(reverse=True)
_,u,s,p=items[0]
print(u, s, p)
PY3
)
PY
                sha_url="${url%/*}/SHA256SUMS"
            else
                local code; code=$(os_codename_to_ubuntu "$ver") || { echo 'Unsupported Ubuntu version. Use 20.04, 22.04, 24.04, 26.04, 25.10 or a custom image.' >&2; return 1; }
                file="$(basename "${code}-server-cloudimg-${arch}.img")"
                url="https://cloud-images.ubuntu.com/${code}/current/${file}"
                sha_url="https://cloud-images.ubuntu.com/${code}/current/SHA256SUMS"
            fi
            ;;
        Debian)
            case "$ver" in 11|bullseye) code=bullseye;; 12|bookworm) code=bookworm;; 13|trixie|latest) code=trixie;; *) echo 'Supported Debian cloud images: 11/bullseye, 12/bookworm, 13/trixie (latest).' >&2; return 1;; esac
            file="debian-${code}-generic-amd64.qcow2"
            url="https://cloud.debian.org/images/cloud/${code}/latest/${file}"
            sha_url="https://cloud.debian.org/images/cloud/${code}/latest/SHA512SUMS"
            ;;
        *)
            echo "No verified official cloud-image resolver is enabled for ${os} in this build. Use Custom URL/ISO or a Docker/LXC backend." >&2
            return 1;;
    esac
    work=$(mktemp -d "${BASE_DIR}/run/image.XXXXXX") || return 1
    file="${BASE_DIR}/images/${file}"
    if [[ ! -s "$file" ]]; then
        printf 'Estimated time: download depends on image size/network.\n'
        curl --fail --location --connect-timeout 10 --max-time 3600 --retry 3 --retry-delay 2 -C - -o "$file" "$url" || { rm -f "$file"; rm -rf "$work"; return 1; }
    fi
    printf 'Verifying official checksum...\n'
    if [[ "$os" == Ubuntu ]]; then
        curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 "$sha_url" > "$work/checksums" || { rm -rf "$work"; return 1; }
        expected=$(awk -v f="$(basename "$file")" '{gsub(/^\*/,"",$2); if($2==f){print $1; exit}}' "$work/checksums")
        [[ -n "$expected" ]] || { echo 'Checksum entry not found.' >&2; rm -rf "$work"; return 1; }
        printf '%s  %s\n' "$expected" "$file" | sha256sum -c - || { echo 'Checksum mismatch — removing cached image.' >&2; rm -f "$file"; rm -rf "$work"; return 1; }
    else
        curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 "$sha_url" > "$work/checksums" || { rm -rf "$work"; return 1; }
        expected=$(awk -v f="$(basename "$file")" '{gsub(/^\*/,"",$NF); if($NF==f){print $1; exit}}' "$work/checksums")
        [[ -n "$expected" ]] || { echo 'Checksum entry not found.' >&2; rm -rf "$work"; return 1; }
        printf '%s  %s\n' "$expected" "$file" | sha512sum -c - || { echo 'Checksum mismatch — removing cached image.' >&2; rm -f "$file"; rm -rf "$work"; return 1; }
    fi
    rm -rf "$work"
    printf '%s\n' "$file"
}

resolve_custom_image() {
    local source="$1" name="$2" out tmp
    out="${BASE_DIR}/images/${name}.custom"
    if [[ "$source" =~ ^https?:// ]]; then
        printf 'Estimated time: network dependent.\n'
        curl --fail --location --connect-timeout 10 --max-time 3600 --retry 3 --retry-delay 2 -C - -o "$out" "$source" || { rm -f "$out"; return 1; }
    elif [[ -f "${source/#\~/$HOME}" ]]; then
        source="${source/#\~/$HOME}"
        cp --reflink=auto "$source" "$out" 2>/dev/null || cp "$source" "$out" || return 1
    else
        echo 'Custom image path does not exist.' >&2; return 1
    fi
    [[ -s "$out" ]] || { rm -f "$out"; return 1; }
    printf '%s\n' "$out"
}

create_parse_ports() {
    local value="$1" x host guest
    [[ -z "$value" ]] && return 0
    IFS=',' read -ra items <<< "$value"
    for x in "${items[@]}"; do
        [[ "$x" == *:* ]] || return 1
        host=${x%%:*}; guest=${x#*:}
        valid_port "$host" && valid_port "$guest" || return 1
    done
}

create_make_cloud_init() {
    local name="$1" keyfile="$2" timezone="$3" user="$4" outfile="$5" hostos="$6"
    local pub=''
    if [[ -n "$keyfile" && -f "${keyfile}.pub" ]]; then pub=$(cat "${keyfile}.pub"); fi
    [[ -n "$pub" ]] || { echo 'An SSH public key is required for QEMU VPS creation.' >&2; return 1; }
    cat > "$outfile" <<CI
#cloud-config
hostname: ${name}
fqdn: ${name}
timezone: ${timezone}
package_update: true
package_upgrade: true
packages:
  - openssh-server
  - sudo
  - curl
users:
  - default
  - name: ${user}
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${pub}
ssh_pwauth: false
ssh_deletekeys: true
runcmd:
  - [bash, -lc, 'systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true']
  - [hostnamectl, set-hostname, ${name}]
CI
    chmod 600 "$outfile"
    [[ -n "$hostos" ]] || true
}

cmd_create() {
    local step=1 name='' os='' ver='' cpu='' ram='' disk='' net='nat' ports='' expiry='0' node='local' region='' urlmode='none' url_guest_port=80 delpass='' keyfile='' user='orbit' bridge='' source='' image_path='' live=0 timezone notes
    local maxcpu maxram maxdisk answer temp exp_ts created=0
    maxcpu=$(host_cpu_count); maxram=$(host_total_ram_mb); maxdisk=$(host_free_disk_gb)
    [[ -z "$maxram" ]] && maxram=1024; [[ -z "$maxdisk" ]] && maxdisk=5
    cpu=$(config_get default_cpu || printf '2'); ram=$(config_get default_ram || printf '2048'); disk=$(config_get default_disk || printf '20'); os=$(config_get default_os || printf 'Ubuntu'); timezone=$(config_get tz || printf 'UTC'); keyfile=$(config_get ssh_key || true)
    (( ram > maxram )) && ram="$maxram"; (( disk > maxdisk )) && disk="$maxdisk"

    while (( step >= 1 && step <= 10 )); do
        case "$step" in
            1)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Name'; c reset; echo
                ui_prompt 'Name (a-z0-9-, 3-32 chars; q=back)' answer
                [[ "$answer" == q ]] && return
                valid_name "$answer" || { c err; echo 'Invalid VPS name.'; c reset; ui_pause; continue; }
                [[ ! -e "${BASE_DIR}/vps/${answer}" ]] || { echo 'A VPS with that name already exists.'; ui_pause; continue; }
                name="$answer"; ((step++));;
            2)
                local -a opts=('Ubuntu' 'Debian' 'Alpine' 'Fedora' 'Arch' 'Rocky' 'Alma' 'openSUSE' 'Kali' 'Custom URL/ISO' 'Back')
                ui_menu 'Create VPS — OS' "${opts[@]}"; answer=$?
                (( answer == 10 || answer == 255 )) && { ((step--)); continue; }; os="${opts[$answer]}"; ((step++));;
            3)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Version / Image'; c reset; echo
                if [[ "$os" == 'Custom URL/ISO' ]]; then
                    ui_prompt 'ISO path/URL or raw/qcow2 image URL' source
                    [[ -n "$source" ]] || continue
                    ui_prompt 'Boot ISO live system? (y/N)' answer; [[ "${answer,,}" == y ]] && live=1 || live=0
                    ver='custom'
                else
                    ui_prompt "Version (recommended: 24.04 for Ubuntu, 12 for Debian; 'latest' allowed where supported)" answer
                    [[ -n "$answer" ]] || continue
                    ver="$answer"
                fi
                ((step++));;
            4)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Resources'; c reset; echo
                printf 'Host limits: CPU %s cores | RAM %s MB | free disk %s GB\n' "$maxcpu" "$maxram" "$maxdisk"
                ui_prompt "CPU [${cpu}]" temp; [[ -n "$temp" ]] && cpu="$temp"
                ui_prompt "RAM MB [${ram}]" temp; [[ -n "$temp" ]] && ram="$temp"
                ui_prompt "Disk GB [${disk}]" temp; [[ -n "$temp" ]] && disk="$temp"
                valid_uint "$cpu" && valid_uint "$ram" && valid_uint "$disk" || { echo 'Resources must be whole numbers.'; ui_pause; continue; }
                (( cpu>=1 && cpu<=maxcpu )) || { echo 'CPU exceeds host limit.'; ui_pause; continue; }
                (( ram>=256 && ram<=maxram )) || { echo 'RAM must be >=256MB and within host limit.'; ui_pause; continue; }
                (( disk>=1 && disk<=maxdisk )) || { echo 'Disk exceeds currently free host space.'; ui_pause; continue; }
                ((step++));;
            5)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Network'; c reset; echo
                ui_prompt 'Network mode (nat/bridge)' temp; [[ -n "$temp" ]] && net="${temp,,}"
                [[ "$net" == nat || "$net" == bridge ]] || { echo 'Use nat or bridge.'; ui_pause; continue; }
                if [[ "$net" == bridge ]]; then ui_prompt 'Bridge name (e.g. br0)' bridge; [[ -n "$bridge" ]] || continue; fi
                ui_prompt 'Port forwards host:guest, comma separated (blank for none)' ports
                create_parse_ports "$ports" || { echo 'Invalid port-forward list.'; ui_pause; continue; }
                ((step++));;
            6)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Expiry'; c reset; echo
                ui_prompt "Expiry hours (0=never) [${expiry}]" temp; [[ -n "$temp" ]] && expiry="$temp"
                valid_uint "$expiry" || { echo 'Expiry must be a non-negative integer number of hours.'; ui_pause; continue; }
                (( expiry > 0 )) && exp_ts=$(( $(date +%s) + expiry*3600 )) || exp_ts=0
                ((step++));;
            7)
                local -a nodes=('local') nfile
                for nfile in "${BASE_DIR}/nodes/"*.env; do [[ -f "$nfile" ]] && nodes+=("$(basename "$nfile" .env)"); done
                nodes+=('Back')
                ui_menu 'Create VPS — Node / Region' "${nodes[@]}"; answer=$?
                (( answer == ${#nodes[@]}-1 || answer == 255 )) && { ((step--)); continue; }
                node="${nodes[$answer]}"
                if [[ "$node" == local ]]; then region='local'; else region=$(backend_node_value "$node" REGION || printf '%s' "$node"); fi
                ((step++));;
            8)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — SSH / Setup'; c reset; echo
                printf 'Timezone: %s\n' "$timezone"
                ui_prompt 'SSH public/private key base path (e.g. ~/.ssh/id_ed25519)' temp
                [[ -n "$temp" ]] && keyfile="${temp/#\~/$HOME}"
                [[ -f "${keyfile}.pub" ]] || { echo 'Public key file not found.'; ui_pause; continue; }
                ui_prompt "Guest SSH user [${user}]" temp; [[ -n "$temp" ]] && user="$temp"
                [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo 'Invalid SSH username.'; ui_pause; continue; }
                ui_prompt 'Notes (optional)' notes
                ui_prompt 'Automatic URL/tunnel (none/cloudflared/caddy)' temp; [[ -n "$temp" ]] && urlmode="${temp,,}"
                [[ "$urlmode" == none || "$urlmode" == cloudflared || "$urlmode" == caddy ]] || { echo 'Choose none, cloudflared or caddy.'; ui_pause; continue; }
                if [[ "$urlmode" != none ]]; then
                    ui_prompt 'Guest target service port [80]' temp; [[ -n "$temp" ]] && url_guest_port="$temp"
                    valid_port "$url_guest_port" || { echo 'Invalid service port.'; ui_pause; continue; }
                fi
                ((step++));;
            9)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Delete Password'; c reset; echo
                ui_prompt_secret 'Confirm main password' answer
                auth_verify_value "$answer" "$(auth_get_main_record)" || { echo 'Main password incorrect.'; ui_pause; continue; }
                ui_prompt_secret 'Set VPS delete password' delpass
                [[ -n "$delpass" ]] || { echo 'Delete password is required.'; ui_pause; continue; }
                ((step++));;
            10)
                ui_clear; ui_paint_bg; c acc; ui_center_text 'Create VPS — Summary'; c reset; echo
                printf 'Name     : %s\nOS       : %s %s\nCPU/RAM  : %s / %sMB\nDisk     : %sGB\nNetwork  : %s\nPorts    : %s\nExpiry   : %sh\nNode     : %s (%s)\nSSH user : %s\nURL mode : %s\n' "$name" "$os" "$ver" "$cpu" "$ram" "$disk" "$net" "${ports:-none}" "$expiry" "$node" "$region" "$user" "$urlmode"
                ui_confirm 'Create this VPS?' || { ((step--)); continue; }
                mkdir -p "${BASE_DIR}/vps/${name}" || return 1
                created=1
                local del_record; del_record="$(generate_id):$(auth_hash "$delpass" "$(generate_id)")"
                # Re-hash delete password with its actual salt for DELETE_HASH.
                local dsalt; dsalt="${del_record%%:*}"; del_record="${dsalt}:$(auth_hash "$delpass" "$dsalt")"
                local sshport; sshport=$(backend_allocate_port 2200) || { echo 'Could not allocate an SSH port.'; rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                case "$os" in
                    'Custom URL/ISO') image_path=$(resolve_custom_image "$source" "$name") || { rm -rf "${BASE_DIR}/vps/${name}"; return 1; };;
                    *)
                        if [[ "$ORBIT_BACKEND" == kvm || "$ORBIT_BACKEND" == qemu-tcg ]]; then
                            image_path=$(resolve_official_image "$os" "$ver") || { echo 'This OS image could not be verified. Use a custom image or a container backend.'; rm -rf "${BASE_DIR}/vps/${name}"; ui_pause; return; }
                        fi;;
                esac
                (( ${#ports} == 0 )) && ports="${sshport}:22" || ports="${ports},${sshport}:22"
                local url_host_port=0
                if [[ "$urlmode" != none ]]; then
                    url_host_port=$(backend_allocate_port 8080) || { echo 'Could not allocate URL host port.'; rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                    ports+=",${url_host_port}:${url_guest_port}"
                fi
                exp_ts=0; (( expiry > 0 )) && exp_ts=$(( $(date +%s) + expiry*3600 ))
                cat > "${BASE_DIR}/vps/${name}/meta.env" <<META
NAME=${name}
ID=$(generate_id)
BACKEND=${ORBIT_BACKEND}
NODE=${node}
REGION=${region}
OS=${os}
OS_VERSION=${ver}
CPU=${cpu}
RAM_MB=${ram}
DISK_GB=${disk}
NET_MODE=${net}
PORTS=${ports}
CREATED=$(date +%s)
EXPIRES=${exp_ts}
STATE=created
LAST_START=0
RUN_SECONDS=0
AUTO_RESTART=0
RESTART_RETRIES=0
RETRY_LIMIT=3
SCHEDULES=
DELETE_HASH=${del_record}
SSH_PORT=${sshport}
SSH_USER=${user}
SSH_KEY=${keyfile}
URL=
URL_MODE=${urlmode}
URL_GUEST_PORT=${url_guest_port}
URL_HOST_PORT=${url_host_port}
TZ=${timezone}
LIVE_ISO=${live}
ISO_PATH=
IMAGE_PATH=${image_path}
BRIDGE=${bridge}
NOTES=${notes}
META
                chmod 600 "${BASE_DIR}/vps/${name}/meta.env"
                if [[ "$os" == "Custom URL/ISO" ]]; then
                    case "${image_path##*.}" in
                        iso|ISO)
                            vps_set_meta "$name" ISO_PATH "$image_path"
                            vps_set_meta "$name" IMAGE_PATH 
                            if (( live == 0 )); then
                                command -v qemu-img >/dev/null 2>&1 || { echo "qemu-img is required for custom ISO installation."; rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                                qemu-img create -f qcow2 "${BASE_DIR}/vps/${name}/disk.qcow2" "${disk}G" >/dev/null || { rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                            fi
                            ;;
                    esac
                fi
                if [[ "$ORBIT_BACKEND" == kvm || "$ORBIT_BACKEND" == qemu-tcg ]]; then
                    if (( live == 0 )); then
                        create_make_cloud_init "$name" "$keyfile" "$timezone" "$user" "${BASE_DIR}/vps/${name}/cloud-init.yaml" "$(config_get host_os || true)" || { rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                    fi
                    if (( live == 0 )) && command -v cloud-localds >/dev/null 2>&1; then cloud-localds "${BASE_DIR}/vps/${name}/seed.iso" "${BASE_DIR}/vps/${name}/cloud-init.yaml" >/dev/null || { rm -rf "${BASE_DIR}/vps/${name}"; return 1; }
                    elif (( live == 0 )) && command -v genisoimage >/dev/null 2>&1; then
                        local cdir; cdir=$(mktemp -d)
                        printf '%s\n' "instance-id: ${name}" > "${cdir}/meta-data"; cp "${BASE_DIR}/vps/${name}/cloud-init.yaml" "${cdir}/user-data"
                        genisoimage -quiet -volid cidata -joliet -rock -output "${BASE_DIR}/vps/${name}/seed.iso" "$cdir" || { rm -rf "$cdir" "${BASE_DIR}/vps/${name}"; return 1; }
                        rm -rf "$cdir"
                    else echo 'Missing cloud-localds or genisoimage; cannot build cloud-init seed.' >&2; rm -rf "${BASE_DIR}/vps/${name}"; return 1; fi
                fi
                if ! backend_create "$name"; then
                    echo "Creation failed. VPS rolled back. Log: ${BASE_DIR}/logs/orbitbash.log"
                    backend_destroy "$name" 2>/dev/null || true
                    rm -rf "${BASE_DIR}/vps/${name}"
                    return 1
                fi
                log_msg INFO "VPS=${name} created backend=${ORBIT_BACKEND} node=${node}"
                echo 'VPS created successfully.'
                ui_pause
                return 0
                ;;
        esac
    done
}
