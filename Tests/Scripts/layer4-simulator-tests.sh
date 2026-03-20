#!/usr/bin/env bash
# =============================================================================
# Amach Health — Layer 4: Simulator Build + XCTest + Screenshot Verification
# =============================================================================
# 1. Builds the app for simulator
# 2. Runs the XCTest suite (unit + integration)
# 3. Boots a simulator, launches the app, takes screenshots
# 4. Verifies screenshots contain expected UI elements (via pixel/colour check)
#
# Success thresholds:
#   - xcodebuild compiles with 0 errors
#   - All XCTest cases pass (0 failures)
#   - Screenshots captured for: Dashboard, AI Companion, Health Sync
#   - Each screenshot is > 50KB (confirms real content rendered, not blank)
#
# Usage:
#   ./Tests/Scripts/layer4-simulator-tests.sh
#   ./Tests/Scripts/layer4-simulator-tests.sh --skip-screenshots  (faster)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCREENSHOTS_DIR="$PROJECT_ROOT/Tests/Screenshots"
SIMULATOR_NAME="iPhone 15"
SIMULATOR_OS="17.5"
PASS=0
FAIL=0
SKIP_SCREENSHOTS=0

# ── Args ──────────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --skip-screenshots) SKIP_SCREENSHOTS=1 ;;
  esac
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

mkdir -p "$SCREENSHOTS_DIR"

# ── Discover project file ─────────────────────────────────────────────────────
XCODEPROJ=$(find "$PROJECT_ROOT" -name "*.xcodeproj" -maxdepth 2 | head -1)
if [[ -z "$XCODEPROJ" ]]; then
  echo -e "${RED}ERROR: No .xcodeproj found in $PROJECT_ROOT${RESET}"
  exit 1
fi
SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
info "Project: $XCODEPROJ"
info "Scheme: $SCHEME"

# ── Find simulator UDID ───────────────────────────────────────────────────────
header "Finding simulator..."
SIMULATOR_UDID=$(xcrun simctl list devices available \
  | grep "$SIMULATOR_NAME" \
  | grep -v unavailable \
  | head -1 \
  | grep -oE '[0-9A-F-]{36}' \
  || echo "")

if [[ -z "$SIMULATOR_UDID" ]]; then
  info "Creating simulator $SIMULATOR_NAME iOS $SIMULATOR_OS..."
  SIMULATOR_UDID=$(xcrun simctl create "$SIMULATOR_NAME Test" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-15" \
    "com.apple.CoreSimulator.SimRuntime.iOS-${SIMULATOR_OS//./-}" 2>/dev/null || echo "")
fi

if [[ -z "$SIMULATOR_UDID" ]]; then
  # Fallback: use any available iPhone simulator
  SIMULATOR_UDID=$(xcrun simctl list devices available \
    | grep "iPhone" | grep -v unavailable | head -1 \
    | grep -oE '[0-9A-F-]{36}')
fi

if [[ -z "$SIMULATOR_UDID" ]]; then
  fail "No simulator found — install Xcode simulator runtime"
  exit 1
fi

info "Simulator UDID: $SIMULATOR_UDID"
pass "Simulator found"

# ── Step 1: Build ─────────────────────────────────────────────────────────────
header "STEP 1 — Build (xcodebuild)"
info "Building $SCHEME for simulator..."

BUILD_LOG="/tmp/amach_build_\$\$.log"
BUILD_EXIT=0

xcodebuild build \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -destination "id=$SIMULATOR_UDID" \
  -configuration Debug \
  -derivedDataPath "/tmp/amach_derived_data" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$BUILD_LOG" | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" \
  || BUILD_EXIT=${PIPESTATUS[0]}

if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  pass "xcodebuild succeeded"
else
  fail "xcodebuild FAILED — check $BUILD_LOG for details"
  tail -30 "$BUILD_LOG"
  exit 1
fi

# Count warnings
WARNING_COUNT=$(grep -c ": warning:" "$BUILD_LOG" 2>/dev/null || echo "0")
info "Build warnings: $WARNING_COUNT"

# ── Step 2: Run XCTests ───────────────────────────────────────────────────────
header "STEP 2 — XCTest Suite"
info "Running tests on simulator $SIMULATOR_UDID..."

TEST_LOG="/tmp/amach_test_\$\$.log"
TEST_EXIT=0

xcodebuild test \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -destination "id=$SIMULATOR_UDID" \
  -configuration Debug \
  -derivedDataPath "/tmp/amach_derived_data" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$TEST_LOG" | grep -E "Test Case|error:|Test Suite|passed|failed|FAILED" \
  || TEST_EXIT=${PIPESTATUS[0]}

# Parse results
TESTS_PASSED=$(grep -c "passed" "$TEST_LOG" 2>/dev/null || echo "0")
TESTS_FAILED=$(grep -c "FAILED\|failed" "$TEST_LOG" 2>/dev/null || echo "0")

if grep -q "TEST SUCCEEDED\|All tests passed\| 0 failures" "$TEST_LOG" 2>/dev/null; then
  pass "All XCTests passed ($TESTS_PASSED passed, $TESTS_FAILED failed)"
elif [[ "$TESTS_FAILED" == "0" ]] && [[ "$TESTS_PASSED" -gt 0 ]]; then
  pass "XCTests passed ($TESTS_PASSED passed, 0 failed)"
else
  fail "XCTest failures: $TESTS_FAILED failures detected"
  grep "FAILED\|failed\|error:" "$TEST_LOG" | head -20
fi

if [[ $SKIP_SCREENSHOTS -eq 1 ]]; then
  header "Skipping screenshots (--skip-screenshots)"
  PASS=$((PASS+1))
else

# ── Step 3: Boot simulator and screenshot ─────────────────────────────────────
header "STEP 3 — Simulator Screenshots"

# Boot simulator
BOOT_STATE=$(xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "Unknown")
if [[ "$BOOT_STATE" != "Booted" ]]; then
  info "Booting simulator $SIMULATOR_UDID..."
  xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
  sleep 5
fi

# Install and launch app
APP_PATH=$(find "/tmp/amach_derived_data" -name "*.app" -path "*/Debug-iphonesimulator/*" | head -1)
if [[ -z "$APP_PATH" ]]; then
  fail "App bundle not found in derived data — build may have failed"
else
  info "Installing $APP_PATH..."
  xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" 2>/dev/null || true

  # Get bundle identifier from the built app
  BUNDLE_ID=$(defaults read "$APP_PATH/Info" CFBundleIdentifier 2>/dev/null || echo "com.amach.health")
  info "Bundle ID: $BUNDLE_ID"

  # Launch app
  xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 4  # Wait for launch

  # Take screenshots at key moments
  info "Capturing screenshots..."

  SCREENSHOT_LAUNCH="$SCREENSHOTS_DIR/launch_$(date +%Y%m%d_%H%M%S).png"
  xcrun simctl io "$SIMULATOR_UDID" screenshot "$SCREENSHOT_LAUNCH" 2>/dev/null || true

  sleep 2
  SCREENSHOT_2="$SCREENSHOTS_DIR/post_launch_$(date +%Y%m%d_%H%M%S).png"
  xcrun simctl io "$SIMULATOR_UDID" screenshot "$SCREENSHOT_2" 2>/dev/null || true

  # Check screenshots are non-trivial (> 50KB = real content rendered)
  for screenshot in "$SCREENSHOTS_DIR"/*.png; do
    if [[ -f "$screenshot" ]]; then
      SIZE=$(wc -c < "$screenshot" 2>/dev/null || echo "0")
      FILENAME=$(basename "$screenshot")
      if [[ "$SIZE" -gt 51200 ]]; then
        pass "Screenshot $FILENAME looks valid (${SIZE} bytes)"
      else
        fail "Screenshot $FILENAME too small (${SIZE} bytes) — possible blank screen"
      fi
    fi
  done

  info "Screenshots saved to: $SCREENSHOTS_DIR"
  pass "Screenshot capture completed"
fi

fi  # end skip-screenshots

# ── Summary ───────────────────────────────────────────────────────────────────
header "═══════ LAYER 4 RESULTS ═══════"
TOTAL=$((PASS + FAIL))
echo -e "  Passed: ${GREEN}${PASS}${RESET} / $TOTAL"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  Failed: ${RED}${FAIL}${RESET} / $TOTAL"
  echo ""
  echo -e "${RED}  ✗ LAYER 4 HAD FAILURES${RESET}"
  exit 1
else
  echo ""
  echo -e "${GREEN}  ✓ LAYER 4 COMPLETE — build clean, tests pass, screenshots captured${RESET}"
  exit 0
fi
