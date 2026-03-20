#!/usr/bin/env bash
# =============================================================================
# Amach Health — Master Test Runner
# =============================================================================
# Orchestrates all four test layers. Designed for pre-coding-session validation.
# Run this before starting any coding session to confirm continuity.
#
# Layers:
#   Layer 1 — API smoke tests (no auth, ~30s)
#   Layer 2 — XCTest unit + integration tests with mock client (via Layer 4)
#   Layer 3 — Authenticated Storj/profile tests (needs TestCredentials.json)
#   Layer 4 — Simulator build + XCTest + screenshots (~5-10min)
#
# PASS THRESHOLD: Layers 1 and 3 must pass before you start coding.
# Layer 4 gives highest confidence but takes longer.
#
# Usage:
#   ./amach-test-runner.sh                        # Full run (all layers)
#   ./amach-test-runner.sh --quick                # Layer 1 + 3 only (~60s)
#   ./amach-test-runner.sh --quick --iterations 3 # Repeat 3 times for stability
#   ./amach-test-runner.sh --dry-run              # No network/Xcode required
#   ./amach-test-runner.sh --layer 1              # Single layer
#   ./amach-test-runner.sh --layer 4 --skip-screenshots
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/Tests/Scripts"
LOG_DIR="$SCRIPT_DIR/Tests/Logs"

# ── Args ──────────────────────────────────────────────────────────────────────
QUICK=0
SINGLE_LAYER=""
ITERATIONS=1
DRY_RUN=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)            QUICK=1; shift ;;
    --layer)            SINGLE_LAYER="$2"; shift 2 ;;
    --iterations|-n)    ITERATIONS="$2"; shift 2 ;;
    --skip-screenshots) EXTRA_ARGS+=("--skip-screenshots"); shift ;;
    --dry-run)          DRY_RUN=1; EXTRA_ARGS+=("--dry-run"); shift ;;
    *) shift ;;
  esac
done

mkdir -p "$LOG_DIR"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'
BOLD='\033[1m'

layer_header() {
  echo ""
  echo -e "${CYAN}${BOLD}════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $1${RESET}"
  echo -e "${CYAN}${BOLD}════════════════════════════════════════${RESET}"
}

# ── Per-run state (reset each iteration) ─────────────────────────────────────
LAYER_RESULTS=()
ALL_PASSED=1

run_layer() {
  local num="$1"
  local label="$2"
  local script="$3"
  shift 3

  local start_ts end_ts elapsed
  start_ts=$(date +%s)
  layer_header "LAYER $num — $label"

  local log_file="$LOG_DIR/layer${num}_iter${CURRENT_ITER}_$(date +%Y%m%d_%H%M%S).log"

  if bash "$script" "$@" 2>&1 | tee "$log_file"; then
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    echo -e "\n${GREEN}  ✓ LAYER $num PASSED${RESET} (${elapsed}s)"
    LAYER_RESULTS+=("PASS:$num:${elapsed}s: $label")
  else
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    echo -e "\n${RED}  ✗ LAYER $num FAILED${RESET} (${elapsed}s)"
    LAYER_RESULTS+=("FAIL:$num:${elapsed}s: $label")
    ALL_PASSED=0
    if [[ "$num" -le 1 ]]; then
      echo -e "${RED}  Layer 1 failure is a blocker — stopping run.${RESET}"
    fi
  fi
}

print_iteration_summary() {
  local iter="$1"
  echo ""
  echo -e "${BOLD}──── Iteration $iter Results ────${RESET}"
  for result in "${LAYER_RESULTS[@]}"; do
    local status="${result%%:*}"
    local rest="${result#*:}"
    local layer="${rest%%:*}"
    rest="${rest#*:}"
    local timing="${rest%%:*}"
    local label="${rest#*: }"
    if [[ "$status" == "PASS" ]]; then
      echo -e "  ${GREEN}✓${RESET} Layer $layer — $label  ${YELLOW}(${timing})${RESET}"
    else
      echo -e "  ${RED}✗${RESET} Layer $layer — $label  ${YELLOW}(${timing})${RESET}"
    fi
  done
}

# ── Multi-iteration tracking ──────────────────────────────────────────────────
ITER_PASS=0
ITER_FAIL=0
declare -A LAYER_PASS_COUNTS
declare -A LAYER_FAIL_COUNTS
declare -A LAYER_TIMINGS

chmod +x "$SCRIPTS_DIR/layer1-smoke-tests.sh" 2>/dev/null || true
chmod +x "$SCRIPTS_DIR/layer3-auth-tests.sh" 2>/dev/null || true
chmod +x "$SCRIPTS_DIR/layer4-simulator-tests.sh" 2>/dev/null || true

# ── Main iteration loop ───────────────────────────────────────────────────────
for (( CURRENT_ITER=1; CURRENT_ITER<=ITERATIONS; CURRENT_ITER++ )); do

  LAYER_RESULTS=()
  ALL_PASSED=1

  echo ""
  echo -e "${BOLD}  Amach Health — Pre-Session Continuity Check${RESET}"
  echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
  if [[ $ITERATIONS -gt 1 ]]; then
    echo -e "  ${CYAN}Iteration $CURRENT_ITER / $ITERATIONS${RESET}"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "  Mode: ${YELLOW}DRY-RUN (no network/Xcode calls)${RESET}"
  elif [[ $QUICK -eq 1 ]]; then
    echo -e "  Mode: ${YELLOW}Quick (Layer 1 + 3 only)${RESET}"
  elif [[ -n "$SINGLE_LAYER" ]]; then
    echo -e "  Mode: ${YELLOW}Single layer $SINGLE_LAYER${RESET}"
  else
    echo -e "  Mode: ${YELLOW}Full (all layers)${RESET}"
  fi

  # Run the appropriate layers
  if [[ -n "$SINGLE_LAYER" ]]; then
    case "$SINGLE_LAYER" in
      1) run_layer 1 "API Smoke Tests" "$SCRIPTS_DIR/layer1-smoke-tests.sh" "${EXTRA_ARGS[@]}" ;;
      3) run_layer 3 "Authenticated API Tests" "$SCRIPTS_DIR/layer3-auth-tests.sh" "${EXTRA_ARGS[@]}" ;;
      4) run_layer 4 "Simulator Build + XCTest" "$SCRIPTS_DIR/layer4-simulator-tests.sh" "${EXTRA_ARGS[@]}" ;;
      *) echo "Unknown layer: $SINGLE_LAYER (valid: 1, 3, 4)"; exit 1 ;;
    esac
  elif [[ $QUICK -eq 1 ]] || [[ $DRY_RUN -eq 1 ]]; then
    run_layer 1 "API Smoke Tests (no auth)" "$SCRIPTS_DIR/layer1-smoke-tests.sh" "${EXTRA_ARGS[@]}"
    if [[ $ALL_PASSED -eq 1 ]]; then
      run_layer 3 "Authenticated API Tests" "$SCRIPTS_DIR/layer3-auth-tests.sh" "${EXTRA_ARGS[@]}"
    fi
  else
    run_layer 1 "API Smoke Tests (no auth)" "$SCRIPTS_DIR/layer1-smoke-tests.sh" "${EXTRA_ARGS[@]}"
    run_layer 3 "Authenticated API Tests" "$SCRIPTS_DIR/layer3-auth-tests.sh" "${EXTRA_ARGS[@]}"
    if [[ $ALL_PASSED -eq 1 ]]; then
      run_layer 4 "Simulator Build + XCTest + Screenshots" \
        "$SCRIPTS_DIR/layer4-simulator-tests.sh" "${EXTRA_ARGS[@]}"
    fi
  fi

  print_iteration_summary "$CURRENT_ITER"

  # Tally results
  if [[ $ALL_PASSED -eq 1 ]]; then
    ITER_PASS=$((ITER_PASS+1))
  else
    ITER_FAIL=$((ITER_FAIL+1))
  fi

  # Track per-layer pass/fail counts and timing
  for result in "${LAYER_RESULTS[@]}"; do
    local_status="${result%%:*}"
    local_rest="${result#*:}"
    local_layer="${local_rest%%:*}"
    local_rest2="${local_rest#*:}"
    local_timing="${local_rest2%%:*}"

    LAYER_PASS_COUNTS[$local_layer]=${LAYER_PASS_COUNTS[$local_layer]:-0}
    LAYER_FAIL_COUNTS[$local_layer]=${LAYER_FAIL_COUNTS[$local_layer]:-0}
    LAYER_TIMINGS[$local_layer]=${LAYER_TIMINGS[$local_layer]:-""}

    if [[ "$local_status" == "PASS" ]]; then
      LAYER_PASS_COUNTS[$local_layer]=$((${LAYER_PASS_COUNTS[$local_layer]}+1))
    else
      LAYER_FAIL_COUNTS[$local_layer]=$((${LAYER_FAIL_COUNTS[$local_layer]}+1))
    fi
    LAYER_TIMINGS[$local_layer]+="${local_timing} "
  done

  # Small pause between iterations
  if [[ $CURRENT_ITER -lt $ITERATIONS ]]; then
    echo ""
    info_plain() { echo -e "${YELLOW}  ▶${RESET} $1"; }
    info_plain "Waiting 3s before next iteration..."
    sleep 3
  fi

done

# ── Final multi-iteration summary ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  AMACH TEST RUNNER — FINAL SUMMARY${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "  Total iterations: $ITERATIONS"
echo -e "  ${GREEN}Passed: $ITER_PASS${RESET}  /  ${RED}Failed: $ITER_FAIL${RESET}"
echo ""

if [[ $ITERATIONS -gt 1 ]]; then
  echo -e "  ${BOLD}Per-layer stability:${RESET}"
  for layer in $(echo "${!LAYER_PASS_COUNTS[@]}" | tr ' ' '\n' | sort); do
    lp=${LAYER_PASS_COUNTS[$layer]:-0}
    lf=${LAYER_FAIL_COUNTS[$layer]:-0}
    lt=$((lp + lf))
    pct=0
    if [[ $lt -gt 0 ]]; then
      pct=$(( (lp * 100) / lt ))
    fi
    if [[ $lf -eq 0 ]]; then
      echo -e "    ${GREEN}✓${RESET} Layer $layer: $lp/$lt (${pct}% pass rate)"
    else
      echo -e "    ${RED}✗${RESET} Layer $layer: $lp/$lt (${pct}% pass rate) — $lf failures"
    fi
  done
  echo ""
fi

OVERALL_PASS=1
for layer in "${!LAYER_FAIL_COUNTS[@]}"; do
  if [[ ${LAYER_FAIL_COUNTS[$layer]:-0} -gt 0 ]]; then
    OVERALL_PASS=0
    break
  fi
done

if [[ $OVERALL_PASS -eq 1 ]] && [[ $ITER_FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  ✓ ALL ITERATIONS PASSED — System is stable, ready to code${RESET}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "  ${YELLOW}(Dry-run: no real network calls were made)${RESET}"
    echo -e "  Run without --dry-run to verify against live production"
  else
    echo -e "  Test account: 0x5C52974c3217fE4B62D5035E336089DEE1718fd6"
    echo -e "  Logs: $LOG_DIR/"
    echo -e "  Screenshots: $SCRIPT_DIR/Tests/Screenshots/"
  fi
else
  echo -e "${RED}${BOLD}  ✗ FAILURES DETECTED — Investigate before coding${RESET}"
  echo -e "  Logs: $LOG_DIR/"
  exit 1
fi
echo ""
