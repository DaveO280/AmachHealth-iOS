#!/usr/bin/env bash
# =============================================================================
# Amach Health — Luma answer evaluation (optional, costs Venice credit)
# =============================================================================
# 1. Runs LumaTemporalContextTests/test_write_luma_eval_requests on the booted
#    simulator. It fills a vault with a synthetic profile and writes, for each
#    question, the exact request the app sends to /api/ai/chat.
# 2. Sends them with luma-eval.py, scores the answers against
#    luma-eval-checks.json and writes report.md + results.json.
#
# Usage:
#   ./Tests/Scripts/luma-eval.sh                         # prod, 1 run
#   ./Tests/Scripts/luma-eval.sh --target preview        # Vercel preview of Amach-Website's branch
#   ./Tests/Scripts/luma-eval.sh --target preview --branch my-branch --repeat 3
#   ./Tests/Scripts/luma-eval.sh --url https://… --only vitd_2024,gut_age
#   ./Tests/Scripts/luma-eval.sh --skip-build --requests <folder>   # reuse requests
#
# Every option except --skip-build / --requests is passed to luma-eval.py.
# Exit code 1 when any answer fails a regex check.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$PROJECT_ROOT/Tests/Logs/luma-eval/$STAMP"
REQUESTS_DIR=""
SKIP_BUILD=0
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --requests) REQUESTS_DIR="$2"; shift 2 ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$REQUESTS_DIR" ]]; then
  REQUESTS_DIR="$OUT_DIR/requests"
fi
mkdir -p "$REQUESTS_DIR"

if [[ $SKIP_BUILD -eq 0 ]]; then
  UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)
  if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl list devices available | grep -E '^\s+iPhone' | tail -1 | grep -oE '[0-9A-F-]{36}' || true)
    if [[ -z "$UDID" ]]; then
      echo "No booted or available iPhone simulator." >&2
      exit 2
    fi
    echo "▶ Booting simulator $UDID"
    xcrun simctl bootstatus "$UDID" -b > /dev/null
  fi
  echo "▶ Writing eval requests on simulator $UDID → $REQUESTS_DIR"
  LOG="$OUT_DIR/xcodebuild.log"
  # TEST_RUNNER_ vars reach the test process with the prefix stripped.
  if ! TEST_RUNNER_LUMA_EVAL_DIR="$REQUESTS_DIR" xcodebuild test \
      -project "$PROJECT_ROOT/AmachHealth.xcodeproj" \
      -scheme "Amach Health" \
      -destination "id=$UDID" \
      -only-testing:"Amach HealthTests/LumaTemporalContextTests/test_write_luma_eval_requests" \
      > "$LOG" 2>&1; then
    echo "xcodebuild failed; see $LOG" >&2
    tail -30 "$LOG" >&2
    exit 2
  fi
  if grep -q "skipped" "$LOG" && ! ls "$REQUESTS_DIR"/*.json > /dev/null 2>&1; then
    echo "Test was skipped (LUMA_EVAL_DIR not passed through); see $LOG" >&2
    exit 2
  fi
fi

COUNT=$(ls "$REQUESTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
if [[ "$COUNT" -eq 0 ]]; then
  echo "No request files in $REQUESTS_DIR" >&2
  exit 2
fi
echo "▶ $COUNT requests ready"

python3 -I "$SCRIPT_DIR/luma-eval.py" "$REQUESTS_DIR" --out "$OUT_DIR" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
