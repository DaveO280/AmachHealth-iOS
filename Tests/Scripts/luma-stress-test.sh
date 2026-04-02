#!/usr/bin/env bash
# luma-stress-test.sh — 50-query Luma AI stress test
# Tests system prompt additions: cite exact numbers + proactively surface anomalies
# Compares vs 30-query baseline run (stress-test-rerun-20260401-205557.log)

set -euo pipefail

API_URL="https://www.amachhealth.com/api/ai/chat"
TIMEOUT=600
PAUSE=2

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
MAGENTA='\033[0;35m'

ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }

declare -a RQ RS RL RDR RT RR RD RDU RM RV
PASS=0; FAIL=0; REGRESSION=0; IMPROVEMENT=0

# ─── Reusable context (matches TypeScript HealthContext interface) ─────────────
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
    { "marker": "Total Cholesterol", "value": 214, "unit": "mg/dL",   "date": "2025-11-15" },
    { "marker": "LDL",               "value": 138, "unit": "mg/dL",   "date": "2025-11-15" },
    { "marker": "HDL",               "value": 52,  "unit": "mg/dL",   "date": "2025-11-15" },
    { "marker": "Triglycerides",     "value": 118, "unit": "mg/dL",   "date": "2025-11-15" },
    { "marker": "Glucose",           "value": 94,  "unit": "mg/dL",   "date": "2025-11-15" },
    { "marker": "HbA1c",             "value": 5.4, "unit": "%",        "date": "2025-11-15" },
    { "marker": "Ferritin",          "value": 68,  "unit": "ng/mL",   "date": "2025-11-15" },
    { "marker": "Vitamin D",         "value": 31,  "unit": "ng/mL",   "date": "2025-11-15" },
    { "marker": "Testosterone",      "value": 520, "unit": "ng/dL",   "date": "2025-11-15" },
    { "marker": "TSH",               "value": 1.8, "unit": "mIU/L",   "date": "2025-11-15" },
    { "marker": "hsCRP",             "value": 1.2, "unit": "mg/L",    "date": "2025-11-15" },
    { "marker": "Homocysteine",      "value": 9.4, "unit": "μmol/L",  "date": "2025-11-15" }
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

# ─── Detection functions ──────────────────────────────────────────────────────
is_deflection() {
  local t; t=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  echo "$t" | grep -qE "i don.t have|try rephrasing|i.m processing|cannot provide|no data available|unable to access|don.t have access|i lack|can.t access|sync your|upload your|could you try|narrowing your"
}

has_data_refs() {
  echo "$1" | grep -qiE "41|44ms|63 bpm|64|138|52|214|42\.3|7200|8100|22ms|22,100|82 bpm|31 ng|68|520|9\.4|1\.2|march|2026|hrv|ldl|vo2|cholesterol|vitamin d|ferritin|testosterone|hscrp|homocysteine|sugarloaf|sore throat"
}

# Precision citation: exact payload figures with units/context
has_exact_citations() {
  local r="$1" hits=0
  echo "$r" | grep -qiE "138\s*mg|ldl.*138|138.*ldl"                  && (( hits++ )) || true
  echo "$r" | grep -qiE "22\s*ms|22ms|hrv.*22\b"                       && (( hits++ )) || true
  echo "$r" | grep -qiE "42\.3|vo2.*42\.3|42\.3.*vo2"                  && (( hits++ )) || true
  echo "$r" | grep -qiE "31\s*ng|vitamin.*d.*31|31.*vitamin"           && (( hits++ )) || true
  echo "$r" | grep -qiE "44\s*ms|44ms|hrv.*44|average.*44"             && (( hits++ )) || true
  echo "$r" | grep -qiE "63\s*bpm|resting.*63|63.*bpm"                 && (( hits++ )) || true
  echo "$r" | grep -qiE "7\.1\s*(h|hr|hour)|average.*7\.1|7\.1.*sleep" && (( hits++ )) || true
  echo "$r" | grep -qiE "4\.5\s*(h|hr|hour)|4\.5.*sleep|sleep.*4\.5"  && (( hits++ )) || true
  echo "$r" | grep -qiE "82\s*bpm|resting.*82|hr.*82"                  && (( hits++ )) || true
  echo "$r" | grep -qiE "68\s*ng|ferritin.*68|68.*ferritin"            && (( hits++ )) || true
  echo "$r" | grep -qiE "1\.2\s*mg|hscrp.*1\.2|crp.*1\.2"             && (( hits++ )) || true
  echo "$r" | grep -qiE "9\.4.*μ|homocysteine.*9\.4|9\.4.*homocysteine" && (( hits++ )) || true
  echo "$r" | grep -qiE "22,100|22100"                                  && (( hits++ )) || true
  echo "$r" | grep -qiE "8,100|8100"                                    && (( hits++ )) || true
  [ "$hits" -ge 2 ]
}

# Anomaly proactivity: named an anomaly without being directly asked about it
has_anomaly_proactivity() {
  local r="$1"
  echo "$r" | grep -qiE "(22ms|22 ms|hrv.*crash|crash.*hrv|hrv.*drop|drop.*hrv|82.*bpm|bpm.*82|4\.5.*h|h.*4\.5|short sleep|sleep.*anomal|anomal.*sleep|22,100|22100|march 17|sugarloaf)"
}

# ─── Scoring ──────────────────────────────────────────────────────────────────
score_relevance() {
  [ ${#2} -lt 100 ] && echo 1 && return
  is_deflection "$2" && echo 1 && return
  echo 3
}

score_depth() {
  local len=${#1}
  [ "$len" -lt 100 ] && echo 1 && return
  is_deflection "$1" && echo 1 && return
  local n; n=$(echo "$1" | grep -oE '[0-9]+\.?[0-9]*' | wc -l | tr -d ' ')
  if   [ "$n" -ge 6 ]; then echo 5
  elif [ "$n" -ge 3 ]; then echo 4
  elif [ "$n" -ge 1 ]; then echo 3
  else echo 2; fi
}

score_data_use() {
  local r="$1"
  is_deflection "$r" && echo 1 && return
  local h=0
  echo "$r" | grep -qi "138\|ldl.*138\|138.*ldl"         && (( h++ )) || true
  echo "$r" | grep -qi "22ms\|22 ms\|hrv.*22\b"          && (( h++ )) || true
  echo "$r" | grep -qi "42\.3\|vo2.*42"                  && (( h++ )) || true
  echo "$r" | grep -qi "31 ng\|31.*vitamin\|vitamin.*31" && (( h++ )) || true
  echo "$r" | grep -qi "march 1[5-9]\|march 2[0-9]\|march 30\|2026-03" && (( h++ )) || true
  echo "$r" | grep -qi "22,100\|22100\|sugarloaf"        && (( h++ )) || true
  echo "$r" | grep -qi "4,100\|4100.*steps"              && (( h++ )) || true
  echo "$r" | grep -qi "8,100\|8100\|7,200\|7200"        && (( h++ )) || true
  echo "$r" | grep -qi "ferritin.*68\|68.*ng"            && (( h++ )) || true
  echo "$r" | grep -qi "1\.2.*mg\|hscrp\|crp"           && (( h++ )) || true
  echo "$r" | grep -qi "9\.4\|homocysteine"              && (( h++ )) || true
  echo "$r" | grep -qi "4\.5.*h\|h.*4\.5\|short sleep"  && (( h++ )) || true
  echo "$r" | grep -qi "82.*bpm\|bpm.*82"                && (( h++ )) || true
  echo "$r" | grep -qi "44.*ms\|ms.*44\|average.*44"     && (( h++ )) || true
  echo "$r" | grep -qi "7\.1.*h\|average.*7\.1"          && (( h++ )) || true

  if   [ "$h" -ge 5 ]; then echo 5
  elif [ "$h" -ge 4 ]; then echo 4
  elif [ "$h" -ge 2 ]; then echo 3
  elif has_data_refs "$r"; then echo 2
  else echo 1; fi
}

score_memory() {
  local r="$1"
  is_deflection "$r" && echo 1 && return
  local c=0
  ( echo "$r" | grep -qi "ill\|sick\|sore throat\|run down" ) && \
    ( echo "$r" | grep -qi "hrv\|heart rate" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "vitamin d\|supplement" ) && \
    ( echo "$r" | grep -qi "31\|level\|ng\|deficien" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "sugarloaf\|hike\|22,100\|22100" ) && \
    ( echo "$r" | grep -qi "recover\|fatigue\|rest\|hrv" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "sleep" ) && \
    ( echo "$r" | grep -qi "energ\|tuesday\|wednesday\|work night" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "ldl\|cholesterol\|138" ) && \
    ( echo "$r" | grep -qi "risk\|cardio\|heart\|crp\|homocysteine" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "goal\|hrv.*55\|55.*hrv\|55\s*ms" ) && (( c++ )) || true
  ( echo "$r" | grep -qi "4\.5\|short sleep" ) && \
    ( echo "$r" | grep -qi "anomal\|flag\|crash\|debt\|consecutive" ) && (( c++ )) || true

  if   [ "$c" -ge 5 ]; then echo 5
  elif [ "$c" -ge 4 ]; then echo 4
  elif [ "$c" -ge 3 ]; then echo 3
  elif [ "$c" -ge 2 ]; then echo 2
  else echo 1; fi
}

verdict() {
  local avg; avg=$(python3 -c "print(int(($1+$2+$3+$4)/4.0+0.5))")
  if   [ "$avg" -ge 5 ]; then echo "Strong"
  elif [ "$avg" -ge 4 ]; then echo "Strong"
  elif [ "$avg" -ge 3 ]; then echo "Acceptable"
  else echo "Weak"; fi
}

# ─── Run a single query ───────────────────────────────────────────────────────
run_query() {
  local idx="$1" label="$2" query="$3" history="${4:-null}"
  local is_anomaly_test="${5:-no}"   # "yes" = grade anomaly proactivity
  local is_precision_test="${6:-no}" # "yes" = grade exact citation
  local baseline_du="${7:-}"         # prior data-use score for regression check

  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}Q${idx}:${RESET} ${label}"
  echo -e "${DIM}\"${query}\"${RESET}"
  [ "$is_anomaly_test" = "yes" ]   && echo -e "  ${MAGENTA}[ANOMALY PROACTIVITY TEST]${RESET}"
  [ "$is_precision_test" = "yes" ] && echo -e "  ${MAGENTA}[PRECISION CITATION TEST]${RESET}"
  echo ""

  local payload; payload=$(build_payload "$query" "$history")
  local t0; t0=$(ms_now)
  local tmp; tmp=$(mktemp)

  local http_code
  http_code=$(curl -s -w "%{http_code}" --max-time "$TIMEOUT" \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Origin: https://www.amachhealth.com" \
    -H "Referer: https://www.amachhealth.com/" \
    -d "$payload" -o "$tmp" 2>/dev/null) || { echo -e "${RED}CURL ERROR / TIMEOUT${RESET}"; http_code="000"; }

  local t1; t1=$(ms_now)
  local elapsed_s; elapsed_s=$(python3 -c "print('%.2f' % (($t1-$t0)/1000.0))")
  local raw; raw=$(cat "$tmp" 2>/dev/null || echo "")
  rm -f "$tmp"

  echo -e "${DIM}HTTP ${http_code} — ${elapsed_s}s${RESET}"

  local msg=""
  [ -n "$raw" ] && msg=$(echo "$raw" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if isinstance(d,dict):
        m=(d.get('content') or d.get('message') or d.get('response') or d.get('text') or '')
        if not m and 'choices' in d:
            m=d['choices'][0].get('message',{}).get('content','')
        print(m)
    else: print(str(d))
except: pass
" 2>/dev/null || echo "")
  [ -z "$msg" ] && msg="$raw"

  echo ""
  echo -e "${BOLD}Response:${RESET}"
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "$msg"
  echo "────────────────────────────────────────────────────────────────────────────"
  echo ""

  # ─── Pass/fail ────────────────────────────────────────────────────────────
  local status="PASS" notes="" len=${#msg}

  [ "$len" -ge 100 ] \
    && echo -e "  ${GREEN}✓${RESET} Length: ${len} chars" \
    || { echo -e "  ${RED}✗${RESET} Length: ${len} (<100)"; status="FAIL"; notes+="[short] "; }

  if is_deflection "$msg"; then
    echo -e "  ${RED}✗${RESET} Deflection"
    status="FAIL"; notes+="[deflect] "
  else
    echo -e "  ${GREEN}✓${RESET} No deflection"
  fi

  [ "$http_code" = "200" ] \
    && echo -e "  ${GREEN}✓${RESET} HTTP 200" \
    || { echo -e "  ${RED}✗${RESET} HTTP ${http_code}"; status="FAIL"; notes+="[http-${http_code}] "; }

  # Anomaly proactivity check
  if [ "$is_anomaly_test" = "yes" ]; then
    if has_anomaly_proactivity "$msg"; then
      echo -e "  ${GREEN}✓${RESET} Anomaly proactively surfaced"
    else
      echo -e "  ${RED}✗${RESET} Anomaly NOT surfaced — prompt instruction not firing"
      notes+="[no-anomaly] "
    fi
  fi

  # Precision citation check
  if [ "$is_precision_test" = "yes" ]; then
    if has_exact_citations "$msg"; then
      echo -e "  ${GREEN}✓${RESET} Exact values cited"
    else
      echo -e "  ${YELLOW}?${RESET} Exact citation unclear — check manually"
      notes+="[no-exact-cite] "
    fi
  fi

  # ─── 4-dimension scores ───────────────────────────────────────────────────
  local sr sd sdu sm verd
  sr=$(score_relevance "$query" "$msg")
  sd=$(score_depth "$msg")
  sdu=$(score_data_use "$msg")
  sm=$(score_memory "$msg")
  verd=$(verdict "$sr" "$sd" "$sdu" "$sm")

  echo ""
  echo -e "  ${BOLD}Scores:${RESET}  Rel ${sr}/5  Depth ${sd}/5  Data-use ${sdu}/5  Memory ${sm}/5  → ${BOLD}${verd}${RESET}"

  # Regression check
  if [ -n "$baseline_du" ]; then
    local reg_note=""
    if [ "$sdu" -gt "$baseline_du" ]; then
      reg_note="${GREEN}↑ IMPROVED data-use (was ${baseline_du}/5 → now ${sdu}/5)${RESET}"
      (( IMPROVEMENT++ )) || true
    elif [ "$sdu" -lt "$baseline_du" ]; then
      reg_note="${RED}↓ REGRESSION data-use (was ${baseline_du}/5 → now ${sdu}/5)${RESET}"
      (( REGRESSION++ )) || true
    else
      reg_note="${DIM}= same data-use as baseline (${sdu}/5)${RESET}"
    fi
    echo -e "  Baseline vs rerun: ${reg_note}"
  fi

  if [ "$status" = "PASS" ]; then
    echo -e "  ${GREEN}${BOLD}→ PASS${RESET}"
    (( PASS++ )) || true
  else
    echo -e "  ${RED}${BOLD}→ FAIL ${notes}${RESET}"
    (( FAIL++ )) || true
  fi

  local _dref="NO"; has_data_refs "$msg" && _dref="YES"
  RQ+=("$label"); RS+=("$status"); RL+=("$len"); RDR+=("$_dref")
  RT+=("${elapsed_s}s"); RR+=("$sr"); RD+=("$sd"); RDU+=("$sdu")
  RM+=("$sm"); RV+=("$verd")
}

print_table() {
  local from="${1:-0}" to="${2:-${#RQ[@]}}"
  printf "\n%-4s  %-36s  %-6s  %-7s  %-5s  %-5s  %-8s  %-6s  %-10s  %-7s\n" \
    "Q#" "Query" "Status" "Length" "Rel" "Depth" "Data-use" "Memory" "Verdict" "Time"
  printf "%-4s  %-36s  %-6s  %-7s  %-5s  %-5s  %-8s  %-6s  %-10s  %-7s\n" \
    "----" "------------------------------------" "------" "-------" "-----" "-----" "--------" "------" "----------" "-------"
  for (( i=from; i<to; i++ )); do
    local color="$GREEN"; [ "${RS[$i]}" = "FAIL" ] && color="$RED"
    printf "%-4s  %-36s  " "$((i+1))" "${RQ[$i]:0:36}"
    printf "${color}%-6s${RESET}  %-7s  %-5s  %-5s  %-8s  %-6s  %-10s  %-7s\n" \
      "${RS[$i]}" "${RL[$i]}" "${RR[$i]}/5" "${RD[$i]}/5" "${RDU[$i]}/5" \
      "${RM[$i]}/5" "${RV[$i]}" "${RT[$i]}"
  done
}

print_report_card() {
  local from="${1:-0}" to="${2:-${#RQ[@]}}"
  local n=$(( to - from )) sr=0 sd=0 sdu=0 sm=0
  for (( i=from; i<to; i++ )); do
    (( sr  += RR[$i]  )) || true
    (( sd  += RD[$i]  )) || true
    (( sdu += RDU[$i] )) || true
    (( sm  += RM[$i]  )) || true
  done
  python3 -c "
n=$n; sr=$sr; sd=$sd; sdu=$sdu; sm=$sm
print(f'  Relevance:         {sr/n:.2f}/5')
print(f'  Depth:             {sd/n:.2f}/5')
print(f'  Data use:          {sdu/n:.2f}/5  (baseline 30q: 3.43)')
print(f'  Memory/continuity: {sm/n:.2f}/5  (baseline 30q: 3.53)')
overall=(sr+sd+sdu+sm)/(n*4)
grade='A' if overall>=0.8 else ('B' if overall>=0.6 else ('C' if overall>=0.4 else 'D'))
print(f'  Overall:           {overall*5:.2f}/5  Grade: {grade}')
"
}

# ─── Header ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║    LUMA AI STRESS TEST — 50 QUERIES — amachhealth.com LIVE             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
echo -e "  Commit: ${CYAN}11f2e00${RESET} — cite exact values + surface anomalies proactively"
echo -e "  Target: ${CYAN}${API_URL}${RESET}"
echo -e "  Timeout: ${TIMEOUT}s | Pause: ${PAUSE}s | Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 1: CARRY-FORWARD RE-TESTS (Q1–2) ───────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 1 "Cross-source correlation (re-test)" \
  "Is there anything in my bloodwork that correlates with my energy dips on Tuesdays and Wednesdays?" \
  "null" "no" "yes" "3"
sleep $PAUSE

run_query 2 "60-day sleep trend (re-test)" \
  "Looking at my data from February 1 to April 1 — has my sleep quality been improving, stable, or getting worse? What's the most consistent pattern you see?" \
  "null" "no" "no" "1"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 2: PRECISION DATA-USE (Q3–10) ──────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 3 "Exact HRV vs 30-day average" \
  "What was my exact HRV reading most recently versus my 30-day average?" \
  "null" "no" "yes"
sleep $PAUSE

run_query 4 "Bloodwork out-of-range with exact numbers" \
  "Give me my top 3 bloodwork values that are outside the optimal reference range, with exact numbers." \
  "null" "no" "yes"
sleep $PAUSE

run_query 5 "Resting HR variance" \
  "What's the variance in my resting heart rate over the past 60 days — give me the actual numbers." \
  "null" "no" "yes"
sleep $PAUSE

run_query 6 "High-step days and next-day HRV" \
  "On the days my steps exceeded 12,000, what happened to my HRV the following morning? Give me specific numbers." \
  "null" "no" "yes"
sleep $PAUSE

run_query 7 "Sleep average with exact figure" \
  "What is my average sleep duration over the past 60 days — exact number please?" \
  "null" "no" "yes"
sleep $PAUSE

run_query 8 "VO2 max exact value and percentile" \
  "My VO2 max — what's the exact value and what percentile is that for a 44 year old male?" \
  "null" "no" "yes"
sleep $PAUSE

run_query 9 "Bloodwork panel exact values" \
  "Read back my full lipid panel with exact values — Total Cholesterol, LDL, HDL, Triglycerides." \
  "null" "no" "yes"
sleep $PAUSE

run_query 10 "Steps baseline and deviation" \
  "What is my daily steps baseline and by how much did March 30th deviate from it?" \
  "null" "no" "yes"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 3: ANOMALY PROACTIVITY (Q11–17) ────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 11 "Broad recovery question (anomaly test)" \
  "How's my overall recovery looking?" \
  "null" "yes" "no"
sleep $PAUSE

run_query 12 "How has my sleep been (anomaly test)" \
  "How has my sleep been lately?" \
  "null" "yes" "no"
sleep $PAUSE

run_query 13 "Any patterns worth knowing (anomaly test)" \
  "Any patterns in my data worth knowing about?" \
  "null" "yes" "no"
sleep $PAUSE

run_query 14 "General health check-in (anomaly test)" \
  "Just give me a quick health check-in — how am I doing overall?" \
  "null" "yes" "no"
sleep $PAUSE

run_query 15 "Recovery this week (anomaly test)" \
  "How is my recovery trending this week?" \
  "null" "yes" "no"
sleep $PAUSE

run_query 16 "Heart health overview (anomaly test)" \
  "Give me a heart health overview." \
  "null" "yes" "no"
sleep $PAUSE

run_query 17 "Anything I should act on today (anomaly test)" \
  "Is there anything in my data I should act on today?" \
  "null" "yes" "no"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 4: LONGITUDINAL AND COMPARATIVE (Q18–22) ───────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 18 "Cardiovascular markers now vs 6 weeks ago" \
  "Compare my cardiovascular markers now versus 6 weeks ago — what's changed?"
sleep $PAUSE

run_query 19 "Most improved metric over 60 days" \
  "Which metric has improved the most over the last 60 days?"
sleep $PAUSE

run_query 20 "Weight trend vs activity" \
  "Is my weight trend consistent with my activity level, or is there a mismatch?"
sleep $PAUSE

run_query 21 "HRV trend full date range" \
  "Walk me through my HRV trend from February 1 to April 1 — including any notable dips or spikes."
sleep $PAUSE

run_query 22 "Sleep architecture change over 60 days" \
  "Has my deep sleep or REM sleep changed meaningfully over the past 60 days?"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 5: BLOODWORK DEPTH (Q23–27) ────────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 23 "Full lipid panel walkthrough" \
  "Walk me through my lipid panel — Total Cholesterol 214, LDL 138, HDL 52, Triglycerides 118. What should I be focused on?"
sleep $PAUSE

run_query 24 "Ferritin in context of activity" \
  "My ferritin is 68 ng/mL — is that a concern given that I'm fairly active and targeting fat loss?"
sleep $PAUSE

run_query 25 "Bloodwork marker interactions" \
  "Which of my bloodwork markers interact with each other in ways I should know about — especially anything that compounds risk?"
sleep $PAUSE

run_query 26 "Vitamin D supplement progress" \
  "I started Vitamin D 2000 IU on March 28th. My level was 31 ng/mL at my November draw. What should I expect at my next test?"
sleep $PAUSE

run_query 27 "Homocysteine + cardiovascular context" \
  "My homocysteine is 9.4 μmol/L. How does that interact with my LDL of 138 and hsCRP of 1.2 from a cardiovascular risk standpoint?"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 6: GOAL ALIGNMENT (Q28–32) ─────────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 28 "On track for goals" \
  "Am I on track for my stated goals — HRV above 55ms, lose 3kg body fat, run 5k under 25 minutes — based on current trajectory?"
sleep $PAUSE

run_query 29 "Biggest gap to goals" \
  "What's the single biggest gap between where I am and where my goals say I should be?"
sleep $PAUSE

run_query 30 "Goal conflict check" \
  "Are any of my three goals in tension with each other — could pursuing one make another harder to achieve?"
sleep $PAUSE

run_query 31 "Timeline for 5k goal" \
  "Given my current VO2 max of 42.3 and exercise average of 28 minutes per day — how long will it realistically take to run a sub-25 minute 5k?"
sleep $PAUSE

run_query 32 "HRV 55ms gap analysis" \
  "I'm at 41ms HRV with a 44ms 7-day average. My goal is 55ms. What's the specific physiological gap and what closes it fastest?"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 7: EDGE CASES / STRESS (Q33–42) ────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 33 "Extremely broad: tell me everything" \
  "Tell me everything important about my health." \
  "null" "yes" "yes"
sleep $PAUSE

run_query 34 "Extremely narrow: single data point" \
  "What was my VO2 max estimate?" \
  "null" "no" "yes"
sleep $PAUSE

run_query 35 "Ambiguous: how am I doing" \
  "How am I doing?"
sleep $PAUSE

run_query 36 "Hypothetical: 6h sleep impact" \
  "If I cut my sleep to 6 hours per night consistently, what would you expect to see happen to my other metrics over the next 30 days?"
sleep $PAUSE

run_query 37 "No-data probe: blood pressure" \
  "What's my blood pressure trend looking like?" \
  "null" "no" "no"
sleep $PAUSE

run_query 38 "No-data probe: body composition" \
  "What does my body composition look like — body fat percentage, lean mass?" \
  "null" "no" "no"
sleep $PAUSE

run_query 39 "Multi-turn: follow up on bloodwork" \
  "You just told me my LDL is a concern. What's the earliest I could realistically expect to see it improve if I change my diet today?" \
  '[{"role":"user","content":"Walk me through my lipid panel."},{"role":"assistant","content":"Your LDL is 138 mg/dL — above the optimal threshold of 100 mg/dL. Combined with Total Cholesterol of 214 and hsCRP of 1.2 mg/L indicating low-grade inflammation, your cardiovascular load is elevated. HDL of 52 is adequate but not optimal. Triglycerides at 118 are within range. Focus: reduce saturated fat, add soluble fiber, and re-test in 3 months."}]'
sleep $PAUSE

run_query 40 "Multi-turn: follow up on HRV crash" \
  "Based on what you just explained about the March 17th crash — what would my training schedule have looked like if I had followed the correct protocol?" \
  '[{"role":"user","content":"What caused my HRV crash on March 17th?"},{"role":"assistant","content":"The HRV crash to 22ms on March 17th was your immune system under full load. You had reported feeling run down with a sore throat on March 15th. Two days in, the viral challenge peaked — your resting HR spiked to 82 bpm, 19 beats above your 63 bpm baseline. Your parasympathetic system was overridden. This was not a training-induced drop; it was a genuine illness response requiring full rest."}]'
sleep $PAUSE

run_query 41 "Contradictory data probe" \
  "My steps are declining but my exercise minutes are improving. How do you reconcile those two trends?"
sleep $PAUSE

run_query 42 "Supplement interaction check" \
  "I'm taking Vitamin D 2000 IU. Given my full bloodwork, are there any supplements that would be counterproductive or interact badly?"
sleep $PAUSE

# ════════════════════════════════════════════════════════════════════
echo -e "${BOLD}─── BLOCK 8: FINAL SYNTHESIS (Q43–50) ────────────────────────────────────${RESET}"
# ════════════════════════════════════════════════════════════════════

run_query 43 "Biggest single risk right now" \
  "What's the single biggest health risk in my data right now — considering both wearable metrics and bloodwork?"
sleep $PAUSE

run_query 44 "Best 3-day recovery protocol" \
  "Given that I've had 2 short sleep nights and my HRV is at 41ms — what's the optimal 3-day recovery protocol?"
sleep $PAUSE

run_query 45 "What to tell my doctor" \
  "I have a GP appointment next week. What are the 3 most important things from my data I should discuss?"
sleep $PAUSE

run_query 46 "Morning readiness score" \
  "Based on all my data — what would you rate my readiness for a hard workout this morning, and why?"
sleep $PAUSE

run_query 47 "Nutrition priorities from bloodwork" \
  "Looking only at my bloodwork, what are my top 3 nutrition priorities right now?"
sleep $PAUSE

run_query 48 "Stress vs recovery balance" \
  "Am I accumulating more stress than my body can recover from — what does the data say?"
sleep $PAUSE

run_query 49 "Explain my Tuesday/Wednesday pattern" \
  "Walk me through exactly why I'm low energy on Tuesdays and Wednesdays — use the specific numbers from my data to explain the mechanism."
sleep $PAUSE

run_query 50 "Full integrated health report" \
  "Give me a complete integrated health report — wearables, bloodwork, anomalies, goals, and your top 5 prioritized recommendations with specific numbers supporting each one." \
  "null" "yes" "yes"
sleep $PAUSE

# ─── Final summary ────────────────────────────────────────────────────────────
TOTAL=${#RQ[@]}
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║              FULL RESULTS — ALL ${TOTAL} QUERIES                              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"
print_table 0 $TOTAL

echo ""
echo -e "${BOLD}═══ REPORT CARD ═══${RESET}"
print_report_card 0 $TOTAL

# Anomaly proactivity summary (Q11–17 are anomaly tests = indices 10–16)
echo ""
echo -e "${BOLD}═══ ANOMALY PROACTIVITY (Q11–17) ═══${RESET}"
AP_PASS=0; AP_FAIL=0
for i in 10 11 12 13 14 15 16; do
  label="${RQ[$i]}"
  msg_idx=$i
  # Re-check from stored verdict (anomaly proactivity must be inferred from response stored above)
  echo -e "  Q$((i+1)) ${label}: ${RV[$i]}"
done

# Precision citation summary (Q3–10 = indices 2–9)
echo ""
echo -e "${BOLD}═══ PRECISION CITATION (Q3–10) ═══${RESET}"
for i in 2 3 4 5 6 7 8 9; do
  echo -e "  Q$((i+1)) ${RQ[$i]}: Data-use ${RDU[$i]}/5 — ${RV[$i]}"
done

# Regression summary
echo ""
echo -e "${BOLD}═══ REGRESSION vs 30-QUERY BASELINE ═══${RESET}"
echo -e "  Q1 (Cross-source correlation): Data-use ${RDU[0]}/5  (baseline: 3/5)"
echo -e "  Q2 (60-day sleep trend):       Data-use ${RDU[1]}/5  (baseline: 1/5)"
[ "$REGRESSION" -gt 0 ] \
  && echo -e "  ${RED}${REGRESSION} regressions detected${RESET}" \
  || echo -e "  ${GREEN}No regressions${RESET}"
[ "$IMPROVEMENT" -gt 0 ] \
  && echo -e "  ${GREEN}${IMPROVEMENT} improvements vs baseline${RESET}"

echo ""
echo -e "  ${BOLD}Pass/Fail: ${GREEN}${PASS} PASS${RESET} / ${RED}${FAIL} FAIL${RESET} out of ${TOTAL} queries"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}ALL QUERIES PASSED ✓${RESET}"
elif [ "$FAIL" -le 5 ]; then
  echo -e "  ${YELLOW}${BOLD}MOSTLY PASSING — ${FAIL} failures to review${RESET}"
else
  echo -e "  ${RED}${BOLD}SIGNIFICANT FAILURES — ${FAIL}/${TOTAL} failed${RESET}"
fi
echo ""
echo -e "  Completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
