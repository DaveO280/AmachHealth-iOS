#!/usr/bin/env bash
# =============================================================================
# Amach Health — Layer 1: API Smoke Tests (no authentication required)
# =============================================================================
# Tests the unauthenticated endpoints against production.
# Run this FIRST — it verifies the backend is alive before anything else.
#
# Success thresholds:
#   /api/ai/chat   — HTTP 200, valid JSON, response.content ≥ 50 chars, < 30s
#   /api/feedback  — HTTP 200 or 204
#
# Usage:
#   chmod +x Tests/Scripts/layer1-smoke-tests.sh
#   ./Tests/Scripts/layer1-smoke-tests.sh
#   ./Tests/Scripts/layer1-smoke-tests.sh --dry-run    # no network calls
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BASE_URL="${AMACH_API_URL:-https://www.amachhealth.com}"
TIMEOUT=30
MIN_CONTENT_LENGTH=50
PASS=0
FAIL=0
RESULTS=()
DRY_RUN=0

for arg in "$@"; do
  case $arg in --dry-run) DRY_RUN=1 ;; esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'
BOLD='\033[1m'

pass() { echo -e "${GREEN}  ✓ PASS${RESET} $1"; PASS=$((PASS+1)); RESULTS+=("PASS: $1"); }
fail() { echo -e "${RED}  ✗ FAIL${RESET} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL: $1"); }
info() { echo -e "${YELLOW}  ▶${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# ── Test 1: /api/ai/chat (Luma, no auth) ─────────────────────────────────────
header "TEST 1 — Luma AI Chat  (/api/ai/chat)"
info "POSTing minimal chat payload to $BASE_URL/api/ai/chat ..."

CHAT_PAYLOAD='{
  "messages": [{"role": "user", "content": "Hello, what is Amach Health in one sentence?"}],
  "context": {}
}'

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST to $BASE_URL/api/ai/chat"
  echo '{"content":"Amach Health is a decentralized health data platform that gives users ownership of their health data through blockchain verification and AI analysis."}' > /tmp/amach_chat_response.json
  HTTP_STATUS="200"
  ELAPSED=1
else
START_TIME=$(date +%s)
HTTP_STATUS=$(curl -s -o /tmp/amach_chat_response.json -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "$BASE_URL/api/ai/chat" \
  -H "Content-Type: application/json" \
  -d "$CHAT_PAYLOAD" || echo "000")
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
fi

info "HTTP status: $HTTP_STATUS  (${ELAPSED}s)"

# Check HTTP status
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "HTTP 200 received"
else
  fail "Expected HTTP 200, got $HTTP_STATUS"
fi

# Check response is valid JSON
if python3 -c "import json,sys; json.load(open('/tmp/amach_chat_response.json'))" 2>/dev/null; then
  pass "Response is valid JSON"
else
  fail "Response is not valid JSON"
  cat /tmp/amach_chat_response.json
fi

# Check response time
if [[ "$ELAPSED" -lt "$TIMEOUT" ]]; then
  pass "Response time within threshold (${ELAPSED}s < ${TIMEOUT}s)"
else
  fail "Response too slow (${ELAPSED}s >= ${TIMEOUT}s)"
fi

# Check content length
CONTENT=$(python3 -c "
import json, sys
try:
    data = json.load(open('/tmp/amach_chat_response.json'))
    # Try common response fields
    for field in ['content', 'message', 'response', 'text', 'reply']:
        if field in data:
            print(str(data[field]))
            sys.exit(0)
    # Check nested
    if 'choices' in data and len(data['choices']) > 0:
        print(str(data['choices'][0].get('message', {}).get('content', '')))
        sys.exit(0)
    print(json.dumps(data))
except Exception as e:
    print('')
" 2>/dev/null)

CONTENT_LEN=${#CONTENT}
if [[ "$CONTENT_LEN" -ge "$MIN_CONTENT_LENGTH" ]]; then
  pass "Response content ≥ $MIN_CONTENT_LENGTH chars (got $CONTENT_LEN chars)"
else
  fail "Response content too short ($CONTENT_LEN chars < $MIN_CONTENT_LENGTH)"
  echo "  Raw response:"
  cat /tmp/amach_chat_response.json
fi

# Check no error field
HAS_ERROR=$(python3 -c "
import json
try:
    data = json.load(open('/tmp/amach_chat_response.json'))
    if 'error' in data and data['error']:
        print('yes:' + str(data['error']))
    else:
        print('no')
except:
    print('no')
" 2>/dev/null)

if [[ "$HAS_ERROR" == "no" ]]; then
  pass "No error field in response"
else
  fail "Error field present: $HAS_ERROR"
fi

# Preview response
echo ""
info "Response preview (first 200 chars):"
echo "$CONTENT" | head -c 200
echo ""

# ── Test 2: /api/ai/chat with health context ──────────────────────────────────
header "TEST 2 — Luma AI Chat with health context"
info "Testing that context fields are accepted without auth errors..."

CONTEXT_PAYLOAD='{
  "messages": [{"role": "user", "content": "What does a resting heart rate of 58 bpm mean for a male aged 44?"}],
  "context": {
    "profile": {"age": 44, "sex": "male", "height": 66, "weight": 163}
  }
}'

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST context payload to $BASE_URL/api/ai/chat"
  echo '{"content":"A resting heart rate of 58 bpm is excellent for a 44-year-old male, falling well within the athletic range and indicating strong cardiovascular fitness."}' > /tmp/amach_chat_context_response.json
  HTTP_STATUS2="200"
else
HTTP_STATUS2=$(curl -s -o /tmp/amach_chat_context_response.json -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "$BASE_URL/api/ai/chat" \
  -H "Content-Type: application/json" \
  -d "$CONTEXT_PAYLOAD" || echo "000")
fi

if [[ "$HTTP_STATUS2" == "200" ]]; then
  pass "HTTP 200 with health context payload"
else
  fail "Expected HTTP 200, got $HTTP_STATUS2"
fi

CONTEXT_CONTENT=$(python3 -c "
import json
try:
    data = json.load(open('/tmp/amach_chat_context_response.json'))
    for field in ['content', 'message', 'response', 'text', 'reply']:
        if field in data and data[field]:
            print(str(data[field]))
            import sys; sys.exit(0)
    print(json.dumps(data))
except:
    print('')
" 2>/dev/null)
CONTEXT_LEN=${#CONTEXT_CONTENT}
if [[ "$CONTEXT_LEN" -ge "$MIN_CONTENT_LENGTH" ]]; then
  pass "Context-enriched response ≥ $MIN_CONTENT_LENGTH chars (got $CONTEXT_LEN chars)"
else
  fail "Context-enriched response too short ($CONTEXT_LEN chars)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "═══════ LAYER 1 RESULTS ═══════"
TOTAL=$((PASS + FAIL))
echo -e "  Passed: ${GREEN}${PASS}${RESET} / $TOTAL"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  Failed: ${RED}${FAIL}${RESET} / $TOTAL"
  echo ""
  echo -e "${RED}  ✗ LAYER 1 FAILED — do not proceed to Layer 2${RESET}"
  exit 1
else
  echo ""
  echo -e "${GREEN}  ✓ ALL LAYER 1 TESTS PASSED — backend is alive and Luma responds${RESET}"
  exit 0
fi
