#!/usr/bin/env bash
# luma-memory-test.sh — Multi-turn memory stress test
# 5 chains × 4 turns = 20 queries
# Each chain passes prior assistant responses as history
# Focus metric: Memory/continuity (1-5) per turn
# Flag turns scoring ≤2/5 on turns 2-4

set -euo pipefail

API_URL="https://www.amachhealth.com/api/ai/chat"
TIMEOUT=600
PAUSE=3

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

COMMIT="${1:-unknown}"

ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }

LOGFILE="Tests/Logs/memory-test-t2fix-$(date +%Y%m%d-%H%M%S).log"
mkdir -p Tests/Logs

# ─── Context ──────────────────────────────────────────────────────────────────
CONTEXT_JSON='{
  "profile": {
    "age": 44,
    "sex": "male",
    "goals": ["improve HRV above 55ms", "lose 3kg body fat", "run 5k under 25 min"],
    "concerns": ["elevated LDL cholesterol", "poor sleep on work nights", "low energy Tuesdays/Wednesdays"]
  },
  "metrics": {
    "steps":            { "latest": 7200,  "average": 8100,  "trend": "declining" },
    "restingHeartRate": { "latest": 63,    "average": 64,    "trend": "stable" },
    "hrv":              { "latest": 41,    "average": 44,    "trend": "declining" },
    "sleep":            { "latest": 6.8,   "average": 7.1,   "trend": "stable" },
    "exercise":         { "latest": 35,    "average": 28,    "trend": "improving" },
    "vo2Max":           { "latest": 42.3 },
    "respiratoryRate":  { "latest": 14.2 }
  },
  "today_partial": { "steps": 4100, "activeCalories": 210, "note": "so far today (9am)" },
  "bloodwork": [
    { "marker": "Total Cholesterol", "value": 214, "unit": "mg/dL",  "date": "2025-11-15" },
    { "marker": "LDL",               "value": 138, "unit": "mg/dL",  "date": "2025-11-15" },
    { "marker": "HDL",               "value": 52,  "unit": "mg/dL",  "date": "2025-11-15" },
    { "marker": "Triglycerides",     "value": 118, "unit": "mg/dL",  "date": "2025-11-15" },
    { "marker": "Glucose",           "value": 94,  "unit": "mg/dL",  "date": "2025-11-15" },
    { "marker": "HbA1c",             "value": 5.4, "unit": "%",      "date": "2025-11-15" },
    { "marker": "Ferritin",          "value": 68,  "unit": "ng/mL",  "date": "2025-11-15" },
    { "marker": "Vitamin D",         "value": 31,  "unit": "ng/mL",  "date": "2025-11-15" },
    { "marker": "Testosterone",      "value": 520, "unit": "ng/dL",  "date": "2025-11-15" },
    { "marker": "TSH",               "value": 1.8, "unit": "mIU/L",  "date": "2025-11-15" },
    { "marker": "hsCRP",             "value": 1.2, "unit": "mg/L",   "date": "2025-11-15" },
    { "marker": "Homocysteine",      "value": 9.4, "unit": "μmol/L", "date": "2025-11-15" }
  ],
  "anomalies": [
    { "metric": "HRV",       "description": "crashed 50% to 22ms (baseline 44ms) — 3-day cluster", "severity": "high",   "date": "2026-03-17" },
    { "metric": "RestingHR", "description": "spiked to 82bpm (baseline 63bpm) during HRV crash",   "severity": "high",   "date": "2026-03-17" },
    { "metric": "Steps",     "description": "unusually high: 22100 steps (baseline ~8100)",         "severity": "medium", "date": "2026-03-30" },
    { "metric": "Sleep",     "description": "2nd consecutive short sleep: 4.5h (baseline 7.1h)",    "severity": "medium", "date": "2026-04-01" }
  ],
  "timeline_events": [
    { "date": "2026-03-15", "type": "illness",    "description": "started feeling run down, sore throat" },
    { "date": "2026-03-20", "type": "recovery",   "description": "back to normal energy" },
    { "date": "2026-03-28", "type": "supplement", "description": "started vitamin D 2000 IU daily" },
    { "date": "2026-03-30", "type": "exercise",   "description": "hiked Sugarloaf Mountain 14km, 22100 steps" }
  ],
  "dateRange": { "start": "2026-02-01", "end": "2026-04-01" }
}'

# ─── Detection ────────────────────────────────────────────────────────────────
is_deflection() {
  local t; t=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  echo "$t" | grep -qE "i don.t have|try rephrasing|i.m processing|cannot provide|no data available|unable to access|don.t have access|i lack|can.t access|sync your|upload your|could you try|narrowing your"
}

# ─── Memory scoring ───────────────────────────────────────────────────────────
# $1=response  $2=chain(A-E)  $3=turn(1-4)
# Turn 1: scored on data-use (no prior context to remember)
# Turns 2-4: scored on whether response references specifics from earlier turns
score_memory() {
  local r="$1" chain="$2" turn="$3"
  is_deflection "$r" && echo 1 && return

  if [ "$turn" -eq 1 ]; then
    # Turn 1 baseline: does it use the context at all?
    local h=0
    echo "$r" | grep -qi "44.*ms\|41.*ms\|hrv"                && (( h++ )) || true
    echo "$r" | grep -qi "138\|ldl"                            && (( h++ )) || true
    echo "$r" | grep -qi "7\.1\|sleep"                         && (( h++ )) || true
    echo "$r" | grep -qi "march\|2026-03\|illness\|sugarloaf" && (( h++ )) || true
    echo "$r" | grep -qi "22ms\|22 ms\|crash"                 && (( h++ )) || true
    if   [ "$h" -ge 4 ]; then echo 5
    elif [ "$h" -ge 3 ]; then echo 4
    elif [ "$h" -ge 2 ]; then echo 3
    elif [ "$h" -ge 1 ]; then echo 2
    else echo 1; fi
    return
  fi

  # Turns 2-4: look for forward-references to prior assistant output
  local c=0
  # Universal continuity signals
  echo "$r" | grep -qi "you mentioned\|as i noted\|earlier\|we discussed\|i said\|from our\|in this conversation\|based on what i" && (( c++ )) || true

  case "$chain" in
    A) # HRV chain
      echo "$r" | grep -qi "22ms\|22 ms\|crash\|dropped.*hrv\|illness\|march 1[5-9]\|decline\|44.*ms\|41.*ms" && (( c++ )) || true
      [ "$turn" -ge 3 ] && echo "$r" | grep -qi "train\|intensity\|zone\|easy.*run\|aerobic\|load\|recover" && (( c++ )) || true
      [ "$turn" -ge 4 ] && echo "$r" | grep -qi "hrv.*55\|55.*ms\|trend\|upward\|improv\|week.*monitor\|check" && (( c++ )) || true
      echo "$r" | grep -qi "44\|41\|22\|55" && (( c++ )) || true
      ;;
    B) # Bloodwork chain
      echo "$r" | grep -qi "138\|ldl\|214\|52.*hdl\|hdl.*52\|trig\|118\|ratio\|panel" && (( c++ )) || true
      [ "$turn" -ge 3 ] && echo "$r" | grep -qi "diet\|saturated\|fiber\|omega\|week\|month\|lower\|reduce" && (( c++ )) || true
      [ "$turn" -ge 4 ] && echo "$r" | grep -qi "crp\|hscrp\|1\.2\|homocysteine\|9\.4\|inflam\|apoB\|triglyc\|hdl\|glucose\|hba1c" && (( c++ )) || true
      ;;
    C) # Sleep chain
      echo "$r" | grep -qi "7\.1\|4\.5\|6\.8\|short.*sleep\|sleep.*short\|work night\|tuesday\|wednesday\|consec" && (( c++ )) || true
      [ "$turn" -ge 3 ] && echo "$r" | grep -qi "train\|late.*session\|session.*late\|evening.*work\|hrv.*sleep\|sleep.*hrv\|recover" && (( c++ )) || true
      [ "$turn" -ge 4 ] && echo "$r" | grep -qi "protocol\|bedtime\|wind.down\|cutoff\|consisten\|schedule\|routine\|7.*hour" && (( c++ )) || true
      ;;
    D) # Goals chain
      echo "$r" | grep -qi "hrv.*55\|55.*ms\|5k.*25\|25.*min\|3.*kg\|body fat\|three goals\|all.*goal" && (( c++ )) || true
      [ "$turn" -ge 3 ] && echo "$r" | grep -qi "sleep\|hrv\|single.*change\|one.*change\|highest.*impact\|biggest.*lever\|consisten" && (( c++ )) || true
      [ "$turn" -ge 4 ] && echo "$r" | grep -qi "ldl\|138\|cholesterol\|bloodwork\|crp\|inflam\|sleep.*ldl\|ldl.*sleep\|diet\|cardio" && (( c++ )) || true
      ;;
    E) # Recovery chain
      echo "$r" | grep -qi "22ms\|22 ms\|hrv.*crash\|82.*bpm\|4\.5.*h\|short sleep\|march 17\|illness\|anomal\|flagged" && (( c++ )) || true
      [ "$turn" -ge 3 ] && echo "$r" | grep -qi "sleep\|volume\|intensity\|taper\|deload\|protein\|easy\|zone 2\|aerobic" && (( c++ )) || true
      [ "$turn" -ge 4 ] && echo "$r" | grep -qi "ceiling\|limit\|overreach\|hrv\|resting.*hr\|threshold\|warning\|sign\|flag\|monitor" && (( c++ )) || true
      ;;
  esac

  if   [ "$c" -ge 4 ]; then echo 5
  elif [ "$c" -ge 3 ]; then echo 4
  elif [ "$c" -ge 2 ]; then echo 3
  elif [ "$c" -ge 1 ]; then echo 2
  else echo 1; fi
}

score_depth() {
  local r="$1" len="${#1}"
  [ "$len" -lt 100 ] && echo 1 && return
  is_deflection "$r" && echo 1 && return
  local n; n=$(echo "$r" | grep -oE '[0-9]+\.?[0-9]*' | wc -l | tr -d ' ')
  if   [ "$n" -ge 6 ]; then echo 5
  elif [ "$n" -ge 3 ]; then echo 4
  elif [ "$n" -ge 1 ]; then echo 3
  else echo 2; fi
}

# ─── Build payload ────────────────────────────────────────────────────────────
build_payload() {
  local query="$1" history="${2:-null}"
  local eq; eq=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$query")
  eq="${eq:1:${#eq}-2}"
  if [ "$history" = "null" ]; then
    printf '{"message":"%s","context":%s,"walletAddress":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"}' \
      "$eq" "$CONTEXT_JSON"
  else
    printf '{"message":"%s","context":%s,"history":%s,"walletAddress":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"}' \
      "$eq" "$CONTEXT_JSON" "$history"
  fi
}

# ─── Append turn to history JSON ──────────────────────────────────────────────
append_history() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, json
hist_raw, user_msg, asst_msg = sys.argv[1], sys.argv[2], sys.argv[3]
hist = [] if hist_raw == "null" else json.loads(hist_raw)
hist.append({"role": "user",      "content": user_msg})
hist.append({"role": "assistant", "content": asst_msg})
print(json.dumps(hist))
PYEOF
}

# ─── Global result arrays ─────────────────────────────────────────────────────
declare -a RES_CHAIN RES_TURN RES_LABEL RES_MEM RES_DEPTH RES_PASS
TOTAL_PASS=0; TOTAL_FAIL=0
declare -a FLAGGED

# ─── Run one turn ─────────────────────────────────────────────────────────────
# Sets globals: TURN_RESPONSE, TURN_MEM, TURN_DEPTH, TURN_PASS
TURN_RESPONSE=""; TURN_MEM=1; TURN_DEPTH=1; TURN_PASS="FAIL"

run_turn() {
  local chain="$1" turn="$2" label="$3" query="$4" history="${5:-null}"

  printf "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "${BOLD}Chain %s — Turn %s:${RESET} %s\n" "$chain" "$turn" "$label"
  printf "${DIM}\"%s\"${RESET}\n" "$query"

  local payload; payload=$(build_payload "$query" "$history")
  local t0; t0=$(ms_now)
  local raw_file; raw_file=$(mktemp)
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$raw_file" \
    --max-time "$TIMEOUT" \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || true
  local t1; t1=$(ms_now)
  local elapsed_s; elapsed_s=$(python3 -c "print('%.2f' % (($t1-$t0)/1000.0))")
  local raw; raw=$(cat "$raw_file"); rm -f "$raw_file"

  local response=""
  if [ "$http_code" = "200" ]; then
    response=$(python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('content') or d.get('message') or d.get('reply') or d.get('response') or '')
except: print('')
" <<< "$raw")
  fi

  local deflect="NO"
  is_deflection "$response" && deflect="YES"

  local mem; mem=$(score_memory "$response" "$chain" "$turn")
  local dep; dep=$(score_depth "$response")

  local avg; avg=$(python3 -c "print(int(($mem+$dep)/2.0+0.5))")
  local verdict
  if   [ "$avg" -ge 4 ]; then verdict="Strong"
  elif [ "$avg" -ge 3 ]; then verdict="Acceptable"
  else verdict="Weak"; fi

  local pf="PASS"
  if [ "$http_code" != "200" ] || [ "$deflect" = "YES" ]; then
    pf="FAIL"
  fi

  printf "\n${DIM}HTTP %s — %ss${RESET}\n\n" "${http_code:-ERR}" "$elapsed_s"
  printf "${BOLD}Response:${RESET}\n"
  printf '%s\n' "────────────────────────────────────────────────────────────────────────────"
  echo "$response"
  printf '%s\n' "────────────────────────────────────────────────────────────────────────────"
  printf "\n  ${DIM}Length: %d chars${RESET}\n" "${#response}"

  if [ "$mem" -le 2 ] && [ "$turn" -gt 1 ]; then
    printf "  ${RED}⚠  MEMORY WEAK: %d/5${RESET}\n" "$mem"
  else
    printf "  ${GREEN}✓  Memory/continuity: %d/5${RESET}\n" "$mem"
  fi
  [ "$deflect" = "YES" ] && printf "  ${RED}✗  DEFLECTION DETECTED${RESET}\n"

  printf "\n  ${BOLD}Scores:${RESET}  Memory %d/5  Depth %d/5  → ${BOLD}%s${RESET}\n" \
    "$mem" "$dep" "$verdict"

  if [ "$pf" = "PASS" ]; then
    printf "  ${GREEN}${BOLD}→ PASS${RESET}\n"
  else
    printf "  ${RED}${BOLD}→ FAIL${RESET}\n"
  fi

  # Set globals for caller
  TURN_RESPONSE="$response"
  TURN_MEM="$mem"
  TURN_DEPTH="$dep"
  TURN_PASS="$pf"
}

# ─── Run one chain ────────────────────────────────────────────────────────────
run_chain() {
  local chain_letter="$1"
  local label1="$2" query1="$3"
  local label2="$4" query2="$5"
  local label3="$6" query3="$7"
  local label4="$8" query4="$9"

  printf "\n${BOLD}═══ CHAIN %s ═══════════════════════════════════════════════════════════════${RESET}\n" \
    "$chain_letter"

  local history="null"
  local turn=1

  for pair_label in "$label1" "$label2" "$label3" "$label4"; do
    local pair_query
    case "$turn" in
      1) pair_query="$query1" ;;
      2) pair_query="$query2" ;;
      3) pair_query="$query3" ;;
      4) pair_query="$query4" ;;
    esac

    run_turn "$chain_letter" "$turn" "$pair_label" "$pair_query" "$history"

    # Record results
    RES_CHAIN+=("$chain_letter")
    RES_TURN+=("$turn")
    RES_LABEL+=("${chain_letter}${turn}: $pair_label")
    RES_MEM+=("$TURN_MEM")
    RES_DEPTH+=("$TURN_DEPTH")
    RES_PASS+=("$TURN_PASS")

    if [ "$TURN_PASS" = "PASS" ]; then
      (( TOTAL_PASS++ )) || true
    else
      (( TOTAL_FAIL++ )) || true
    fi

    if [ "$TURN_MEM" -le 2 ] && [ "$turn" -gt 1 ]; then
      FLAGGED+=("Chain ${chain_letter} Turn ${turn} — ${pair_label}: Memory ${TURN_MEM}/5")
    fi

    # Append this turn to history for next turn
    history=$(append_history "$history" "$pair_query" "$TURN_RESPONSE")

    (( turn++ )) || true
    [ "$turn" -le 4 ] && sleep "$PAUSE" || true
  done
}

# ─── Main ─────────────────────────────────────────────────────────────────────
{
printf "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║    LUMA MEMORY STRESS TEST — 5 CHAINS × 4 TURNS = 20 QUERIES          ║${RESET}\n"
printf "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}\n"
printf "  Commit: ${CYAN}%s${RESET}\n" "$COMMIT"
printf "  Target: ${CYAN}%s${RESET}\n" "$API_URL"
printf "  Timeout: %ss | Pause: %ss | Started: %s\n" "$TIMEOUT" "$PAUSE" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "  Focus: Memory/continuity — flags turns 2-4 scoring ≤2/5\n"

# Chain A — HRV
run_chain "A" \
  "HRV overview"          "What's been happening with my HRV?" \
  "Why is it happening?"  "Why do you think that's happening?" \
  "Training adjustments"  "Given what you just described, what would you change about my training?" \
  "How to know it's working" "How would I know if that change is working?"

sleep "$PAUSE"

# Chain B — Bloodwork / Lipids
run_chain "B" \
  "Lipid panel walkthrough" "Walk me through my lipid panel." \
  "LDL driver"              "The LDL specifically — what do you think is driving it?" \
  "Diet timeline"           "If I adjust my diet, how long before the LDL moves?" \
  "Companion markers"       "What other markers should I watch alongside the LDL?"

sleep "$PAUSE"

# Chain C — Sleep
run_chain "C" \
  "Sleep overview"          "How's my sleep overall?" \
  "Short-sleep window impact" "That short-sleep window you mentioned — what happened around that time in my other metrics?" \
  "Late training pattern"   "Is there a pattern between my late training days and sleep quality?" \
  "Concrete sleep protocol" "Give me a concrete sleep protocol based on everything we've discussed in this conversation."

sleep "$PAUSE"

# Chain D — Goals
run_chain "D" \
  "Goal progress"           "Am I making progress toward my goals?" \
  "Most at-risk goal"       "Which goal is most at risk?" \
  "Highest-impact change"   "What's one change that would have the most impact across all three goals?" \
  "Change vs bloodwork"     "How would that change interact with my current bloodwork?"

sleep "$PAUSE"

# Chain E — Recovery
run_chain "E" \
  "Recovery capacity"       "How's my recovery capacity right now?" \
  "Anomaly in bloodwork"    "You mentioned an anomaly just now — is that connected to anything in my bloodwork?" \
  "Preparing for hard week" "If I have a hard training week coming, how should I prepare given everything you've told me?" \
  "Current ceiling"         "What's my current ceiling before I'd be overreaching?"

# ─── Report card ──────────────────────────────────────────────────────────────
printf "\n${BOLD}═══ REPORT CARD ════════════════════════════════════════════════════════════${RESET}\n"
printf "\n${BOLD}%-44s  %-4s  %s  %s  %s${RESET}\n" "Turn" "P/F" "Mem" "Dep" "Verdict"
printf '%s\n' "────────────────────────────────────────────────────────────────────────"

total_mem=0; total_depth=0
mem_t24_sum=0; mem_t24_count=0

for i in "${!RES_LABEL[@]}"; do
  lab="${RES_LABEL[$i]}"
  pf="${RES_PASS[$i]}"
  mem="${RES_MEM[$i]}"
  dep="${RES_DEPTH[$i]}"
  trn="${RES_TURN[$i]}"

  total_mem=$(python3 -c "print($total_mem + $mem)")
  total_depth=$(python3 -c "print($total_depth + $dep)")

  if [ "$trn" -ge 2 ]; then
    mem_t24_sum=$(python3 -c "print($mem_t24_sum + $mem)")
    (( mem_t24_count++ )) || true
  fi

  avg=$(python3 -c "print(int(($mem+$dep)/2.0+0.5))")
  if   [ "$avg" -ge 4 ]; then ver="Strong"
  elif [ "$avg" -ge 3 ]; then ver="Acceptable"
  else ver="Weak"; fi

  pf_c="${GREEN}"; [ "$pf" = "FAIL" ] && pf_c="${RED}"
  mem_c="${GREEN}"; [ "$mem" -le 2 ] && [ "$trn" -gt 1 ] && mem_c="${RED}"

  printf "${pf_c}%-44s  %-4s${RESET}  ${mem_c}%s/5${RESET}  %s/5  %s\n" \
    "${lab:0:44}" "$pf" "$mem" "$dep" "$ver"
done

count="${#RES_LABEL[@]}"
avg_mem=$(python3 -c "print('%.2f' % ($total_mem/$count))")
avg_dep=$(python3 -c "print('%.2f' % ($total_depth/$count))")
avg_t24=$(python3 -c "print('%.2f' % ($mem_t24_sum/max($mem_t24_count,1)))")

printf "\n${BOLD}Dimension averages (all 20 turns):${RESET}\n"
printf "  Memory/continuity: %s/5\n" "$avg_mem"
printf "  Depth:             %s/5\n" "$avg_dep"
printf "\n${BOLD}Memory average — turns 2-4 only (the real test):${RESET}\n"
printf "  ${CYAN}%s/5${RESET}\n" "$avg_t24"

# Per-chain breakdown (turns 2-4)
printf "\n${BOLD}Per-chain memory (turns 2-4):${RESET}\n"
for ch in A B C D E; do
  csum=0; ccount=0
  for i in "${!RES_CHAIN[@]}"; do
    if [ "${RES_CHAIN[$i]}" = "$ch" ] && [ "${RES_TURN[$i]}" -ge 2 ]; then
      csum=$(python3 -c "print($csum + ${RES_MEM[$i]})")
      (( ccount++ )) || true
    fi
  done
  cavg=$(python3 -c "print('%.1f' % ($csum/max($ccount,1)))")
  case "$ch" in
    A) cname="HRV"       ;;
    B) cname="Bloodwork" ;;
    C) cname="Sleep"     ;;
    D) cname="Goals"     ;;
    E) cname="Recovery"  ;;
  esac
  ccolor="${GREEN}"
  python3 -c "import sys; sys.exit(0 if float('$cavg')>=3.0 else 1)" 2>/dev/null || ccolor="${RED}"
  printf "  Chain %s (%s): ${ccolor}%s/5${RESET}\n" "$ch" "$cname" "$cavg"
done

printf "\n${BOLD}Pass/Fail: ${GREEN}%d PASS${RESET} / ${RED}%d FAIL${RESET} out of %d\n" \
  "$TOTAL_PASS" "$TOTAL_FAIL" "$count"

if [ "${#FLAGGED[@]}" -eq 0 ]; then
  printf "\n${GREEN}${BOLD}No memory failures — all turns 2-4 scored ≥3/5${RESET}\n"
else
  printf "\n${RED}${BOLD}⚠  FLAGGED MEMORY FAILURES (turns 2-4, mem ≤2/5):${RESET}\n"
  for ft in "${FLAGGED[@]}"; do
    printf "  ${RED}• %s${RESET}\n" "$ft"
  done
fi

printf "\n  Completed: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"

} 2>&1 | tee "$LOGFILE"

printf "\n===LOG_PATH=== %s\n" "$LOGFILE" | tee -a "$LOGFILE"
