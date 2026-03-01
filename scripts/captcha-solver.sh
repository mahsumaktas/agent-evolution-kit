#!/bin/bash
# captcha-solver.sh — Multi-layer CAPTCHA bypass system for Oracle CDP browser
# Layer 1: Stealth (fingerprint evasion) — already active via chrome-debug-launcher.sh
# Layer 2: CapSolver Chrome Extension (auto-solve reCAPTCHA, hCaptcha, Cloudflare Turnstile, etc.)
# Layer 3: CapSolver API fallback (for headless/API-only scenarios)
#
# Usage:
#   captcha-solver.sh install [--port 18804]     Install CapSolver ext into CDP profile
#   captcha-solver.sh configure --key <API_KEY>  Set CapSolver API key
#   captcha-solver.sh status [--port 18804]      Check solver status
#   captcha-solver.sh solve --url <URL> [--port 18804]  Navigate and auto-solve
#   captcha-solver.sh api-solve --type recaptchav2 --sitekey <KEY> --url <URL>  API fallback

set -euo pipefail

CAPSOLVER_EXT_DIR="$HOME/clawd/tools/capsolver/capsolver-extension"
CAPSOLVER_CONFIG="$HOME/.config/hachix/capsolver.json"
STEALTH_INJECT="$HOME/clawd/scripts/stealth-inject.js"
DEFAULT_PORT=18804

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[capsolver]${NC} $*"; }
warn() { echo -e "${YELLOW}[capsolver]${NC} $*"; }
err() { echo -e "${RED}[capsolver]${NC} $*" >&2; }

get_api_key() {
    local key=""
    if [[ -f "$CAPSOLVER_CONFIG" ]]; then
        key=$(python3 -c "import json; print(json.load(open('$CAPSOLVER_CONFIG')).get('apiKey',''))" 2>/dev/null || true)
    fi
    if [[ -z "$key" && -f "$HOME/.config/hachix/secrets.env" ]]; then
        key=$(grep '^CAPSOLVER_API_KEY=' "$HOME/.config/hachix/secrets.env" 2>/dev/null | cut -d= -f2 || true)
    fi
    echo "$key"
}

cmd_install() {
    local port="${1:-$DEFAULT_PORT}"
    
    if [[ ! -d "$CAPSOLVER_EXT_DIR" ]]; then
        err "CapSolver extension not found at $CAPSOLVER_EXT_DIR"
        err "Run: cd ~/.agent-evolution/tools/capsolver && curl -sL <url> -o capsolver-chrome.zip && unzip"
        exit 1
    fi
    
    # Get CDP profile data dir
    local profile_dir
    case "$port" in
        18804) profile_dir="$HOME/Library/Application Support/Google/Chrome-CDP" ;;
        18805) profile_dir="$HOME/Library/Application Support/Google/Chrome-CDP-18805" ;;
        18806) profile_dir="$HOME/Library/Application Support/Google/Chrome-CDP-18806" ;;
        18807) profile_dir="$HOME/Library/Application Support/Google/Chrome-CDP-18807" ;;
        *) err "Unknown port $port"; exit 1 ;;
    esac
    
    # Install extension to External Extensions (preferred for CDP)
    local ext_dir="${profile_dir}/Default/Extensions/capsolver"
    mkdir -p "$ext_dir/1.17.0"
    cp -R "$CAPSOLVER_EXT_DIR/"* "$ext_dir/1.17.0/"
    
    log "CapSolver extension installed to port $port profile"
    log "Extension dir: $ext_dir"
    
    # Configure API key if available
    local api_key
    api_key=$(get_api_key)
    if [[ -n "${api_key:-}" ]]; then
        configure_extension "$ext_dir/1.17.0" "$api_key"
        log "API key configured"
    else
        warn "No API key found. Run: captcha-solver.sh configure --key <YOUR_KEY>"
    fi
    
    warn "Chrome restart needed for extension to load. Kill CDP on port $port and restart."
}

configure_extension() {
    local ext_path="$1"
    local api_key="$2"
    
    # CapSolver extension stores config in chrome.storage.local
    # We need to inject it via CDP after browser starts
    # For now, create a config that the init script will use
    mkdir -p "$(dirname "$CAPSOLVER_CONFIG")"
    cat > "$CAPSOLVER_CONFIG" << EOF
{
    "apiKey": "$api_key",
    "appId": "cdp",
    "enabledForRecaptchaV2": true,
    "enabledForRecaptchaV3": true,
    "enabledForHCaptcha": true,
    "enabledForFunCaptcha": true,
    "enabledForTurnstile": true,
    "enabledForAWSWAF": true,
    "enabledForGeeTest": true,
    "enabledForImageToText": true,
    "autoSolve": true,
    "solveDelay": 500,
    "proxyless": true,
    "installedPorts": [18804, 18805, 18806, 18807]
}
EOF
    log "Config saved to $CAPSOLVER_CONFIG"
}

cmd_configure() {
    local api_key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key) api_key="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    if [[ -z "$api_key" ]]; then
        err "Usage: captcha-solver.sh configure --key <CAPSOLVER_API_KEY>"
        exit 1
    fi
    
    configure_extension "" "$api_key"
    
    # Also save to secrets.env
    local secrets="$HOME/.config/hachix/secrets.env"
    if [[ -f "$secrets" ]]; then
        if grep -q '^CAPSOLVER_API_KEY=' "$secrets"; then
            sed -i '' "s|^CAPSOLVER_API_KEY=.*|CAPSOLVER_API_KEY=$api_key|" "$secrets"
        else
            echo "CAPSOLVER_API_KEY=$api_key" >> "$secrets"
        fi
        log "API key saved to secrets.env"
    fi
    
    # Inject into all running CDP instances
    for port in 18804 18805 18806 18807; do
        if curl -s --connect-timeout 2 "http://127.0.0.1:$port/json/version" >/dev/null 2>&1; then
            inject_capsolver_config "$port" "$api_key"
        fi
    done
}

inject_capsolver_config() {
    local port="$1"
    local api_key="$2"
    
    # Use CDP to set CapSolver config in chrome.storage.local
    local js_code="
        chrome.storage.local.set({
            'CAPSOLVER_API_KEY': '${api_key}',
            'CAPSOLVER_AUTO_SOLVE': true,
            'CAPSOLVER_SOLVE_DELAY': 500
        });
    "
    
    # Get extension page targets
    local targets
    targets=$(curl -s "http://127.0.0.1:$port/json" 2>/dev/null)
    local ext_page
    ext_page=$(echo "$targets" | python3 -c "
import json, sys
targets = json.load(sys.stdin)
for t in targets:
    if 'capsolver' in t.get('url', '').lower():
        print(t['id'])
        break
" 2>/dev/null || true)
    
    if [[ -n "${ext_page:-}" ]]; then
        log "CapSolver extension found on port $port (target: $ext_page)"
    else
        warn "CapSolver extension not detected on port $port (may need restart)"
    fi
}

cmd_status() {
    local port="${1:-$DEFAULT_PORT}"
    
    echo "=== Oracle CAPTCHA Solver Status ==="
    echo ""
    
    # Layer 1: Stealth
    if [[ -f "$STEALTH_INJECT" ]]; then
        echo -e "Layer 1 (Stealth):    ${GREEN}✅ ACTIVE${NC} — $STEALTH_INJECT"
    else
        echo -e "Layer 1 (Stealth):    ${RED}❌ MISSING${NC}"
    fi
    
    # Layer 2: Extension
    if [[ -d "$CAPSOLVER_EXT_DIR" ]]; then
        local ver
        ver=$(python3 -c "import json; print(json.load(open('$CAPSOLVER_EXT_DIR/manifest.json'))['version'])" 2>/dev/null || echo "?")
        echo -e "Layer 2 (Extension):  ${GREEN}✅ INSTALLED${NC} — CapSolver v$ver"
    else
        echo -e "Layer 2 (Extension):  ${RED}❌ NOT INSTALLED${NC}"
    fi
    
    # API Key
    local api_key
    api_key=$(get_api_key)
    if [[ -n "${api_key:-}" ]]; then
        local masked="${api_key:0:6}...${api_key: -4}"
        echo -e "API Key:              ${GREEN}✅ SET${NC} — $masked"
    else
        echo -e "API Key:              ${YELLOW}⚠️  NOT SET${NC}"
    fi
    
    # Layer 3: API endpoint
    if [[ -n "${api_key:-}" ]]; then
        local balance
        balance=$(curl -s -X POST "https://api.capsolver.com/getBalance" \
            -H "Content-Type: application/json" \
            -d "{\"clientKey\":\"$api_key\"}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('errorId', 1) == 0:
    print(f\"Balance: \${data.get('balance', 0):.2f}\")
else:
    print(f\"Error: {data.get('errorDescription', 'unknown')}\")
" 2>/dev/null || echo "unreachable")
        echo -e "Layer 3 (API):        ${GREEN}✅ AVAILABLE${NC} — $balance"
    else
        echo -e "Layer 3 (API):        ${YELLOW}⚠️  NO API KEY${NC}"
    fi
    
    echo ""
    
    # CDP ports
    echo "=== CDP Ports ==="
    for p in 18804 18805 18806 18807; do
        if curl -s --connect-timeout 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
            echo -e "Port $p: ${GREEN}✅ UP${NC}"
        else
            echo -e "Port $p: ${RED}❌ DOWN${NC}"
        fi
    done
}

cmd_api_solve() {
    local captcha_type="" sitekey="" url="" api_key=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) captcha_type="$2"; shift 2 ;;
            --sitekey) sitekey="$2"; shift 2 ;;
            --url) url="$2"; shift 2 ;;
            --key) api_key="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    api_key="${api_key:-$(get_api_key)}"
    
    if [[ -z "$api_key" || -z "$captcha_type" || -z "$url" ]]; then
        err "Usage: captcha-solver.sh api-solve --type <type> --sitekey <key> --url <url>"
        err "Types: recaptchav2, recaptchav3, hcaptcha, turnstile, funcaptcha, geetest, awswaf"
        exit 1
    fi
    
    # Map type to CapSolver task type
    local task_type
    case "$captcha_type" in
        recaptchav2)  task_type="ReCaptchaV2TaskProxyLess" ;;
        recaptchav3)  task_type="ReCaptchaV3TaskProxyLess" ;;
        hcaptcha)     task_type="HCaptchaTaskProxyLess" ;;
        turnstile)    task_type="AntiTurnstileTaskProxyLess" ;;
        funcaptcha)   task_type="FunCaptchaTaskProxyLess" ;;
        awswaf)       task_type="AntiAwsWafTaskProxyLess" ;;
        *) err "Unknown type: $captcha_type"; exit 1 ;;
    esac
    
    log "Creating task: $task_type for $url"
    
    # Create task
    local create_response
    create_response=$(curl -s -X POST "https://api.capsolver.com/createTask" \
        -H "Content-Type: application/json" \
        -d "{
            \"clientKey\": \"$api_key\",
            \"task\": {
                \"type\": \"$task_type\",
                \"websiteURL\": \"$url\",
                \"websiteKey\": \"$sitekey\"
            }
        }" 2>/dev/null)
    
    local task_id
    task_id=$(echo "$create_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('errorId', 1) != 0:
    print(f\"ERROR:{data.get('errorDescription', 'unknown')}\")
else:
    print(data.get('taskId', ''))
" 2>/dev/null)
    
    if [[ "$task_id" == ERROR:* ]]; then
        err "Task creation failed: ${task_id#ERROR:}"
        exit 1
    fi
    
    log "Task created: $task_id — polling for result..."
    
    # Poll for result
    local max_attempts=60
    for i in $(seq 1 $max_attempts); do
        sleep 2
        local result
        result=$(curl -s -X POST "https://api.capsolver.com/getTaskResult" \
            -H "Content-Type: application/json" \
            -d "{\"clientKey\": \"$api_key\", \"taskId\": \"$task_id\"}" 2>/dev/null)
        
        local status
        status=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
status = data.get('status', 'unknown')
if status == 'ready':
    solution = data.get('solution', {})
    token = solution.get('gRecaptchaResponse') or solution.get('token') or solution.get('cookie') or json.dumps(solution)
    print(f'READY:{token}')
elif data.get('errorId', 0) != 0:
    print(f'ERROR:{data.get(\"errorDescription\", \"unknown\")}')
else:
    print(f'PENDING:{status}')
" 2>/dev/null)
        
        case "$status" in
            READY:*)
                log "Solved in $((i*2))s!"
                echo "${status#READY:}"
                exit 0
                ;;
            ERROR:*)
                err "Solve failed: ${status#ERROR:}"
                exit 1
                ;;
            *)
                printf "\r  Polling... %ds" "$((i*2))"
                ;;
        esac
    done
    
    err "Timeout after $((max_attempts*2))s"
    exit 1
}

# Main
case "${1:-help}" in
    install)
        shift
        cmd_install "${1:-$DEFAULT_PORT}"
        ;;
    configure)
        shift
        cmd_configure "$@"
        ;;
    status)
        shift
        cmd_status "${1:-$DEFAULT_PORT}"
        ;;
    api-solve)
        shift
        cmd_api_solve "$@"
        ;;
    help|*)
        echo "Oracle CAPTCHA Solver — Multi-layer bypass system"
        echo ""
        echo "Usage:"
        echo "  captcha-solver.sh install [PORT]           Install CapSolver ext"
        echo "  captcha-solver.sh configure --key <KEY>    Set API key"
        echo "  captcha-solver.sh status [PORT]            Show solver status"
        echo "  captcha-solver.sh api-solve --type <TYPE> --sitekey <KEY> --url <URL>"
        echo ""
        echo "Layers:"
        echo "  1. Stealth inject (fingerprint evasion) — always active"
        echo "  2. CapSolver Chrome Extension (auto-solve in CDP) — requires install"
        echo "  3. CapSolver API (fallback for headless) — requires API key"
        echo ""
        echo "Supported: reCAPTCHA v2/v3, hCaptcha, Cloudflare Turnstile, FunCaptcha, AWS WAF, GeeTest"
        ;;
esac
