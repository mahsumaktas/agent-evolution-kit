#!/bin/bash
# sandbox.sh — 3-Layer Plugin Validation for Oracle
# Usage: sandbox.sh <source-dir> [OPTIONS]
#
# 3-Layer Pipeline:
#   L1: jiti load + mock register (runtime validation, ~200ms)
#   L2: tsc --noEmit (type checking, ~2.5s)
#   L3: canary deploy (full integration, ~30s) — via canary-deploy.sh
#
# Supports: AgentSystem extensions, generic TypeScript, Docker isolation
set -euo pipefail

# --- Constants ---
readonly LOG_FILE="/tmp/sandbox.log"
readonly SANDBOX_PROFILE="/tmp/sandbox.sb"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly VALIDATE_SCRIPT="${SCRIPT_DIR}/validate-plugin.mjs"
readonly CANARY_SCRIPT="${SCRIPT_DIR}/canary-deploy.sh"
readonly OPENCLAW_ROOT="/opt/homebrew/lib/node_modules/agent-system"

# --- Defaults ---
USE_DOCKER=false
SKIP_L2=false
SKIP_L3=true   # L3 (canary) off by default, use --canary to enable
TEST_CMD=""
SOURCE_DIR=""
SANDBOX_DIR=""
VERBOSE=false
L1_ONLY=false

# --- Logging ---
log() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
    echo "$line" | tee -a "$LOG_FILE"
}

log_separator() {
    echo "========================================" | tee -a "$LOG_FILE"
}

# --- Cleanup ---
cleanup() {
    local exit_code=$?
    if [[ -n "${SANDBOX_DIR:-}" && -d "${SANDBOX_DIR:-}" ]]; then
        log "INFO" "Cleaning up sandbox: ${SANDBOX_DIR}"
        rm -rf "$SANDBOX_DIR"
    fi
    if [[ -f "$SANDBOX_PROFILE" ]]; then
        rm -f "$SANDBOX_PROFILE"
    fi
    return $exit_code
}
trap cleanup EXIT

# --- Usage ---
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <source-dir> [OPTIONS]

3-Layer Plugin Validation Pipeline:
  L1: jiti load + mock register  (catches syntax, import, runtime errors)
  L2: tsc --noEmit               (catches type errors)
  L3: canary deploy              (full integration test)

Options:
  --l1-only         Run only Layer 1 (fastest, ~200ms)
  --skip-l2         Skip Layer 2 type checking
  --canary          Enable Layer 3 canary deploy
  --docker          Use Docker for full isolation (requires docker)
  --test-cmd "CMD"  Custom test command to run after L2
  --verbose         Show detailed output
  -h, --help        Show this help

Examples:
  ${SCRIPT_NAME} ./my-plugin                              # L1 + L2
  ${SCRIPT_NAME} ./my-plugin --l1-only                    # L1 only (fast)
  ${SCRIPT_NAME} ./my-plugin --canary                     # L1 + L2 + L3
  ${SCRIPT_NAME} /path/to/extensions/memory-lancedb/      # Auto-detect AgentSystem
  ${SCRIPT_NAME} ./my-plugin --docker                     # Docker isolation
EOF
    exit 0
}

# --- Arg parsing ---
parse_args() {
    if [[ $# -eq 0 ]]; then
        log "ERROR" "No source directory provided"
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --docker)
                USE_DOCKER=true
                shift
                ;;
            --l1-only)
                L1_ONLY=true
                shift
                ;;
            --skip-l2)
                SKIP_L2=true
                shift
                ;;
            --canary)
                SKIP_L3=false
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --test-cmd)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR" "--test-cmd requires an argument"
                    exit 1
                fi
                TEST_CMD="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            -*)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$SOURCE_DIR" ]]; then
                    SOURCE_DIR="$1"
                else
                    log "ERROR" "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$SOURCE_DIR" ]]; then
        log "ERROR" "Source directory is required"
        exit 1
    fi

    if [[ ! -d "$SOURCE_DIR" ]]; then
        log "ERROR" "Source directory does not exist: ${SOURCE_DIR}"
        exit 1
    fi

    # Resolve to absolute path
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
}

# --- Detect if source is an AgentSystem extension ---
is_agent-system_extension() {
    local dir="$1"
    if [[ "$dir" == *"/agent-system/extensions/"* ]]; then
        return 0
    fi
    if [[ -f "${dir}/index.ts" ]] && grep -q "agent-system/plugin-sdk" "${dir}/index.ts" 2>/dev/null; then
        return 0
    fi
    if [[ -f "${dir}/package.json" ]] && grep -q "agent-system" "${dir}/package.json" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Prepare sandbox directory ---
prepare_sandbox() {
    SANDBOX_DIR="$(mktemp -d /tmp/sandbox-${TIMESTAMP}-XXXXXX)"
    log "INFO" "Created sandbox directory: ${SANDBOX_DIR}"

    log "INFO" "Copying source from ${SOURCE_DIR} to sandbox..."
    cp -R "${SOURCE_DIR}/." "${SANDBOX_DIR}/"

    # For AgentSystem extensions, symlink node_modules from installation
    if is_agent-system_extension "$SOURCE_DIR"; then
        log "INFO" "Detected AgentSystem extension, linking dependencies..."

        local agent-system_root
        agent-system_root="$(echo "$SOURCE_DIR" | sed 's|/extensions/.*|/|')"
        # Fallback to global installation
        if [[ ! -d "${agent-system_root}/node_modules" ]]; then
            agent-system_root="$OPENCLAW_ROOT"
        fi

        if [[ -d "${agent-system_root}/node_modules" && ! -d "${SANDBOX_DIR}/node_modules" ]]; then
            ln -sf "${agent-system_root}/node_modules" "${SANDBOX_DIR}/node_modules"
            log "INFO" "Symlinked node_modules from ${agent-system_root}"
        fi
    fi

    # If no package.json, create a minimal one
    if [[ ! -f "${SANDBOX_DIR}/package.json" ]]; then
        cat > "${SANDBOX_DIR}/package.json" <<PKGEOF
{
  "name": "sandbox-test",
  "version": "0.0.0",
  "private": true
}
PKGEOF
    fi

    log "INFO" "Sandbox prepared ($(du -sh "$SANDBOX_DIR" | cut -f1) total)"
}

# ============================================================
# LAYER 1: jiti load + mock register
# ============================================================
run_layer1() {
    local dir="$1"

    log "INFO" "=== LAYER 1: jiti load + mock register ==="

    if [[ ! -f "$VALIDATE_SCRIPT" ]]; then
        log "ERROR" "L1: validate-plugin.mjs not found at ${VALIDATE_SCRIPT}"
        return 1
    fi

    local l1_output
    local l1_exit=0
    local verbose_flag=""
    if [[ "$VERBOSE" == true ]]; then
        verbose_flag="--verbose"
    fi

    l1_output="$(node "$VALIDATE_SCRIPT" "$dir" $verbose_flag 2>&1)" || l1_exit=$?

    echo "$l1_output" | tee -a "$LOG_FILE"

    if [[ $l1_exit -ne 0 ]]; then
        log "ERROR" "L1 FAILED: Plugin could not be loaded/registered"
        return 1
    fi

    log "INFO" "L1 PASSED"
    return 0
}

# ============================================================
# LAYER 2: tsc type checking
# ============================================================
run_layer2() {
    local dir="$1"

    log "INFO" "=== LAYER 2: TypeScript type checking ==="

    # Check for TypeScript files
    local ts_files
    ts_files="$(find "$dir" -maxdepth 3 -name '*.ts' -not -path '*/node_modules/*' 2>/dev/null | head -1)"

    if [[ -z "$ts_files" ]]; then
        log "INFO" "L2: No TypeScript files found, skipping"
        return 0
    fi

    # Create tsconfig if missing
    if [[ ! -f "${dir}/tsconfig.json" ]]; then
        log "INFO" "L2: Creating tsconfig.json for type-checking"
        cat > "${dir}/tsconfig.json" <<TSEOF
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "strict": false,
    "noImplicitAny": false,
    "noEmit": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "resolveJsonModule": true
  },
  "include": ["*.ts", "**/*.ts"],
  "exclude": ["node_modules", "*.test.ts"]
}
TSEOF
    fi

    local tsc_output
    local tsc_exit=0

    tsc_output="$(cd "$dir" && npx tsc --noEmit 2>&1)" || tsc_exit=$?

    if [[ $tsc_exit -ne 0 ]]; then
        # Count errors
        local error_count
        error_count="$(echo "$tsc_output" | grep -c "^.*error TS" 2>/dev/null || echo 0)"

        log "WARN" "L2: tsc reported ${error_count} error(s) (exit ${tsc_exit})"

        if [[ "$VERBOSE" == true ]]; then
            echo "$tsc_output" | tee -a "$LOG_FILE"
        else
            # Show first 10 errors
            echo "$tsc_output" | grep "error TS" | head -10 | tee -a "$LOG_FILE"
            if [[ $error_count -gt 10 ]]; then
                echo "  ... and $((error_count - 10)) more errors (use --verbose for full output)" | tee -a "$LOG_FILE"
            fi
        fi

        # For AgentSystem extensions, L2 is advisory (jiti doesn't type-check at runtime)
        if is_agent-system_extension "$dir" || is_agent-system_extension "$SOURCE_DIR"; then
            log "WARN" "L2: AgentSystem extension — tsc errors are ADVISORY (jiti strips types at runtime)"
            log "WARN" "L2: Plugin will still work if L1 passed. Errors above indicate code quality issues."
            return 0  # Don't fail for AgentSystem extensions
        fi

        return 1
    fi

    log "INFO" "L2 PASSED: Zero type errors"
    return 0
}

# ============================================================
# LAYER 3: canary deploy
# ============================================================
run_layer3() {
    local dir="$1"

    log "INFO" "=== LAYER 3: Canary deploy ==="

    if [[ ! -f "$CANARY_SCRIPT" ]]; then
        log "ERROR" "L3: canary-deploy.sh not found at ${CANARY_SCRIPT}"
        return 1
    fi

    log "INFO" "L3: Launching canary deploy from sandbox..."
    local canary_exit=0

    bash "$CANARY_SCRIPT" "$dir" 2>&1 | tee -a "$LOG_FILE" || canary_exit=$?

    if [[ $canary_exit -ne 0 ]]; then
        log "ERROR" "L3 FAILED: Canary deploy failed"
        return 1
    fi

    log "INFO" "L3 PASSED: Canary deploy successful"
    return 0
}

# ============================================================
# LAYER 2 (Docker): tsc in container
# ============================================================
run_layer2_docker() {
    local dir="$1"

    log "INFO" "=== LAYER 2 (Docker): Type checking in container ==="

    if ! command -v docker &>/dev/null; then
        log "ERROR" "Docker not found"
        return 1
    fi

    if ! docker info &>/dev/null; then
        log "ERROR" "Docker daemon not running"
        return 1
    fi

    local dockerfile="${dir}/Dockerfile.sandbox"
    cat > "$dockerfile" <<'DEOF'
FROM node:22-alpine
WORKDIR /app
COPY . .
RUN npm install --ignore-scripts 2>/dev/null || true
RUN npx tsc --noEmit 2>&1
DEOF

    local docker_exit=0
    docker build -t sandbox-test:latest -f "$dockerfile" "$dir" 2>&1 | tee -a "$LOG_FILE" || docker_exit=$?
    rm -f "$dockerfile"

    if [[ $docker_exit -ne 0 ]]; then
        log "ERROR" "L2 Docker FAILED"
        docker rmi sandbox-test:latest 2>/dev/null || true
        return 1
    fi

    # Run custom test if provided
    if [[ -n "$TEST_CMD" ]]; then
        log "INFO" "Running custom test in Docker: ${TEST_CMD}"
        docker run --rm --network none sandbox-test:latest sh -c "$TEST_CMD" 2>&1 | tee -a "$LOG_FILE" || docker_exit=$?
    fi

    docker rmi sandbox-test:latest 2>/dev/null || true

    if [[ $docker_exit -ne 0 ]]; then
        log "ERROR" "Docker test FAILED"
        return 1
    fi

    log "INFO" "L2 Docker PASSED"
    return 0
}

# --- Run custom test command ---
run_test_cmd() {
    local dir="$1"
    local cmd="$2"

    if [[ -z "$cmd" ]]; then
        return 0
    fi

    log "INFO" "Running custom test: ${cmd}"

    local test_output
    local test_exit=0

    test_output="$(cd "$dir" && eval "$cmd" 2>&1)" || test_exit=$?

    if [[ $test_exit -ne 0 ]]; then
        log "ERROR" "Custom test FAILED (exit ${test_exit})"
        echo "$test_output" | tee -a "$LOG_FILE"
        return 1
    fi

    log "INFO" "Custom test PASSED"
    if [[ -n "$test_output" ]]; then
        echo "$test_output" | tail -5 | tee -a "$LOG_FILE"
    fi
    return 0
}

# ============================================================
# MAIN
# ============================================================
main() {
    log_separator
    log "INFO" "${SCRIPT_NAME} started at ${TIMESTAMP}"
    log "INFO" "Arguments: $*"

    parse_args "$@"

    log "INFO" "Source directory: ${SOURCE_DIR}"
    log "INFO" "Pipeline: L1$(if [[ "$L1_ONLY" != true && "$SKIP_L2" != true ]]; then echo " + L2"; fi)$(if [[ "$SKIP_L3" != true ]]; then echo " + L3"; fi)"

    local is_extension=false
    if is_agent-system_extension "$SOURCE_DIR"; then
        log "INFO" "Source detected as AgentSystem extension"
        is_extension=true
    fi

    # Prepare sandbox copy
    prepare_sandbox

    local result=0
    local l1_pass=false
    local l2_pass=false
    local l3_pass=false

    # === LAYER 1: jiti load + mock register ===
    if run_layer1 "$SANDBOX_DIR"; then
        l1_pass=true
    else
        result=1
    fi

    # === LAYER 2: tsc type checking ===
    if [[ "$L1_ONLY" != true && "$SKIP_L2" != true && $result -eq 0 ]]; then
        if [[ "$USE_DOCKER" == true ]]; then
            if run_layer2_docker "$SANDBOX_DIR"; then
                l2_pass=true
            else
                result=1
            fi
        else
            if run_layer2 "$SANDBOX_DIR"; then
                l2_pass=true
            else
                result=1
            fi
        fi
    elif [[ "$L1_ONLY" == true || "$SKIP_L2" == true ]]; then
        l2_pass=true  # Skipped = pass
    fi

    # === Custom test command ===
    if [[ $result -eq 0 && -n "$TEST_CMD" ]]; then
        run_test_cmd "$SANDBOX_DIR" "$TEST_CMD" || result=$?
    fi

    # === LAYER 3: canary deploy ===
    if [[ "$SKIP_L3" != true && $result -eq 0 ]]; then
        if run_layer3 "$SOURCE_DIR"; then
            l3_pass=true
        else
            result=1
        fi
    elif [[ "$SKIP_L3" == true ]]; then
        l3_pass=true  # Skipped = pass
    fi

    # === Summary ===
    log_separator
    echo ""
    echo "  SANDBOX PIPELINE RESULTS"
    echo "  ========================"
    echo "  L1 (jiti load):   $(if [[ "$l1_pass" == true ]]; then echo "PASS"; else echo "FAIL"; fi)"
    if [[ "$L1_ONLY" != true && "$SKIP_L2" != true ]]; then
        echo "  L2 (tsc check):  $(if [[ "$l2_pass" == true ]]; then echo "PASS"; else echo "FAIL"; fi)"
    else
        echo "  L2 (tsc check):  SKIPPED"
    fi
    if [[ "$SKIP_L3" != true ]]; then
        echo "  L3 (canary):     $(if [[ "$l3_pass" == true ]]; then echo "PASS"; else echo "FAIL"; fi)"
    else
        echo "  L3 (canary):     SKIPPED"
    fi
    echo "  ========================"

    if [[ $result -eq 0 ]]; then
        echo "  FINAL VERDICT: PASS"
        log "INFO" "RESULT: ALL CHECKS PASSED"
    else
        echo "  FINAL VERDICT: FAIL"
        echo "  See ${LOG_FILE} for details"
        log "ERROR" "RESULT: CHECKS FAILED"
    fi
    echo ""

    exit $result
}

main "$@"
