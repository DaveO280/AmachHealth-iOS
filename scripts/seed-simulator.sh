#!/usr/bin/env bash
# =============================================================================
# seed-simulator.sh — Seed iOS Simulator HealthKit store with 60 days of data
# =============================================================================
#
# Runs the MockDataSeeder fully autonomously — no UI dialogs, no manual steps.
#
# What it does:
#   1. Finds the booted simulator UDID
#   2. Pre-grants HealthKit write permissions (bypasses the system dialog)
#   3. Builds and runs SeedHealthKitTests/testSeedHealthKitData via xcodebuild
#
# Prerequisites:
#   • Xcode installed (xcodebuild, xcrun in PATH)
#   • At least one iOS Simulator is booted
#     → Open Simulator.app or: xcrun simctl boot <UDID>
#
# Usage:
#   ./scripts/seed-simulator.sh               # use booted simulator
#   ./scripts/seed-simulator.sh --reset       # revoke + re-grant permissions first
#   ./scripts/seed-simulator.sh --dry-run     # validate env, skip xcodebuild
#
# After seeding, launch "Amach Health" in the Simulator, open Luma chat, and ask:
#   "How has my recovery been trending this month?"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCODEPROJ="$PROJECT_ROOT/AmachHealth.xcodeproj"
SCHEME="Amach Health"
BUNDLE_ID="com.amach.health"
TEST_ID="Amach HealthTests/SeedHealthKitTests/testSeedHealthKitData"

# ── Args ──────────────────────────────────────────────────────────────────────
RESET_PERMS=0
DRY_RUN=0
for arg in "$@"; do
  case $arg in
    --reset)   RESET_PERMS=1 ;;
    --dry-run) DRY_RUN=1     ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${CYAN}  ▶${RESET} $1"; }
success() { echo -e "${GREEN}  ✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET} $1"; }
die()     { echo -e "${RED}  ✗ ERROR:${RESET} $1" >&2; exit 1; }

echo ""
echo -e "${BOLD}  Amach Health — HealthKit Data Seeder${RESET}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ── Validate tools ────────────────────────────────────────────────────────────
info "Checking prerequisites…"
command -v xcrun      >/dev/null 2>&1 || die "xcrun not found — install Xcode."
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found — install Xcode."
[[ -d "$XCODEPROJ" ]] || die "Project not found: $XCODEPROJ"
success "Prerequisites OK (Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}'))"

# ── Find booted simulator ─────────────────────────────────────────────────────
info "Looking for a booted simulator…"

# `xcrun simctl list devices booted` output format:
#   -- iOS 17.5 --
#   iPhone 15 Pro (XXXXXXXX-...) (Booted)
BOOTED_UDID=$(
  xcrun simctl list devices booted 2>/dev/null \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
    | head -1 \
  || true
)

if [[ -z "${BOOTED_UDID:-}" ]]; then
  die "No simulator is currently booted.
  Boot one first:
    open -a Simulator
  Or boot by UDID:
    xcrun simctl boot \$(xcrun simctl list devices available | grep 'iPhone 1' | head -1 | grep -oE '[0-9A-F-]{36}')
  Then re-run this script."
fi

BOOTED_NAME=$(
  xcrun simctl list devices booted 2>/dev/null \
    | grep "$BOOTED_UDID" \
    | sed 's/ (.*$//' \
    | xargs \
  || echo "Unknown"
)
success "Booted: $BOOTED_NAME ($BOOTED_UDID)"

# ── Grant permissions ─────────────────────────────────────────────────────────
#
# simctl privacy supports: all, calendar, contacts, location, photos, microphone,
# motion, reminders, siri.  "health" (HealthKit) was removed in Xcode 16/iOS 18+.
#
# Approach: grant "motion" (covers Core Motion activity data), then attempt
# "health" silently (works on older Xcode; no-ops on Xcode 16+).
# HealthKit authorization is stored in the simulator's TCC.db after the first
# user-approval — subsequent runs of this script need no interaction at all.

if [[ $RESET_PERMS -eq 1 ]]; then
  info "Resetting permissions (--reset)…"
  xcrun simctl privacy "$BOOTED_UDID" reset all "$BUNDLE_ID" 2>/dev/null || true
  success "Permissions reset — HealthKit dialog will appear on next launch."
fi

info "Granting motion + attempting HealthKit permissions…"
if [[ $DRY_RUN -eq 0 ]]; then
  xcrun simctl privacy "$BOOTED_UDID" grant motion "$BUNDLE_ID" 2>/dev/null || true
  # Silently try "health" — works on Xcode ≤15, no-ops on Xcode 16+ (not in service list).
  xcrun simctl privacy "$BOOTED_UDID" grant health "$BUNDLE_ID" 2>/dev/null || true

  # Check if "health" is in the supported services list.
  if ! xcrun simctl privacy --help 2>&1 | grep -q "health"; then
    warn "HealthKit ('health') not in simctl privacy service list (Xcode 16+)."
    warn "If this is your FIRST run, a HealthKit permission sheet will appear — approve it."
    warn "Subsequent runs will be fully autonomous (permissions persist in simulator)."
  else
    success "HealthKit permissions granted via simctl"
  fi
else
  success "Permissions would be granted (dry-run)"
fi

# ── Run the seeder test ───────────────────────────────────────────────────────
BUILD_LOG="/tmp/amach_seed_$$.log"

info "Building + running seeder test (this takes ~2–5 min on first build)…"
info "Log: $BUILD_LOG"

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo -e "${YELLOW}  DRY-RUN — would execute:${RESET}"
  echo "  xcodebuild test \\"
  echo "    -project '$XCODEPROJ' \\"
  echo "    -scheme '$SCHEME' \\"
  echo "    -destination 'id=$BOOTED_UDID' \\"
  echo "    -only-testing '$TEST_ID' \\"
  echo "    -testTimeoutsEnabled NO \\"
  echo "    CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO"
  echo ""
  success "Dry-run complete — environment is valid."
  exit 0
fi

# Stream output, capture to log, exit on failure.
set +e
xcodebuild test \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -destination "id=$BOOTED_UDID" \
  -only-testing "$TEST_ID" \
  -testTimeoutsEnabled NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$BUILD_LOG" | grep --line-buffered -E \
    "Build|Test Case|passed|failed|error:|FAILED|🌱|✅|⚠️|Seeded"
XCB_EXIT=${PIPESTATUS[0]}
set -e

if [[ $XCB_EXIT -ne 0 ]] || grep -q "FAILED\|Build FAILED" "$BUILD_LOG" 2>/dev/null; then
  echo ""
  die "xcodebuild failed (exit $XCB_EXIT). Last 30 lines of log:
$(tail -30 "$BUILD_LOG")"
fi

echo ""
success "Seeding complete!"
echo ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. Launch ${CYAN}Amach Health${RESET} in the Simulator"
echo -e "  2. Open ${CYAN}Luma${RESET} chat"
echo -e "  3. Ask: ${YELLOW}\"How has my recovery been trending this month?\"${RESET}"
echo -e "  4. Check anomaly detection: ${YELLOW}\"Did anything unusual happen recently?\"${RESET}"
echo ""
echo -e "  Log: $BUILD_LOG"
echo ""
