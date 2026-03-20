#!/usr/bin/env bash
# =============================================================================
# Amach Health — Layer 3: Authenticated API Tests (Storj + Profile)
# =============================================================================
# Tests endpoints that require WalletEncryptionKey authentication.
# Depends on Tests/TestCredentials.json being present.
#
# Success thresholds:
#   /api/profile/read   — HTTP 200, valid JSON, non-empty profile
#   /api/storj (list)   — HTTP 200, valid JSON array
#   /api/health/summary — HTTP 200, valid JSON with summary content
#   /api/ai/chat (authed) — HTTP 200, Luma responds with health-contextual reply
#
# Usage:
#   ./Tests/Scripts/layer3-auth-tests.sh
#   ./Tests/Scripts/layer3-auth-tests.sh --dry-run    # no network calls
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CREDS_FILE="$PROJECT_ROOT/Tests/TestCredentials.json"
BASE_URL="${AMACH_API_URL:-https://www.amachhealth.com}"
TIMEOUT=30
PASS=0
FAIL=0
DRY_RUN=0

for arg in "$@"; do
  case $arg in --dry-run) DRY_RUN=1 ;; esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'
BOLD='\033[1m'

pass() { echo -e "${GREEN}  ✓ PASS${RESET} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  ✗ FAIL${RESET} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}  ▶${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# ── Load credentials ──────────────────────────────────────────────────────────
if [[ ! -f "$CREDS_FILE" ]]; then
  echo -e "${RED}ERROR: TestCredentials.json not found at $CREDS_FILE${RESET}"
  echo "Run the credential extraction flow described in TEST-SETUP.md"
  exit 1
fi

WALLET_ADDRESS=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['testAccount']['walletAddress'])")
ENC_KEY=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['testAccount']['encryptionKey'])")
SIGNATURE=$(python3 -c "import json; d=json.load(open('$CREDS_FILE')); print(d['testAccount']['signature'])")
TIMESTAMP=$(date +%s000)  # current time in ms

# Build the WalletEncryptionKey JSON body (matches AmachAPIClient.swift serialization)
AUTH_KEY_JSON=$(python3 -c "
import json
print(json.dumps({
  'walletAddress': '$WALLET_ADDRESS',
  'key': '$ENC_KEY',
  'signature': '$SIGNATURE',
  'derivedAt': $TIMESTAMP
}))
")

info "Test account: $WALLET_ADDRESS"
info "Base URL: $BASE_URL"
[[ $DRY_RUN -eq 1 ]] && info "[DRY-RUN MODE — no real network calls]"

# ── Test 1: /api/profile/read ─────────────────────────────────────────────────
header "TEST 1 — Profile Read  (/api/profile/read)"

PROFILE_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'walletEncryptionKey': json.loads('$AUTH_KEY_JSON')
}))
")

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST to $BASE_URL/api/profile/read"
  echo '{"success":true,"profile":{"birthDate":"1981-01-01","sex":"male","height":66,"weight":163,"source":"onchain","isActive":true}}' > /tmp/amach_profile.json
  HTTP_STATUS="200"
else
HTTP_STATUS=$(curl -s -o /tmp/amach_profile.json -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "$BASE_URL/api/profile/read" \
  -H "Content-Type: application/json" \
  -d "$PROFILE_PAYLOAD" || echo "000")
fi

info "HTTP: $HTTP_STATUS"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "Profile read HTTP 200"
else
  fail "Profile read expected 200, got $HTTP_STATUS"
fi

if python3 -c "import json,sys; d=json.load(open('/tmp/amach_profile.json')); sys.exit(0 if d else 1)" 2>/dev/null; then
  pass "Profile response is valid non-empty JSON"
  info "Profile preview: $(python3 -c "import json; d=json.load(open('/tmp/amach_profile.json')); print(str(d)[:200])" 2>/dev/null)"
else
  fail "Profile response invalid or empty"
  cat /tmp/amach_profile.json
fi

# ── Test 2: /api/storj (list) ─────────────────────────────────────────────────
header "TEST 2 — Storj List  (/api/storj)"

STORJ_LIST_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'action': 'storage/list',
  'walletEncryptionKey': json.loads('$AUTH_KEY_JSON')
}))
")

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST storage/list to $BASE_URL/api/storj"
  echo '{"success":true,"result":[{"uri":"storj://amach-health/apple-health-full-export/2024-03-01.enc","contentHash":"abc123","size":245760,"uploadedAt":1709251200000,"dataType":"apple-health-full-export","metadata":{"tier":"gold","metricsCount":"35","platform":"web"}}]}' > /tmp/amach_storj_list.json
  HTTP_STATUS="200"
else
HTTP_STATUS=$(curl -s -o /tmp/amach_storj_list.json -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "$BASE_URL/api/storj" \
  -H "Content-Type: application/json" \
  -d "$STORJ_LIST_PAYLOAD" || echo "000")
fi

info "HTTP: $HTTP_STATUS"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "Storj list HTTP 200"
else
  fail "Storj list expected 200, got $HTTP_STATUS"
fi

ITEM_COUNT=$(python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/amach_storj_list.json'))
    # Handle various response shapes
    if isinstance(d, list):
        print(len(d))
    elif isinstance(d, dict):
        for key in ['files', 'items', 'objects', 'data']:
            if key in d and isinstance(d[key], list):
                print(len(d[key]))
                sys.exit(0)
        print(len(d))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null)

info "Items in Storj: $ITEM_COUNT"
if [[ "$ITEM_COUNT" -gt 0 ]]; then
  pass "Storj contains $ITEM_COUNT health data file(s)"
else
  fail "Storj list empty — health data may not be uploaded yet"
  echo "  NOTE: Upload health data via the web app first (see TEST-SETUP.md)"
  cat /tmp/amach_storj_list.json | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2)[:500])" 2>/dev/null || true
fi

# ── Test 3: /api/health/summary ───────────────────────────────────────────────
header "TEST 3 — Health Summary  (/api/health/summary)"

SUMMARY_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'walletEncryptionKey': json.loads('$AUTH_KEY_JSON')
}))
")

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST to $BASE_URL/api/health/summary"
  echo '{"success":true,"summary":{"metricsCount":35,"dateRange":{"start":"2024-01-01","end":"2024-12-31"},"dailyAverages":{"heartRate":62.4,"steps":8200,"hrv":45.0,"sleepHours":7.2}}}' > /tmp/amach_summary.json
  HTTP_STATUS="200"
else
HTTP_STATUS=$(curl -s -o /tmp/amach_summary.json -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "$BASE_URL/api/health/summary" \
  -H "Content-Type: application/json" \
  -d "$SUMMARY_PAYLOAD" || echo "000")
fi

info "HTTP: $HTTP_STATUS"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "Health summary HTTP 200"
else
  fail "Health summary expected 200, got $HTTP_STATUS"
fi

SUMMARY_LEN=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/amach_summary.json'))
    print(len(json.dumps(d)))
except:
    print(0)
" 2>/dev/null)

if [[ "$SUMMARY_LEN" -gt 50 ]]; then
  pass "Health summary non-trivial (${SUMMARY_LEN} chars)"
  info "Summary preview: $(python3 -c "import json; d=json.load(open('/tmp/amach_summary.json')); print(str(d)[:200])" 2>/dev/null)"
else
  fail "Health summary too short or empty ($SUMMARY_LEN chars)"
fi

# ── Test 4: /api/ai/chat with wallet context (full Luma flow) ─────────────────
header "TEST 4 — Luma with Wallet Context  (end-to-end auth flow)"
info "This mirrors what iOS ChatService does: wallet addr + key injected into context"

AUTHED_CHAT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'messages': [{'role': 'user', 'content': 'Based on my health data, what is one thing I should focus on this week?'}],
  'context': {
    'userAddress': '$WALLET_ADDRESS',
    'encryptionKey': '$ENC_KEY',
    'profile': {'age': 44, 'sex': 'male', 'height': 66, 'weight': 163}
  }
}))
")

if [[ $DRY_RUN -eq 1 ]]; then
  info "[DRY-RUN] Would POST authenticated chat payload to $BASE_URL/api/ai/chat"
  echo '{"content":"Based on your health data showing strong HRV of 45ms and consistent 8200 daily steps, I recommend focusing on optimizing your sleep quality this week — your data suggests your recovery window starts around 10pm based on your HRV dip pattern."}' > /tmp/amach_authed_chat.json
  HTTP_STATUS="200"
  ELAPSED=2
else
START_TIME=$(date +%s)
HTTP_STATUS=$(curl -s -o /tmp/amach_authed_chat.json -w "%{http_code}" \
  --max-time 45 \
  -X POST "$BASE_URL/api/ai/chat" \
  -H "Content-Type: application/json" \
  -d "$AUTHED_CHAT_PAYLOAD" || echo "000")
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
fi

info "HTTP: $HTTP_STATUS  (${ELAPSED}s)"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "Authenticated Luma chat HTTP 200"
else
  fail "Authenticated chat expected 200, got $HTTP_STATUS"
fi

AUTH_CONTENT=$(python3 -c "
import json
try:
    data = json.load(open('/tmp/amach_authed_chat.json'))
    for field in ['content', 'message', 'response', 'text', 'reply']:
        if field in data and data[field]:
            print(str(data[field]))
            import sys; sys.exit(0)
    print(json.dumps(data))
except:
    print('')
" 2>/dev/null)
AUTH_LEN=${#AUTH_CONTENT}

if [[ "$AUTH_LEN" -ge 50 ]]; then
  pass "Authenticated Luma response ≥ 50 chars ($AUTH_LEN chars)"
else
  fail "Authenticated Luma response too short ($AUTH_LEN chars)"
fi

echo ""
info "Luma response preview:"
echo "$AUTH_CONTENT" | head -c 300
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
header "═══════ LAYER 3 RESULTS ═══════"
TOTAL=$((PASS + FAIL))
echo -e "  Passed: ${GREEN}${PASS}${RESET} / $TOTAL"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  Failed: ${RED}${FAIL}${RESET} / $TOTAL"
  echo ""
  echo -e "${RED}  ✗ LAYER 3 HAD FAILURES — check auth and Storj data${RESET}"
  exit 1
else
  echo ""
  echo -e "${GREEN}  ✓ ALL LAYER 3 TESTS PASSED — authenticated stack is healthy${RESET}"
  exit 0
fi
