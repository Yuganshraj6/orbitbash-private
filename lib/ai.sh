# OrbitBash OpenAI-compatible AI helper

_ai_decrypt_key() {
    local pass="$1" enc; enc=$(config_get ai_key_enc || true)
    [[ -n "$enc" ]] || return 1
    printf '%s' "$enc" | openssl enc -d -aes-256-cbc -pbkdf2 -a -pass pass:"$pass" 2>/dev/null
}

_ai_verify_main() {
    local pass="$1"; auth_verify_value "$pass" "$(auth_get_main_record)"
}

cmd_ai_test() {
    echo 'Testing AI provider…'
    ai_ask 'Reply with exactly: OrbitBash AI test OK' || { ui_pause; return 1; }
    ui_pause
}

cmd_ai_config() {
    command -v openssl >/dev/null 2>&1 || { echo 'OpenSSL is required for encrypted AI key storage.'; ui_pause; return; }
    while true; do
        ui_menu 'AI Provider' 'Configure OpenAI-compatible provider' 'Test call' 'Ask AI about recent log' 'Back'; local c=$?
        case "$c" in
            0)
                local url model key pass enc
                ui_clear; ui_paint_bg; c acc; ui_center_text 'AI Provider Configuration'; c reset; echo
                ui_prompt 'OpenAI-compatible Base URL (e.g. https://api.example/v1)' url; uri_safe "$url" || { echo 'Invalid URL.'; ui_pause; continue; }
                ui_prompt 'Model' model; [[ -n "$model" ]] || continue
                ui_prompt_secret 'API key' key
                ui_prompt_secret 'Main password (used to encrypt API key)' pass
                _ai_verify_main "$pass" || { echo 'Main password incorrect.'; ui_pause; continue; }
                enc=$(printf '%s' "$key" | openssl enc -aes-256-cbc -pbkdf2 -a -salt -pass pass:"$pass" 2>/dev/null) || { echo 'Encryption failed.'; ui_pause; continue; }
                config_set ai_url "$url"; config_set ai_model "$model"; config_set ai_key_enc "$enc"; chmod 600 "${BASE_DIR}/config"
                echo 'AI configuration saved (key encrypted).'; ui_pause;;
            1) cmd_ai_test;;
            2) cmd_ai_ask_log;;
            3|255) return;;
        esac
    done
}

ai_ask() {
    local prompt="$1" pass url model key payload
    url=$(config_get ai_url || true); model=$(config_get ai_model || true)
    [[ -n "$url" && -n "$model" ]] || { echo 'AI is not configured.' >&2; return 1; }
    ui_prompt_secret 'Main password to decrypt AI key' pass
    key=$(_ai_decrypt_key "$pass") || { echo 'Unable to decrypt AI key.' >&2; return 1; }
    payload=$(python3 - "$model" "$prompt" <<'PY'
import json,sys
print(json.dumps({'model':sys.argv[1],'messages':[{'role':'user','content':sys.argv[2]}]}))
PY
) || return 1
    curl --fail --silent --show-error --connect-timeout 8 --max-time 45 -H 'Content-Type: application/json' -H "Authorization: Bearer ${key}" -d "$payload" "${url%/}/chat/completions" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j["choices"][0]["message"]["content"])'
}

cmd_ai_ask_log() {
    local prompt answer
    ui_prompt 'Question about the log/config' prompt
    answer=$(ai_ask "${prompt}\n\nRelevant OrbitBash log:\n$(tail -n 80 "${BASE_DIR}/logs/orbitbash.log" 2>/dev/null | sed 's/[^[:print:]\t]//g')") || { ui_pause; return; }
    printf '\n%s\n' "$answer"; ui_pause
}
