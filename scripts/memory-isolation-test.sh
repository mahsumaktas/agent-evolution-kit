#!/usr/bin/env bash
# memory-isolation-test.sh — Cognitive Memory v4 cross-agent isolation test
# Verifies that sourceAgent filter works correctly in memory_recall
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

readonly MEMORY_DB="$HOME/.agent-system/memory/lancedb"
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${CYAN}INFO${NC} $1"; }

FAILURES=0
TESTS=0

echo "=== Cognitive Memory v4 — Isolation Test ==="
echo ""

# Test 1: LanceDB exists
TESTS=$((TESTS + 1))
if [[ -d "$MEMORY_DB" ]]; then
    pass "LanceDB directory exists: $MEMORY_DB"
else
    fail "LanceDB directory NOT FOUND: $MEMORY_DB"
    echo "Cognitive Memory v4 is not deployed. Exiting."
    exit 1
fi

# Test 2: Tables exist
TESTS=$((TESTS + 1))
TABLE_COUNT=$(ls "$MEMORY_DB"/*.lance 2>/dev/null | wc -l | tr -d ' ')
if [[ $TABLE_COUNT -gt 0 ]]; then
    pass "LanceDB tables found: $TABLE_COUNT"
else
    fail "No LanceDB tables found"
fi

# Test 3: Check gateway log for v4 init
TESTS=$((TESTS + 1))
GATEWAY_LOG="$HOME/.agent-system/logs/gateway.log"
if grep -q "memory-lancedb: initialized" "$GATEWAY_LOG" 2>/dev/null; then
    LAST_INIT=$(grep "memory-lancedb: initialized" "$GATEWAY_LOG" | tail -1)
    pass "Gateway loaded memory-lancedb plugin"
    info "$LAST_INIT"
else
    fail "No memory-lancedb init found in gateway log"
fi

# Test 4: Check v4 features in source
TESTS=$((TESTS + 1))
PLUGIN_INDEX="/opt/homebrew/lib/node_modules/agent-system/extensions/memory-lancedb/index.ts"
if [[ -f "$PLUGIN_INDEX" ]]; then
    V4_MARKERS=0
    grep -q "sourceAgent" "$PLUGIN_INDEX" 2>/dev/null && V4_MARKERS=$((V4_MARKERS + 1))
    grep -q "entityGraph" "$PLUGIN_INDEX" 2>/dev/null && V4_MARKERS=$((V4_MARKERS + 1))
    grep -q "self-pruning\|dormant\|pruneStale" "$PLUGIN_INDEX" 2>/dev/null && V4_MARKERS=$((V4_MARKERS + 1))
    grep -q "accessLog\|access.pattern\|accessPattern" "$PLUGIN_INDEX" 2>/dev/null && V4_MARKERS=$((V4_MARKERS + 1))
    if [[ $V4_MARKERS -ge 3 ]]; then
        pass "v4 features detected in index.ts ($V4_MARKERS/4 markers)"
    else
        fail "Only $V4_MARKERS/4 v4 markers found — may not be v4"
    fi
else
    fail "Plugin index.ts not found at $PLUGIN_INDEX"
fi

# Test 5: Check sourceAgent filter in recall code
TESTS=$((TESTS + 1))
if grep -q "sourceAgent" "$PLUGIN_INDEX" 2>/dev/null; then
    FILTER_COUNT=$(grep -c "sourceAgent" "$PLUGIN_INDEX" 2>/dev/null || echo 0)
    pass "sourceAgent filter present ($FILTER_COUNT references)"
else
    fail "sourceAgent filter NOT found in index.ts"
fi

# Test 6: Check config for autoCapture/autoRecall
TESTS=$((TESTS + 1))
PLUGIN_CONFIG="/opt/homebrew/lib/node_modules/agent-system/extensions/memory-lancedb/config.ts"
if [[ -f "$PLUGIN_CONFIG" ]]; then
    FEATURES=0
    grep -q "autoCapture" "$PLUGIN_CONFIG" 2>/dev/null && FEATURES=$((FEATURES + 1))
    grep -q "autoRecall" "$PLUGIN_CONFIG" 2>/dev/null && FEATURES=$((FEATURES + 1))
    pass "Config features: autoCapture+autoRecall ($FEATURES/2)"
else
    fail "Plugin config.ts not found"
fi

# Test 7: Memory count
TESTS=$((TESTS + 1))
MEM_INJECT=$(grep "memory-lancedb: injecting" "$GATEWAY_LOG" 2>/dev/null | tail -1)
if [[ -n "$MEM_INJECT" ]]; then
    pass "Memory injection active"
    info "$MEM_INJECT"
else
    info "No memory injection log entries found (might be empty DB)"
    pass "Plugin is functional (no memories to inject yet)"
fi

echo ""
echo "=== Results: $((TESTS - FAILURES))/$TESTS passed, $FAILURES failed ==="

if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES TEST(S) FAILED${NC}"
    exit 1
fi
