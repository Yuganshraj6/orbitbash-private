# OrbitBash remote SSH nodes

_node_valid() { valid_name "$1"; }

nodes_menu() {
    while true; do
        local -a opts=('Add Node' 'List Nodes' 'Remove Node' 'Test Node' 'Set Default Node' 'Back')
        ui_menu 'SSH Nodes / Regions' "${opts[@]}"; local c=$?
        case "$c" in
            0) _node_add;; 1) _node_list;; 2) _node_remove;; 3) _node_test;; 4) _node_default;; 5|255) return;;
        esac
    done
}

_node_add() {
    local name host user key region f
    ui_clear; ui_paint_bg; printf 'Add SSH node\n\n'
    ui_prompt 'Name (a-z0-9-)' name; _node_valid "$name" || { echo 'Invalid name.'; ui_pause; return; }
    f="${BASE_DIR}/nodes/${name}.env"; [[ ! -e "$f" ]] || { echo 'Node already exists.'; ui_pause; return; }
    ui_prompt 'Host/IP' host; [[ -n "$host" ]] || return
    ui_prompt 'SSH user' user; [[ -n "$user" ]] || user=root
    ui_prompt 'SSH key path (blank for agent)' key; key="${key/#\~/$HOME}"
    [[ -z "$key" || -f "$key" ]] || { echo 'Key file not found.'; ui_pause; return; }
    ui_prompt 'Region label' region; [[ -n "$region" ]] || region="$name"
    cat > "$f" <<NODE
HOST=${host}
USER=${user}
KEY=${key}
REGION=${region}
NODE
    chmod 600 "$f"
    printf 'Node added.\n'; ui_pause
}

_node_list() {
    ui_clear; ui_paint_bg; c acc; ui_center_text 'SSH Nodes'; c reset; echo
    local f n host region def; def=$(config_get node_default || true)
    for f in "${BASE_DIR}/nodes/"*.env; do
        [[ -f "$f" ]] || continue
        n=$(basename "$f" .env); host=$(backend_node_value "$n" HOST); region=$(backend_node_value "$n" REGION)
        printf '%-18s %-30s %-18s%s\n' "$n" "$host" "$region" "$( [[ "$n" == "$def" ]] && printf '  [default]' )"
    done
    ui_pause
}

_node_remove() {
    local -a list=(); local f; for f in "${BASE_DIR}/nodes/"*.env; do [[ -f "$f" ]] && list+=("$(basename "$f" .env)"); done; list+=('Back')
    (( ${#list[@]} > 1 )) || { echo 'No nodes.'; ui_pause; return; }
    ui_menu 'Remove node' "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return
    local n="${list[$c]}"; echo 'Estimated time: ~1s'; ui_confirm "Remove node '$n'?" || return; rm -f "${BASE_DIR}/nodes/${n}.env"; [[ "$(config_get node_default)" == "$n" ]] && config_set node_default ''
}

_node_test() {
    local -a list=(); local f; for f in "${BASE_DIR}/nodes/"*.env; do [[ -f "$f" ]] && list+=("$(basename "$f" .env)"); done; list+=('Back');
    (( ${#list[@]} > 1 )) || { echo 'No nodes.'; ui_pause; return; }
    ui_menu 'Test node' "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return
    local n="${list[$c]}"; echo 'Estimated time: ~10s'; if backend_remote_ssh "$n" 'printf ready'; then printf '\nNode is reachable.\n'; else printf '\nNode test failed.\n'; fi; ui_pause
}

_node_default() {
    local -a list=(); local f; for f in "${BASE_DIR}/nodes/"*.env; do [[ -f "$f" ]] && list+=("$(basename "$f" .env)"); done; list+=('Back');
    (( ${#list[@]} > 1 )) || { echo 'No nodes.'; ui_pause; return; }
    ui_menu 'Default node' "${list[@]}"; local c=$?; (( c == ${#list[@]}-1 || c == 255 )) && return; config_set node_default "${list[$c]}"; echo 'Default node saved.'; ui_pause
}
