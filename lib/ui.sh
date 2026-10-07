# OrbitBash UI layer
UI_COLS=80
UI_LINES=24
UI_ACTIVE=0
UI_STTY=""

ui_resize() {
    UI_COLS=$(tput cols 2>/dev/null || printf '80')
    UI_LINES=$(tput lines 2>/dev/null || printf '24')
    [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
    [[ "$UI_LINES" =~ ^[0-9]+$ ]] || UI_LINES=24
}

ui_handle_resize() { ui_resize; }

ui_init() {
    ui_resize
    if [[ -t 1 ]]; then
        tput smcup 2>/dev/null || true
        tput civis 2>/dev/null || true
        UI_ACTIVE=1
        UI_STTY=$(stty -g 2>/dev/null || true)
        trap 'ui_cleanup; exit 130' INT TERM HUP
        trap 'ui_handle_resize' WINCH
    fi
}

ui_cleanup() {
    if (( UI_ACTIVE )); then
        [[ -n "$UI_STTY" ]] && stty "$UI_STTY" 2>/dev/null || stty sane 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        tput rmcup 2>/dev/null || true
        UI_ACTIVE=0
    fi
}

ui_clear() {
    if [[ -t 1 ]]; then
        tput clear 2>/dev/null || printf '\033[2J\033[H'
    else
        printf '\n'
    fi
}

ui_paint_bg() {
    if [[ -t 1 ]]; then
        c bg
        printf '\033[2J\033[H'
        c reset
    fi
}


ui_repeat_char() {
    local n="$1" ch="$2" i
    for ((i=0;i<n;i++)); do printf '%s' "$ch"; done
}

ui_center_text() {
    local text="$1" width pad
    width=${#text}; pad=$(( (UI_COLS - width) / 2 )); (( pad < 0 )) && pad=0
    printf '%*s%s\n' "$pad" '' "$text"
}

ui_box_line() {
    local w="$1" ch="${2:--}" title="${3:-}" left="+" right="+" line
    case "${BORDER_STYLE:-ascii}" in
        round) left='╭'; right='╮'; ch='─';;
        double) left='╔'; right='╗'; ch='═';;
        square) left='┌'; right='┐'; ch='─';;
        *) left='+'; right='+'; ch='-';;
    esac
    line=$(ui_repeat_char "$w" "$ch")
    if [[ -n "$title" ]]; then
        title=" ${title} "
        local avail=$((w-2))
        title=${title:0:avail}
        line="${line:0:2}${title}${line:$((2+${#title}))}"
    fi
    c bd; printf '%s%s%s\n' "$left" "$line" "$right"; c reset
}

ui_draw_box() {
    local x="$1" y="$2" w="$3" h="$4" title="${5:-}" i body="${6:-}"
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ && "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 2
    (( w < 4 || h < 2 )) && return 2
    local tl='+' tr='+' bl='+' br='+' hz='-' vt='|'
    case "${BORDER_STYLE:-ascii}" in
        round) tl='╭'; tr='╮'; bl='╰'; br='╯'; hz='─'; vt='│';;
        double) tl='╔'; tr='╗'; bl='╚'; br='╝'; hz='═'; vt='║';;
        square) tl='┌'; tr='┐'; bl='└'; br='┘'; hz='─'; vt='│';;
    esac
    local line; line=$(ui_repeat_char "$((w-2))" "$hz")
    tput cup "$y" "$x" 2>/dev/null || true
    c bd; printf '%s%s%s' "$tl" "$line" "$tr"; c reset
    for ((i=1;i<h-1;i++)); do
        tput cup $((y+i)) "$x" 2>/dev/null || true
        c bd; printf '%s' "$vt"; c reset
        printf '%*s' $((w-2)) ''
        c bd; printf '%s' "$vt"; c reset
    done
    tput cup $((y+h-1)) "$x" 2>/dev/null || true
    c bd; printf '%s%s%s' "$bl" "$line" "$br"; c reset
    if [[ -n "$title" ]]; then
        tput cup "$y" $((x+2)) 2>/dev/null || true
        c bd; printf ' %s ' "$title"; c reset
    fi
    [[ -n "$body" ]] && { tput cup $((y+1)) $((x+2)) 2>/dev/null || true; printf '%-*s' $((w-4)) "$body"; }
}

ui_read_key() {
    local key rest
    IFS= read -rsn1 key < /dev/tty || return 1
    case "$key" in
        $'\x1b')
            IFS= read -rsn1 -t 0.1 rest < /dev/tty || true
            if [[ "$rest" == '[' ]]; then
                IFS= read -rsn1 -t 0.1 rest < /dev/tty || true
                case "$rest" in
                    A) REPLY=up;; B) REPLY=down;; C) REPLY=right;; D) REPLY=left;; *) REPLY=esc;;
                esac
            else
                REPLY=esc
            fi;;
        '') REPLY=enter;;
        ' ') REPLY=space;;
        $'\x03') REPLY=ctrl-c;;
        [qQ]) REPLY=q;;
        [jJ]) REPLY=down;;
        [kK]) REPLY=up;;
        *) REPLY="$key";;
    esac
}

ui_menu() {
    local title="$1"; shift
    local -a options=("$@")
    local selected=0 key i
    (( ${#options[@]} > 0 )) || return 255
    while true; do
        ui_resize
        ui_clear; ui_paint_bg
        c acc; ui_center_text "$title"; c reset
        echo
        local maxw=$(( UI_COLS - 8 )); (( maxw > 70 )) && maxw=70; (( maxw < 24 )) && maxw=24
        local x=$(( (UI_COLS-maxw)/2 )); (( x < 0 )) && x=0
        local y=3 h=$(( ${#options[@]} + 4 )); (( h > UI_LINES-2 )) && h=$((UI_LINES-2))
        ui_draw_box "$x" "$y" "$maxw" "$h" "$title"
        for ((i=0; i<${#options[@]}; i++)); do
            local line="  ${options[$i]}"
            tput cup $((y+2+i)) $((x+3)) 2>/dev/null || true
            if (( i == selected )); then c hl; printf '%-*s' $((maxw-6)) "> $line"; c reset
            else printf '%-*s' $((maxw-6)) "$line"; fi
        done
        tput cup $((UI_LINES-1)) 0 2>/dev/null || true
        c dim; printf '↑↓/j k  Enter=select  Esc/q=back  1-9=jump'; c reset
        ui_read_key || return 255; key="$REPLY"
        case "$key" in
            up) (( selected > 0 )) && ((selected--));;
            down) (( selected < ${#options[@]}-1 )) && ((selected++));;
            enter) return "$selected";;
            esc|q) return 255;;
            [1-9]) i=$((key-1)); (( i < ${#options[@]} )) && selected=$i;;
            ctrl-c) return 255;;
        esac
    done
}

ui_multiselect() {
    local title="$1"; shift
    local -a options=("$@"); local -a chosen=(); local selected=0 key i result=''
    for ((i=0;i<${#options[@]};i++)); do chosen[i]=0; done
    (( ${#options[@]} > 0 )) || { printf '\n'; return 0; }
    while true; do
        ui_resize; ui_clear; ui_paint_bg
        c acc; ui_center_text "$title"; c reset; echo
        for ((i=0;i<${#options[@]};i++)); do
            [[ ${chosen[$i]} -eq 1 ]] && result='x' || result=' '
            if (( i == selected )); then c hl; printf '> [%s] %s\n' "$result" "${options[$i]}"; c reset
            else printf '  [%s] %s\n' "$result" "${options[$i]}"; fi
        done
        c dim; printf '\nSpace=toggle  Enter=done  Esc/q=back\n'; c reset
        ui_read_key || return 255; key="$REPLY"
        case "$key" in
            up) (( selected > 0 )) && ((selected--));;
            down) (( selected < ${#options[@]}-1 )) && ((selected++));;
            space) chosen[$selected]=$((1-${chosen[$selected]}));;
            enter)
                result=''; for ((i=0;i<${#options[@]};i++)); do (( chosen[i] )) && result+="${options[$i]}|"; done
                printf '%s\n' "${result%|}"; return 0;;
            esc|q|ctrl-c) printf '\n'; return 255;;
        esac
    done
}

ui_prompt() {
    local prompt="$1" var_name="$2" value
    printf '%s: ' "$prompt"
    IFS= read -r value < /dev/tty || value=''
    printf -v "$var_name" '%s' "$value"
}

ui_prompt_secret() {
    local prompt="$1" var_name="$2" value
    printf '%s: ' "$prompt"
    IFS= read -rs value < /dev/tty || value=''
    printf '\n'
    printf -v "$var_name" '%s' "$value"
}

ui_confirm() {
    local prompt="$1" ans
    printf 'Estimated time: ~5s\n'
    while true; do
        printf '%s (y/n): ' "$prompt"
        IFS= read -r ans < /dev/tty || return 1
        case "${ans,,}" in y|yes) return 0;; n|no|q) return 1;; esac
    done
}

ui_pause() { printf '\nPress Enter to continue...'; IFS= read -r _ < /dev/tty || true; }

ui_spinner() {
    local pid="$1" msg="$2" ch='|/-\\' idx=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s %c' "$msg" "${ch:idx%4:1}"
        ((idx++))
        sleep 0.1
    done
    printf '\r%s ✓\n' "$msg"
}

ui_progress_bar() {
    local current="$1" total="$2" msg="${3:-}" width=36 pct filled empty
    (( total <= 0 )) && total=1
    (( current < 0 )) && current=0
    (( current > total )) && current=$total
    pct=$(( current * 100 / total )); filled=$(( pct * width / 100 )); empty=$((width-filled))
    local a=''; local b=''
    (( filled > 0 )) && a=$(printf '%*s' "$filled" '' | tr ' ' '#')
    (( empty > 0 )) && b=$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf '\r%-20s [%s%s] %3d%%' "$msg" "$a" "$b" "$pct"
}

ui_start_page() {
    local pass='' key='' oldstty='' redraw=1 x w y
    if ! oldstty=$(stty -g < /dev/tty 2>/dev/null); then
        ui_clear; ui_paint_bg; ui_logo; printf '\n'
        ui_center_text 'Enter Password or press Enter to exit';
        ui_prompt_secret 'Password' pass
        [[ -n "$pass" ]] || return 1
        AUTH_INPUT="$pass"; return 0
    fi
    stty -echo -icanon min 0 time 10 < /dev/tty 2>/dev/null || { ui_prompt_secret 'Password' pass; [[ -n "$pass" ]] || return 1; AUTH_INPUT="$pass"; return 0; }
    trap 'stty "$oldstty" < /dev/tty 2>/dev/null || true; exit 130' INT
    while true; do
        ui_resize
        if (( redraw )); then
            ui_clear; ui_paint_bg; ui_logo; printf '\n'
            c dim; ui_center_text "$(date '+%Y-%m-%d %H:%M:%S %Z')"; c reset; printf '\n'
            w=$(( UI_COLS < 56 ? UI_COLS-4 : 52 )); (( w < 32 )) && w=32; x=$(( (UI_COLS-w)/2 )); (( x<0 )) && x=0; y=8
            ui_draw_box "$x" "$y" "$w" 6 'Private Access'
            tput cup $((y+2)) $((x+3)) 2>/dev/null || true; printf 'Enter Password'
            tput cup $((y+3)) $((x+3)) 2>/dev/null || true; c dim; printf 'Input: '; c reset; [[ -n "$pass" ]] && printf '%*s' "${#pass}" '' | tr ' ' '*' || printf 'Waiting…'
            tput cup $((y+4)) $((x+3)) 2>/dev/null || true; c dim; printf 'Empty Enter = Exit'; c reset
            tput cup $((UI_LINES-1)) 0 2>/dev/null || true
            redraw=0
        fi
        IFS= read -rsn1 -t 1 key < /dev/tty 2>/dev/null || { redraw=1; continue; }
        case "$key" in
            '')
                stty "$oldstty" < /dev/tty 2>/dev/null || true; trap - INT
                [[ -n "$pass" ]] || return 1
                AUTH_INPUT="$pass"; return 0;;
            $'\x7f'|$'\x08') pass="${pass%?}";;
            $'\x03') stty "$oldstty" < /dev/tty 2>/dev/null || true; trap - INT; return 255;;
            *) pass+=$key;;
        esac
        redraw=1
    done
}
