THEME_DIR="${BASE_DIR}/themes"
C_MODE=mono
T_BG=''; T_FG=''; T_ACC=''; T_BD=''; T_HL_BG=''; T_HL_FG=''; T_DIM=''; T_OK=''; T_WARN=''; T_ERR=''; LOGO_FROM=''; LOGO_TO=''; BORDER_STYLE='ascii'

_hex_rgb() {
    local h="${1#\#}"
    [[ "$h" =~ ^[0-9a-fA-F]{6}$ ]] || { printf '255 255 255\n'; return; }
    printf '%d %d %d\n' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}

_hex_ansi_fg() {
    local h="$1" r g b; read -r r g b < <(_hex_rgb "$h")
    printf '38;2;%d;%d;%dm' "$r" "$g" "$b"
}
_hex_ansi_bg() {
    local h="$1" r g b; read -r r g b < <(_hex_rgb "$h")
    printf '48;2;%d;%d;%dm' "$r" "$g" "$b"
}
_rgb_to_256_fg() {
    local r="$1" g="$2" b="$3" ri gi bi idx
    ri=$(( r*5/255 )); gi=$(( g*5/255 )); bi=$(( b*5/255 )); idx=$((16+36*ri+6*gi+bi))
    printf '38;5;%dm' "$idx"
}
_rgb_to_256_bg() {
    local r="$1" g="$2" b="$3" ri gi bi idx
    ri=$(( r*5/255 )); gi=$(( g*5/255 )); bi=$(( b*5/255 )); idx=$((16+36*ri+6*gi+bi))
    printf '48;5;%dm' "$idx"
}

_theme_value() { awk -F= -v k="$2" 'index($0,k"=")==1 {sub(/^[^=]*=/,""); print; exit}' "$1"; }

theme_load() {
    local saved="$(config_get theme || true)" file role value r g b
    [[ -z "$saved" ]] && saved='Dark Purple Pastel Pink'
    file="${THEME_DIR}/${saved}.theme"
    [[ -f "$file" ]] || file="${THEME_DIR}/Dark Purple Pastel Pink.theme"
    T_BG=$(_theme_value "$file" bg); T_FG=$(_theme_value "$file" fg); T_ACC=$(_theme_value "$file" accent)
    T_BD=$(_theme_value "$file" border); T_HL_BG=$(_theme_value "$file" highlight_bg); T_HL_FG=$(_theme_value "$file" highlight_fg)
    T_DIM=$(_theme_value "$file" dim); T_OK=$(_theme_value "$file" ok); T_WARN=$(_theme_value "$file" warn); T_ERR=$(_theme_value "$file" err)
    LOGO_FROM=$(_theme_value "$file" logo_from); LOGO_TO=$(_theme_value "$file" logo_to); BORDER_STYLE=$(_theme_value "$file" border_style)
    [[ -z "$BORDER_STYLE" ]] && BORDER_STYLE=ascii
    local cols; cols=$(tput colors 2>/dev/null || printf '0')
    if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == dumb || ! "$cols" =~ ^[0-9]+$ || "$cols" -lt 8 ]]; then
        C_MODE=mono
    elif [[ "${COLORTERM:-}" =~ ^(truecolor|24bit)$ ]]; then
        C_MODE=truecolor
    elif (( cols >= 256 )); then
        C_MODE=256
    else
        C_MODE=8
    fi
    [[ "$saved" == 'Mono Black' ]] && C_MODE=mono
    export C_MODE T_BG T_FG T_ACC T_BD T_HL_BG T_HL_FG T_DIM T_OK T_WARN T_ERR LOGO_FROM LOGO_TO BORDER_STYLE
}

c() {
    local role="${1:-}" code=''
    [[ "$C_MODE" == mono ]] && return 0
    if [[ "$C_MODE" == 8 ]]; then
        case "$role" in
            bg) code='40m';; fg) code='37m';; acc) code='35m';; bd) code='36m';; dim) code='90m';; ok) code='32m';; warn) code='33m';; err) code='31m';;
            hl) printf '\033[7m'; return;; reset|full_reset) printf '\033[0m'; return;; *) return 0;;
        esac
        printf '\033[%s' "$code"; return
    fi
    case "$role" in
        bg) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_bg "$T_BG" || _rgb_to_256_bg $(_hex_rgb "$T_BG"));;
        fg) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_FG" || _rgb_to_256_fg $(_hex_rgb "$T_FG"));;
        acc) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_ACC" || _rgb_to_256_fg $(_hex_rgb "$T_ACC"));;
        bd) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_BD" || _rgb_to_256_fg $(_hex_rgb "$T_BD"));;
        dim) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_DIM" || _rgb_to_256_fg $(_hex_rgb "$T_DIM"));;
        ok) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_OK" || _rgb_to_256_fg $(_hex_rgb "$T_OK"));;
        warn) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_WARN" || _rgb_to_256_fg $(_hex_rgb "$T_WARN"));;
        err) code=$([[ "$C_MODE" == truecolor ]] && _hex_ansi_fg "$T_ERR" || _rgb_to_256_fg $(_hex_rgb "$T_ERR"));;
        hl)
            if [[ "$C_MODE" == truecolor ]]; then code="$(printf '%s%s' "$(_hex_ansi_bg "$T_HL_BG")" "$(_hex_ansi_fg "$T_HL_FG")")"
            else code="$(printf '%s%s' "$(_rgb_to_256_bg $(_hex_rgb "$T_HL_BG"))" "$(_rgb_to_256_fg $(_hex_rgb "$T_HL_FG"))")"; fi;;
        reset|full_reset) printf '\033[0m'; return;; *) return 0;;
    esac
    printf '\033[%s' "$code"
}

# The C_MODE-aware line wrapper is intentionally small; callers reset after lines.
theme_sample() {
    local tl='┌' tr='┐' bl='└' br='┘' hz='─' vt='│'
    [[ "$C_MODE" == mono || "${BORDER_STYLE:-ascii}" == ascii ]] && { tl='+'; tr='+'; bl='+'; br='+'; hz='-'; vt='|'; }
    local top mid ok bottom
    top="${tl}$(ui_repeat_char 30 "$hz")${tr}"
    mid="${vt} OrbitBash Private              ${vt}"
    ok="${vt} OK    Warning    Error        ${vt}"
    bottom="${bl}$(ui_repeat_char 30 "$hz")${br}"
    ui_clear; ui_paint_bg
    ui_center_text 'Theme Preview'
    printf '\n'
    ui_center_text "$(c bd)$top$(c reset)"
    ui_center_text "$(c bd)${vt} $(c acc)OrbitBash$(c reset) $(c dim)Private$(c reset)              $(c bd)${vt}$(c reset)"
    ui_center_text "$(c bd)${vt} $(c ok)OK$(c reset)   $(c warn)Warning$(c reset)   $(c err)Error$(c reset)        $(c bd)${vt}$(c reset)"
    ui_center_text "$(c bd)$bottom$(c reset)"
    ui_pause
}

ui_logo() {
    ui_resize
    local -a logo=() ; local idx ch line len pos fromr fromg fromb tor tog tob rr gg bb code private_inline=0 total
    if command -v figlet >/dev/null 2>&1; then
        mapfile -t logo < <(figlet -f slant 'OrbitBash' 2>/dev/null || true)
    fi
    if (( ${#logo[@]} == 0 )); then
        if (( UI_COLS >= 80 )); then
            logo=(
'   ____       _     _ _  ____            _        '
'  / __ \_____| |__ (_) |/ __ )____ _____| |__     '
' / / / / ___/ __ \/ / __/ __  / __ `/ ___/ __ \   '
'/ /_/ / /  / /_/ / / /_/ /_/ / /_/ (__  ) / / /   '
'\____/_/  /_.___/_/\__/_____/\__,_/____/_/ /_/    ')
        elif (( UI_COLS >= 40 )); then
            logo=(
'  ___      _     _ _ _   ____              __  __'
' / _ \____| |__ (_) | | / / __ )____  ____/ / / /'
'/ , _/___/| / / / | | |/ / __  / __ \/ __  / / / '
'/_/|_|    |__/ /_/ |_|___/_____\__,_/\__,_/ /_/  ')
        else
            printf 'OrbitBash  '; c dim; printf 'Private'; c reset; printf '\n'; return
        fi
    fi
    total=${#logo[@]}
    for ((idx=0;idx<total;idx++)); do
        line=${logo[$idx]}; len=${#line}
        if [[ "$C_MODE" == truecolor || "$C_MODE" == 256 || "$C_MODE" == 8 ]]; then
            read -r fromr fromg fromb < <(_hex_rgb "$LOGO_FROM"); read -r tor tog tob < <(_hex_rgb "$LOGO_TO")
            for ((pos=0;pos<len;pos++)); do
                ch=${line:pos:1}
                if [[ "$C_MODE" == truecolor ]]; then
                    if (( len > 1 )); then rr=$((fromr+(tor-fromr)*pos/(len-1))); gg=$((fromg+(tog-fromg)*pos/(len-1))); bb=$((fromb+(tob-fromb)*pos/(len-1))); else rr=$fromr; gg=$fromg; bb=$fromb; fi
                    printf '\033[38;2;%d;%d;%dm%s' "$rr" "$gg" "$bb" "$ch"
                elif [[ "$C_MODE" == 256 ]]; then
                    code=$((91 + pos*6/(len>1 ? len-1 : 1))); (( code > 97 )) && code=97; printf '\033[38;5;%dm%s' "$code" "$ch"
                else
                    printf '%s' "$ch"
                fi
            done
        else printf '%s' "$line"; fi
        if (( idx == total-1 && UI_COLS - len >= 11 )); then c dim; printf '  Private'; c reset; private_inline=1; fi
        printf '\033[0m\n' 2>/dev/null || printf '\n'
    done
    (( private_inline )) || { c dim; printf '  Private'; c reset; printf '\n'; }
}
