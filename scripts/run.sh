#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Lux in Tenebris V2 — Orchestrator Script (v2.2)
# Each step is isolated, stateless, communicates via JSON files.
# Features:
#   - Scouts run SEQUENTIALLY (one at a time) — the inference server is a
#     single self-hosted box and can't take concurrent agent sessions
#   - Every LLM call is wrapped in a timeout; nothing can hang forever
#   - 4h master timeout for the whole pipeline
#   - Auto-skip image gen when xAI credits exhausted
#   - Auto-skip podcast pill when xAI TTS unavailable (checked independently)
#   - Falls back to partial deploy if any non-critical step fails
#   - Single edition (the K3 second edition was removed 2026-07-28)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Machine-specific config ─────────────────────────────────────
# Everything below is either self-located (works regardless of where the
# repo is cloned or how it's symlinked in) or overridable via env var, with
# defaults that match the original operator's setup so nothing changes for
# an existing install. Set LUX_* env vars (e.g. in the untracked script that
# actually launches cron — see docs/SETUP.md) to point this at a different
# profile/layout.
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"          # this script's own directory
PIPELINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" # repo root, one level up

PROFILE="${LUX_PROFILE:-luke}"
V2_DIR="/tmp/v2"
LOG_DIR="$V2_DIR/logs"
SCOUTS_DIR="$V2_DIR/scouts"
IMAGES_DIR="$V2_DIR/images"
OUTPUT_DIR="$V2_DIR/output"
HERMES_BIN="${LUX_HERMES_BIN:-$HOME/.local/bin/hermes}"
RENDER_PY="$SCRIPT_DIR/core/render.py"
CLEANUP_SH="$V2_DIR/cleanup.sh"
DEPLOY_DIR="${LUX_DEPLOY_DIR:-$HOME/ai-news-deploy}"
# Scouts run ONE AT A TIME (see step 2) against a single self-hosted
# inference server, so these budgets are per-scout wall clock with the whole
# server to itself, and the master budget has to cover their sum, not their max.
#
# Measured on the first fully-sequential run (2026-07-29, all 9 scouts green):
#   x 7m17 · research 7m01 · official 12m12 · opensource 12m57 · tools 10m17
#   funding 13m33 · hardware 10m33 · youtube 0m58 · italia ~13m  → ~87 min total
# Five of nine exceeded 10 min, which is why the old 600s ceiling killed every
# scout. Slowest is ~13.5 min, so 20 min leaves real headroom.
TIMEOUT_SECS=1200       # 20 min per scout
STEP_TIMEOUT_SECS=1200  # 20 min for the italia scout
# The editor gets its own, larger budget: it is the only FATAL step (no
# edition.json ⇒ no newspaper at all) and it chews through 9 scout files
# (~80 items) with cross-day dedup against headlines_history.json. On
# 2026-07-29 it hit the 20-min ceiling at 08:17:48 to the second and killed
# the run before render/images/podcast/deploy; a manual re-run right after
# completed in ~11 min, so the ceiling — not the work — was the problem.
EDITOR_TIMEOUT_SECS=2400 # 40 min
MEDIA_TIMEOUT_SECS=900   # 15 min for image gen / podcast (xAI-bound, not localAIServer)
MASTER_TIMEOUT=14400     # 4h for the entire pipeline. Budget check against the
                         # measured run: 87 (scouts) + 40 (editor) + 15 + 15
                         # (media) + ~10 (wire) ≈ 2h50m, comfortably inside.
TEMPLATE_DIR="$PIPELINE_ROOT/template"

# ╔════════════════════════════════════════════════════════════════════════╗
# ║ PIPELINE_PROVIDER — DO NOT CHANGE without the user explicitly          ║
# ║ asking for it, in this exact conversation, for this exact reason.      ║
# ║                                                                        ║
# ║ This must always be "localAIServer" (the user's friend's dedicated     ║
# ║ LiteLLM server), never "openrouter" or anything else — regardless of   ║
# ║ what model/provider the *interactive* Hermes session reasoning about   ║
# ║ this fix happens to be running on. The user uses openrouter for        ║
# ║ their own chats; the pipeline's own steps must not follow that.        ║
# ║                                                                        ║
# ║ Incident (2026-07-27/28): asked to raise the scout timeout, an         ║
# ║ interactive session swapped every "--provider localAIServer" in this   ║
# ║ file to "--provider openrouter" — unrequested, unnoticed until the     ║
# ║ user asked why. openrouter is a paid, metered service, separate from   ║
# ║ the friend's server, with a different cost profile.                   ║
# ╚════════════════════════════════════════════════════════════════════════╝
PIPELINE_PROVIDER="localAIServer"

# Model for every LLM step (scouts, editor, image-gen, podcast-pill, wire
# articles) — was hardcoded separately in each of the 7 call sites below;
# centralized here so it's a one-line change instead of a find-and-replace.
PIPELINE_MODEL="Qwen3.8-Flash-Next"

# ── Setup ────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$SCOUTS_DIR" "$IMAGES_DIR" "$OUTPUT_DIR"
TODAY=$(date +%Y-%m-%d)
LOGFILE="$LOG_DIR/run_${TODAY}.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ── Per-step logs: APPEND, never truncate ───────────────────
# These logs used to be opened with '>', so a manual re-run of a step wiped
# the evidence of why the automated one had failed. That happened for real on
# 2026-07-29: the editor was killed by its timeout, the recovery re-run
# overwrote editor_<date>.log, and the failure became undiagnosable. Every
# per-step log is now opened with '>>' and preceded by this banner, so a day's
# attempts stack up in order instead of erasing each other.
log_attempt() {
    local logfile="$1" label="$2"
    {
        echo ""
        echo "───────────────────────────────────────────────"
        echo "▶ $label — $(date '+%Y-%m-%d %H:%M:%S') (pid $$)"
        echo "───────────────────────────────────────────────"
    } >>"$logfile"
}

# Print only the MOST RECENT attempt from an appended log.
# The credit checks below grep these logs to decide whether to skip a step.
# With append-mode logs a stale error from an earlier attempt the same day
# would otherwise stick forever — e.g. hit the xAI spending limit at 06:40,
# top the credits up, and every later attempt that day would still skip.
# Reading only the last banner-delimited block keeps the original "look at
# what happened last time" semantics while preserving the full history.
last_attempt() {
    local logfile="$1"
    [ -f "$logfile" ] || return 0
    awk '/^▶ /{buf=""} {buf = buf $0 "\n"} END{printf "%s", buf}' "$logfile"
}

# ── Telegram progress notifications ──────────────────────────
# The run is fire-and-forget in the background: until now the only thing that
# ever reached Telegram was the wrapper's "pipeline launched" line at 06:30,
# leaving two hours of silence and no word at all when something broke.
#
# notify() posts one short line at each real milestone. Written to be
# impossible to break the run:
#   - every failure path returns 0 (missing .env, empty creds, no network)
#   - curl has a hard 10s timeout, so it can never hang the pipeline
#   - output is discarded; the bot token must never reach the run log, which
#     is tee'd to disk and committed nowhere but still readable
TG_ENV="${LUX_TG_ENV:-$HOME/.hermes/profiles/$PROFILE/.env}"
notify() {
    local text="$1" tok chat
    [ -f "$TG_ENV" ] || return 0
    tok=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$TG_ENV" 2>/dev/null | cut -d= -f2- || true)
    chat=$(grep -m1 '^TELEGRAM_HOME_CHANNEL=' "$TG_ENV" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$tok" ] && [ -n "$chat" ] || return 0
    curl -s -o /dev/null --max-time 10 \
        -X POST "https://api.telegram.org/bot${tok}/sendMessage" \
        -d "chat_id=${chat}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || true
    return 0
}

# Master watchdog — if we exceed MASTER_TIMEOUT, kill everything
START_EPOCH=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_EPOCH )); }
check_timeout() {
    if [ "$(elapsed)" -gt "$MASTER_TIMEOUT" ]; then
        echo "⛔ MASTER TIMEOUT after $(elapsed)s — aborting pipeline"
        notify "⛔ Lux — master timeout after $(( $(elapsed) / 60 ))m. Run aborted, no issue today."
        exit 2
    fi
}

echo "═══════════════════════════════════════════════"
echo "LUX IN TENEBRIS V2 — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════"

# ── Step 0: Cleanup ─────────────────────────────────────────
echo "[step 0] cleanup..."
if [ -f "$CLEANUP_SH" ]; then
    bash "$CLEANUP_SH"
else
    find "$SCOUTS_DIR" -name 'scout_*.json' -delete 2>/dev/null || true
    find "$IMAGES_DIR" -type f -delete 2>/dev/null || true
    [ -f "$V2_DIR/edition.json" ] && rm -f "$V2_DIR/edition.json"
fi
echo "  ✓ cleanup done"

# ── Step 1: Metadata ────────────────────────────────────────
echo "[step 1] metadata..."
YESTERDAY=$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=1)).isoformat())")
TODAY_HUMAN=$(python3 -c "import datetime; print(datetime.date.today().strftime('%B %d, %Y'))")
cat > "$SCOUTS_DIR/_metadata.json" <<EOF
{"today":"$TODAY","yesterday":"$YESTERDAY","today_human":"$TODAY_HUMAN"}
EOF
echo "  ✓ window: $YESTERDAY → $TODAY"

# ── Step 1b: Sync deploy dir, resolve issue number, archive predecessor ──
# Done early (the editor needs the issue number) and against a freshly
# git-reset deploy dir, so it's immune to local leftovers from a crashed
# run. Incident that motivated this (2026-07-27): a run crashed after
# bumping $DEPLOY_DIR/.issue locally but before pushing;
# the recovery re-run read that unpushed leftover value and bumped again,
# silently skipping issue #31. Reading the issue/date from the *live*
# index.html's own masthead instead of the .issue file (which can go
# stale — same incident window also left edition.json two issues behind)
# fixes that: it always reflects the last truly-published state.
echo "[step 1b] sync deploy dir + issue number..."
mkdir -p "$DEPLOY_DIR"
(cd "$DEPLOY_DIR" && git fetch origin --quiet 2>/dev/null && git reset --hard origin/main --quiet 2>/dev/null) || true

PREV_ISSUE=0
PREV_DATE=""
if [ -f "$DEPLOY_DIR/index.html" ]; then
    ISSUE_DATE_LINE=$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/core')
import archive_issue as ai
no = ai.extract_issue_no('$DEPLOY_DIR/index.html') or 0
date = ai.extract_issue_date('$DEPLOY_DIR/index.html')
print(f'{no} {date}')
" 2>/dev/null || echo "0 ")
    PREV_ISSUE=$(echo "$ISSUE_DATE_LINE" | awk '{print $1}')
    PREV_DATE=$(echo "$ISSUE_DATE_LINE" | awk '{print $2}')
fi
PREV_ISSUE="${PREV_ISSUE:-0}"

if [ "$PREV_DATE" = "$TODAY" ]; then
    echo "  → live edition is already dated $TODAY (same-day re-run) — reusing issue #$PREV_ISSUE"
    NEXT_ISSUE=$PREV_ISSUE
else
    NEXT_ISSUE=$((PREV_ISSUE + 1))
    # Archive whatever's currently live BEFORE today's run overwrites it.
    # This guarantees every published edition gets archived at the latest
    # by the next day's run, even if that edition's own run never reached
    # its own deploy/archive step (as happened to the 2026-07-26 edition).
    ARCHIVE_SCRIPT="$SCRIPT_DIR/core/archive_issue.py"
    if [ -f "$ARCHIVE_SCRIPT" ] && [ -f "$DEPLOY_DIR/index.html" ]; then
        python3 "$ARCHIVE_SCRIPT" "$DEPLOY_DIR" 2>>"$LOGFILE" \
            && echo "  ✓ archived previous issue (#$PREV_ISSUE, $PREV_DATE)" \
            || echo "  ⚠ archiving previous issue failed (non-fatal)"
    fi
fi
echo "$NEXT_ISSUE" > "$V2_DIR/.issue"
echo "  ✓ issue #$NEXT_ISSUE"
notify "▶ Lux #$NEXT_ISSUE — run started $(date '+%H:%M'). Nine scouts, one at a time; expect ~2h."
check_timeout

# ── Helper: run a scout with safe timeout ──────────────────
# Runs one scout to completion, then validates its output file. If the
# timeout fires, write_file may never have run — so we check, and write an
# empty [] fallback here so downstream steps always have valid JSON.
# CRITICAL: '|| true' prevents set -e from aborting the whole pipeline
# when timeout returns non-zero (exit code 124).
run_scout() {
    local name="$1"
    local skill="$2"
    local toolsets="$3"
    local prompt="$4"
    local outfile="$SCOUTS_DIR/scout_${name}.json"
    
    echo "  → starting scout $name ($skill)"
    log_attempt "$LOG_DIR/scout_${name}_${TODAY}.out" "scout $name"
    log_attempt "$LOG_DIR/scout_${name}_${TODAY}.err" "scout $name"
    timeout "$TIMEOUT_SECS" "$HERMES_BIN" chat -q "$prompt" \
        --profile "$PROFILE" \
        -s "$skill" \
        -t "$toolsets" \
        -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" \
        -Q --yolo \
        2>>"$LOG_DIR/scout_${name}_${TODAY}.err" \
        >>"$LOG_DIR/scout_${name}_${TODAY}.out" || true
    
    # Validate output
    if [ -f "$outfile" ] && python3 -c "import json; json.load(open('$outfile'))" 2>/dev/null 2>&1; then
        local count=0
        count=$(python3 -c "import json; d=json.load(open('$outfile')); print(len(d) if isinstance(d, list) else len(d.get('editorial',[])))" 2>/dev/null || echo "0")
        echo "  ✓ scout $name done ($count items)"
    else
        echo "  ✗ scout $name FAILED or TIMEOUT — writing empty fallback"
        echo "[]" > "$outfile"
    fi
    check_timeout
}

SCOUT_DATE_BRIEF="Window: from $YESTERDAY to $TODAY. Today is $TODAY, yesterday is $YESTERDAY."

# ── Step 2: Scouts ───────────────────────────────────────────
# SEQUENTIAL, one scout at a time. Each gets the whole inference server to
# itself and its own timeout; a failure only ever costs that one scout, which
# falls back to [] and never blocks the pipeline.
#
# Why not parallel (changed 2026-07-28): scouts used to run 3-up in phases.
# That works against a distributed API, but `localAIServer` is a single self-hosted
# box serving these models — and a "scout" is not one request, it's a whole
# multi-turn agent session (searches, tool calls, reasoning). Three of those
# at once saturate the machine and all three crawl. Evidence from the logs on
# 2026-07-26/27/28: every 3-up phase ran exactly to the per-scout ceiling and
# got killed — 0 scouts completed across those runs. The same scouts against
# a distributed provider finished a whole phase in 4.7-6.7 min. Serialising
# trades wall clock (which is free here: this is a fire-and-forget 06:30 cron)
# for actually finishing.
echo "[step 2] scouts (sequential, one at a time)..."

run_scout "x" "scout-x" "x_search,file,terminal" \
    "You are the X Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-x and follow it exactly. Use from_date=$YESTERDAY to_date=$TODAY in x_search calls.
Write the JSON array to $SCOUTS_DIR/scout_x.json using write_file. ENGLISH ONLY."

run_scout "research" "scout-research" "web,file,terminal" \
    "You are the Research Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-research and follow it exactly. Search arXiv and HuggingFace daily papers.
Write the JSON array to $SCOUTS_DIR/scout_research.json using write_file. ENGLISH ONLY."

run_scout "official" "scout-official" "web,file,terminal" \
    "You are the Official Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-official and follow it exactly. Scrape official AI lab blogs.
Write the JSON array to $SCOUTS_DIR/scout_official.json using write_file. ENGLISH ONLY."

run_scout "opensource" "scout-opensource" "web,x_search,file,terminal" \
    "You are the Open Source Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-opensource and follow it exactly. Search GitHub Trending and HuggingFace Trending.
Write the JSON object (with editorial array + trending object) to $SCOUTS_DIR/scout_opensource.json using write_file. ENGLISH ONLY."

run_scout "tools" "scout-tools" "web,file,terminal" \
    "You are the Tools Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-tools and follow it exactly. Search Product Hunt, Hacker News, tool launches.
Write the JSON array to $SCOUTS_DIR/scout_tools.json using write_file. ENGLISH ONLY."

run_scout "funding" "scout-funding" "web,file,terminal" \
    "You are the Funding Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-funding and follow it exactly. Search TechCrunch, Crunchbase for AI funding.
Write the JSON array to $SCOUTS_DIR/scout_funding.json using write_file. ENGLISH ONLY."

# ── Trending fallback: if opensource scout failed, fetch via curl ──
TRENDING_FALLBACK="$SCRIPT_DIR/content/fetch_trending.py"
if [ -f "$TRENDING_FALLBACK" ]; then
    SCOUT_OS="$SCOUTS_DIR/scout_opensource.json"
    has_trending=$(python3 -c "
import json
try:
    d = json.load(open('$SCOUT_OS'))
    if isinstance(d, dict):
        gh = len(d.get('trending',{}).get('github',{}).get('items',[]))
        hf = len(d.get('trending',{}).get('huggingface',{}).get('items',[]))
        print(gh + hf)
    else:
        print(0)
except: print(0)
" 2>/dev/null || echo "0")
    if [ "$has_trending" -lt 3 ]; then
        echo "  → trending data missing (${has_trending} items), fetching via curl fallback..."
        TMP_TRENDING=$(mktemp)
        python3 "$TRENDING_FALLBACK" --output-json "$TMP_TRENDING" 2>>"$LOGFILE" || true
        if [ -f "$TMP_TRENDING" ] && python3 -c "import json; json.load(open('$TMP_TRENDING'))" 2>/dev/null 2>&1; then
            python3 -c "
import json
try:
    # Read existing scout file (may be [] or {editorial:..., trending:...})
    with open('$SCOUT_OS') as f:
        existing = json.load(f)
    if not isinstance(existing, dict):
        existing = {'editorial': []}
    # Read trending data
    with open('$TMP_TRENDING') as f:
        trending_data = json.load(f)
    existing['trending'] = trending_data.get('trending', {})
    with open('$SCOUT_OS', 'w') as f:
        json.dump(existing, f, indent=2)
    gh = len(existing['trending'].get('github',{}).get('items',[]))
    hf = len(existing['trending'].get('huggingface',{}).get('items',[]))
    print(f'  ✓ trending fallback: {gh} GitHub + {hf} HF items written')
except Exception as e:
    print(f'  ⚠ trending fallback failed: {e}')
" 2>>"$LOGFILE" || true
            rm -f "$TMP_TRENDING"
        else
            echo "  ⚠ trending fallback fetch failed"
            rm -f "$TMP_TRENDING"
        fi
    fi
fi

run_scout "hardware" "scout-hardware" "web,x_search,file,terminal" \
    "You are the Hardware Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-hardware and follow it exactly. Search for robots, chips, datacenter hardware news.
Write the JSON array to $SCOUTS_DIR/scout_hardware.json using write_file. ENGLISH ONLY."

# --- YouTube: Python fetch, then LLM extraction over the fetched data ---
echo "[step 2] scout youtube..."
echo "  → running youtube_scout.py (Python fetch)..."
python3 "$SCRIPT_DIR/content/youtube_scout.py" --max 10 2>>"$LOGFILE" || echo "  ⚠ youtube scout fetch failed (non-fatal)"
echo "  ✓ youtube_scout.py done"

echo "  → running scout-youtube..."
log_attempt "$LOG_DIR/scout_youtube_${TODAY}.log" "scout youtube"
timeout "$TIMEOUT_SECS" "$HERMES_BIN" chat -q 'Load scout-youtube skill. Read /tmp/v2/scouts/scout_youtube_raw.json.
Extract newsworthy items from the video data.
Write the JSON array to /tmp/v2/scouts/scout_youtube.json using write_file.
ENGLISH ONLY. Today is '"$TODAY"' ('"$TODAY_HUMAN"'). Window: '"$YESTERDAY"' to '"$TODAY"'."' \
    --profile "$PROFILE" -s scout-youtube -t file \
    -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" \
    -Q --yolo >>"$LOG_DIR/scout_youtube_${TODAY}.log" 2>&1 || true
echo "  ✓ youtube scout done"
check_timeout

# --- Italia AI Spotlight ---
echo "[step 2] scout italia..."
log_attempt "$LOG_DIR/scout_italia_${TODAY}.log" "scout italia"
timeout "$STEP_TIMEOUT_SECS" "$HERMES_BIN" chat -q "You are the Italia AI Spotlight Scout for Lux in Tenebris. $SCOUT_DATE_BRIEF
Load skill scout-italia and follow it exactly. Fetch AI4Business RSS, search web for Italian AI news.
Write the JSON array to $SCOUTS_DIR/scout_italia.json using write_file.
All titles in ENGLISH, links to Italian sources. ENGLISH ONLY." \
    --profile "$PROFILE" -s scout-italia -t web,file,terminal -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" -Q --yolo \
    >>"$LOG_DIR/scout_italia_${TODAY}.log" 2>&1 || true
echo "  ✓ italia scout done"
check_timeout

# ── Step 3: Validate all scout files ────────────────────────
echo "[step 3] validating scout files..."
SCOUT_COUNT=0
SCOUT_NAMES="x research official opensource tools funding hardware youtube italia"
for scout in $SCOUT_NAMES; do
    f="$SCOUTS_DIR/scout_${scout}.json"
    if [ -f "$f" ] && python3 -c "import json; json.load(open('$f'))" 2>/dev/null 2>&1; then
        SCOUT_COUNT=$((SCOUT_COUNT + 1))
    else
        echo "  ✗ missing/invalid: scout_${scout}.json — writing empty"
        echo "[]" > "$f"
        SCOUT_COUNT=$((SCOUT_COUNT + 1))
    fi
done
echo "  ✓ $SCOUT_COUNT/9 scout files ready"

# Milestone: the scouts are the long stretch (~90 min of the ~2h). Report what
# actually landed on the desk, and name any scout that came back empty — a
# timed-out scout is survivable but worth knowing about before the paper lands.
DESK_ITEMS=$(python3 -c "
import json, os
keys = 'x research official opensource tools funding hardware youtube italia'.split()
t = 0
for k in keys:
    try:
        d = json.load(open(os.path.join('$SCOUTS_DIR', 'scout_%s.json' % k)))
        t += len(d) if isinstance(d, list) else len(d.get('editorial') or [])
    except Exception:
        pass
print(t)
" 2>/dev/null || echo "?")
EMPTY_SCOUTS=$(grep -c "✗ scout .* FAILED or TIMEOUT" "$LOGFILE" 2>/dev/null || echo 0)
if [ "${EMPTY_SCOUTS:-0}" -gt 0 ]; then
    notify "🔍 Lux #$NEXT_ISSUE — scouts done, $DESK_ITEMS items on the desk. ⚠ $EMPTY_SCOUTS scout(s) timed out and came back empty. Editor starting."
else
    notify "🔍 Lux #$NEXT_ISSUE — scouts done, all nine green, $DESK_ITEMS items on the desk. Editor starting."
fi
check_timeout

# ── Step 3b: Free models fetch ──────────────────────────────
# Deterministic, no LLM: currently-free models on OpenRouter + OpenCode Zen.
# Not one of the 9 scouts — writes straight to $V2_DIR/free_models.json,
# which the editor passes through unchanged (see editor SKILL.md step 3b).
# Non-fatal: if this fails or the script is missing, the editor just won't
# find the file and the Free Models section is skipped for the day.
echo "[step 3b] free models (OpenRouter + OpenCode Zen)..."
FREE_MODELS_SCRIPT="$SCRIPT_DIR/content/fetch_free_models.py"
if [ -f "$FREE_MODELS_SCRIPT" ]; then
    python3 "$FREE_MODELS_SCRIPT" --output-json "$V2_DIR/free_models.json" 2>>"$LOGFILE" \
        && echo "  ✓ free_models.json written" \
        || echo "  ⚠ free models fetch failed (non-fatal, section skipped today)"
else
    echo "  - fetch_free_models.py not found, skipping"
fi
check_timeout

# ── Step 4: Editor ──────────────────────────────────────────
echo "[step 4] editor..."
# NEXT_ISSUE was already resolved in step 1b (reuse-if-same-day-rerun,
# increment-and-archive-predecessor otherwise).

log_attempt "$LOG_DIR/editor_${TODAY}.log" "editor (timeout ${EDITOR_TIMEOUT_SECS}s)"
timeout "$EDITOR_TIMEOUT_SECS" "$HERMES_BIN" chat -q "You are the Editor for Lux in Tenebris. Load skill editor and follow it exactly.
Today is $TODAY. Issue #$NEXT_ISSUE.
Read all scout JSON files from $SCOUTS_DIR/scout_*.json and the metadata.
For cross-day dedup, read $DEPLOY_DIR/headlines_history.json via read_file.
If $V2_DIR/free_models.json exists, read it and pass its content through unchanged into the free_models key (see skill step 3b) — skip the key entirely if the file is missing.
Assemble edition.json following the skill instructions.
Write the result to $V2_DIR/edition.json using write_file. ENGLISH ONLY." \
    --profile "$PROFILE" -s editor -t file -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" -Q --yolo \
    >>"$LOG_DIR/editor_${TODAY}.log" 2>&1 && EDITOR_RC=0 || EDITOR_RC=$?

if [ -f "$V2_DIR/edition.json" ] && python3 -c "import json; json.load(open('$V2_DIR/edition.json'))" 2>/dev/null 2>&1; then
    echo "  ✓ edition.json written"
    ED_KEPT=$(python3 -c "
import json
d = json.load(open('$V2_DIR/edition.json'))
print((1 if d.get('lead') else 0)
      + len(d.get('top_stories') or [])
      + sum(len(s.get('items') or []) for s in (d.get('sections') or []))
      + len(d.get('quick_hits') or []))
" 2>/dev/null || echo "?")
    ED_LEAD=$(python3 -c "
import json
print((json.load(open('$V2_DIR/edition.json')).get('lead') or {}).get('title','')[:90])
" 2>/dev/null || echo "")
    notify "✍️ Lux #$NEXT_ISSUE — edition assembled. $ED_KEPT kept of $DESK_ITEMS. Lead: ${ED_LEAD:-—}"
else
    # Say WHICH failure it was. `timeout` returns 124 when it kills the child,
    # and that distinction is the whole diagnosis: 124 means raise
    # EDITOR_TIMEOUT_SECS, anything else means the editor itself broke.
    if [ "$EDITOR_RC" -eq 124 ]; then
        echo "  ✗ editor KILLED by timeout after ${EDITOR_TIMEOUT_SECS}s — it never finished writing edition.json"
        echo "     → if this recurs, raise EDITOR_TIMEOUT_SECS at the top of this script"
    else
        echo "  ✗ editor exited with code $EDITOR_RC and left no valid edition.json"
    fi
    echo "     → see $LOG_DIR/editor_${TODAY}.log (appended, not overwritten)"
    echo "FATAL: editor failed"
    # The one message that matters most: this is the only step whose failure
    # means no paper at all, and until now it failed in complete silence.
    if [ "$EDITOR_RC" -eq 124 ]; then
        notify "⛔ Lux #$NEXT_ISSUE — EDITOR TIMED OUT after $((EDITOR_TIMEOUT_SECS / 60))m. No issue today. The $DESK_ITEMS scouted items are still on disk; a re-run can use them."
    else
        notify "⛔ Lux #$NEXT_ISSUE — EDITOR FAILED (exit $EDITOR_RC). No issue today. Check editor_${TODAY}.log."
    fi
    exit 1
fi
check_timeout

# ── Step 5: Image Gen (with pre-check for xAI credits) ──────
echo "[step 5] image gen..."
SKIP_IMAGES=false

# Check if xAI credits are available before even launching the agent
if last_attempt "$LOG_DIR/imagegen_${TODAY}.log" | grep -q "personal-team-blocked:spending-limit"; then
    SKIP_IMAGES=true
fi

if [ "$SKIP_IMAGES" = false ]; then
    log_attempt "$LOG_DIR/imagegen_${TODAY}.log" "image gen"
    timeout "$MEDIA_TIMEOUT_SECS" "$HERMES_BIN" chat -q "You are the Image Generator for Lux in Tenebris. Load skill image-gen.
Today is $TODAY. Read $V2_DIR/edition.json.
Generate images for lead + each non-empty section using image_generate tool.
Save images to $V2_DIR/images/. Update edition.json. ENGLISH ONLY." \
        --profile "$PROFILE" -s image-gen -t file,image_gen,terminal -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" -Q --yolo \
        >>"$LOG_DIR/imagegen_${TODAY}.log" 2>&1 || true
fi

# Check if it failed due to credits
if last_attempt "$LOG_DIR/imagegen_${TODAY}.log" | grep -q "spending-limit\|credits exhausted\|403"; then
    echo "  ⚠ xAI credits exhausted — will skip images for next runs too"
    SKIP_IMAGES=true
fi

echo "  ✓ image gen complete ($([ "$SKIP_IMAGES" = true ] && echo 'skipped - no credits' || echo 'done'))"
check_timeout

# ── Step 6: Render HTML ─────────────────────────────────────
echo "[step 6] render..."
if [ -f "$RENDER_PY" ] && [ -f "$V2_DIR/edition.json" ]; then
    python3 "$RENDER_PY" "$V2_DIR/edition.json" "$OUTPUT_DIR/index.html" --templates "$TEMPLATE_DIR" 2>>"$LOGFILE"
    echo "  ✓ rendered → $OUTPUT_DIR/index.html"
else
    echo "  ✗ render.py or edition.json missing"
    exit 1
fi

# The K3 "The Lens" second edition was fully removed on 2026-07-28 (it had
# been render-disabled since 07-25 but its editor and wire steps still ran
# daily, burning LLM calls for output nothing read). Single DS edition only.
# Nothing here renders a k3/ page any more, and the version-selector badge
# went with it — there is no second version to select.

# ── Step 7: Podcast Pill ─────────────────────────────────────
echo "[step 7] podcast pill..."
SKIP_PODCAST=false

# TTS (Castor/Luna) shares the xAI account with image gen but does NOT always
# fail on the same day image gen does — e.g. Jul 14 and Jul 24 both had 0
# images yet a working podcast. So this gets its own credit check on its own
# log instead of inheriting SKIP_IMAGES (which used to skip the attempt
# entirely whenever images failed, even on days podcast would have worked).
if last_attempt "$LOG_DIR/podcast_${TODAY}.log" | grep -q "personal-team-blocked:spending-limit"; then
    SKIP_PODCAST=true
fi

if [ "$SKIP_PODCAST" = false ]; then
    PODCAST_INJECT="$SCRIPT_DIR/inject/inject_podcast_pill.py"
    mkdir -p "$V2_DIR/podcasts"
    
    log_attempt "$LOG_DIR/podcast_${TODAY}.log" "podcast pill"
    timeout "$MEDIA_TIMEOUT_SECS" "$HERMES_BIN" chat -q "You are the Podcast Pill generator. Load skill podcast-pill.
Today is $TODAY. Issue #$NEXT_ISSUE.
Read $V2_DIR/edition.json. Generate Castor/Luna dialogue from lead.
Produce TTS audio, concat with ffmpeg, write metadata to $V2_DIR/podcast_meta.json.
Use text_to_speech tool. Use terminal for ffmpeg. ENGLISH ONLY." \
        --profile "$PROFILE" -s podcast-pill -t file,terminal -m "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" -Q --yolo \
        >>"$LOG_DIR/podcast_${TODAY}.log" 2>&1 || true

    # Check if it failed due to credits (own signal, independent of images)
    if last_attempt "$LOG_DIR/podcast_${TODAY}.log" | grep -q "spending-limit\|credits exhausted\|403"; then
        echo "  ⚠ xAI credits exhausted for podcast"
        SKIP_PODCAST=true
    fi

    # Inject podcast pill into HTML (if metadata was generated)
    if [ -f "$V2_DIR/podcast_meta.json" ]; then
        META=$(python3 -c "
import json
with open('$V2_DIR/podcast_meta.json') as f:
    m = json.load(f)
print(m.get('ogg_rel_path', ''))
print(m.get('duration_sec', 0))
") 2>/dev/null || META=""
        OGG_REL=$(echo "$META" | sed -n '1p')
        DUR=$(echo "$META" | sed -n '2p')
        if [ -n "$OGG_REL" ] && [ "${DUR:-0}" -gt 0 ] 2>/dev/null; then
            python3 "$PODCAST_INJECT" \
                "$OUTPUT_DIR/index.html" \
                "$OGG_REL" \
                "$DUR" \
                --output "$OUTPUT_DIR/index.html" \
                2>>"$LOGFILE" && echo "  ✓ podcast pill injected" || echo "  ⚠ podcast pill injection failed"
        else
            echo "  - podcast meta incomplete, skipping injection"
        fi
    else
        echo "  - podcast meta not found, skipping"
    fi
else
    echo "  - podcast pill skipped (xAI credits unavailable)"
fi
check_timeout

# ── Step 8: Wire Articles ────────────────────────────────────
echo "[step 8] wire articles..."
WIRE_SCRIPT="$SCRIPT_DIR/content/wire_articles.py"
if [ -f "$WIRE_SCRIPT" ]; then
    # --provider passed explicitly (rather than relying on wire_articles.py's
    # own default) so $PIPELINE_PROVIDER stays the single place the backend is
    # decided for the whole pipeline.
    python3 "$WIRE_SCRIPT" --max 5 --out "$SCOUTS_DIR/scout_wire.json" \
        --model "$PIPELINE_MODEL" --provider "$PIPELINE_PROVIDER" 2>>"$LOGFILE" || \
        echo "  ⚠ wire articles failed (non-fatal)"
    WIRE_COUNT=$(python3 -c "import json;d=json.load(open('$SCOUTS_DIR/scout_wire.json'));print(len(d))" 2>/dev/null || echo "0")
    echo "  ✓ $WIRE_COUNT wire articles written"
else
    echo "  - wire_articles.py not found, skipping"
fi

echo "[step 8b] inject wire ticker..."
INJECT_SCRIPT="$SCRIPT_DIR/inject/inject_wire_ticker.py"
if [ "${WIRE_COUNT:-0}" -gt 0 ] && [ -f "$INJECT_SCRIPT" ] && [ -f "$OUTPUT_DIR/index.html" ]; then
    python3 "$INJECT_SCRIPT" "$OUTPUT_DIR/index.html" "$SCOUTS_DIR/scout_wire.json" --output "$OUTPUT_DIR/index.html" 2>>"$LOGFILE" || \
        echo "  ⚠ ticker injection failed (non-fatal)"
    echo "  ✓ ticker injected"
else
    echo "  - no wire articles, skipping ticker"
fi
check_timeout

# ── Step 8c: Making-of page ──────────────────────────────────
# "How this issue made itself" — a replayable account of this run, built by
# parsing what the pipeline already wrote (scout JSON, run log, log mtimes,
# edition.json). Pure code, no LLM, no network, READ-ONLY on pipeline state.
#
# STRICTLY NON-FATAL, and deliberately placed last among the content steps:
# by the time it runs, index.html is already complete. If it fails, the
# newspaper publishes exactly as it would have without it — the front page
# link just leads to a 404 for that day. Never let this step block a deploy.
echo "[step 8c] making-of page..."
MAKING_SCRIPT="$SCRIPT_DIR/content/make_making_of.py"
if [ -f "$MAKING_SCRIPT" ]; then
    if python3 "$MAKING_SCRIPT" "$OUTPUT_DIR/making-of.html" \
         --date "$TODAY" --logs "$LOG_DIR" \
         --edition "$V2_DIR/edition.json" --scouts "$SCOUTS_DIR" 2>>"$LOGFILE"; then
        echo "  ✓ making-of page built"
    else
        echo "  ⚠ making-of page failed (non-fatal) — issue publishes without it"
    fi
else
    echo "  - make_making_of.py not found, skipping"
fi
check_timeout

# ── Step 9: Deploy ───────────────────────────────────────────
echo "[step 9] deploying to production..."

cd "$DEPLOY_DIR"
# NO second git reset --hard here. Step 1b already synced $DEPLOY_DIR to
# origin/main and, on the increment path, modified a TRACKED file in the
# process (archive/index.html, rewritten by regenerate_archive_index()) plus
# created a new UNTRACKED archive/<date>/ directory.
#
# A second `reset --hard` at this point reverts tracked-file modifications
# back to their committed state but does NOT touch untracked new
# directories — so it silently discarded every archive/index.html update
# from 2026-07-25 onward while the archive/<date>/ folders themselves kept
# getting committed. The listing page froze at 07-25 for four days before
# anyone noticed, because the underlying data was all still there — only
# the index of it stopped updating. Reproduced in an isolated sandbox
# before removing this.
echo "$NEXT_ISSUE" > "$DEPLOY_DIR/.issue"

# ── Step 10: Copy files ───────────────────────────────────────
echo "[step 10] copying files..."
cp "$OUTPUT_DIR/index.html" "$DEPLOY_DIR/index.html"
# Guarded: step 8c is non-fatal, so this file may legitimately not exist.
if [ -f "$OUTPUT_DIR/making-of.html" ]; then
    cp "$OUTPUT_DIR/making-of.html" "$DEPLOY_DIR/making-of.html"
    echo "  ✓ making-of page copied"
fi
cp -r "$OUTPUT_DIR/fonts"/* "$DEPLOY_DIR/fonts/" 2>/dev/null || true
mkdir -p "$DEPLOY_DIR/images"
cp "$IMAGES_DIR"/*.jpg "$IMAGES_DIR"/*.png "$DEPLOY_DIR/images/" 2>/dev/null || true
mkdir -p "$DEPLOY_DIR/podcasts"
cp /tmp/v2/podcasts/*.ogg "$DEPLOY_DIR/podcasts/" 2>/dev/null || true
echo "  ✓ files copied to deploy dir"
if [ -f "$TEMPLATE_DIR/style.css" ]; then
    cp "$TEMPLATE_DIR/style.css" "$DEPLOY_DIR/style.css"
    echo "  ✓ style.css copied from template"
else
    echo "  ⚠ template style.css not found"
fi

cp "$V2_DIR/edition.json" "$DEPLOY_DIR/edition.json"
echo "  ✓ edition.json saved to deploy dir"

# ── Step 10b: Edition-100 celebration gate ──────────────────────
# ONE-OFF for issue #100: injects the fullscreen LVX Fragments game gate
# (with skip button) into index.html, and copies the game + image assets
# beside it. The injector is a NO-OP for any other issue, so from #101 the
# newspaper renders exactly as normal — nothing here persists.
# Non-fatal: if it fails the paper still publishes without the gate.
echo "[step 10b] edition-100 gate..."
LUX100_GATE="$SCRIPT_DIR/inject/inject_lux100_gate.py"
LUX100_ASSETS="$PIPELINE_ROOT/assets/lux100"
if [ -f "$LUX100_GATE" ] && [ -d "$LUX100_ASSETS" ]; then
    python3 "$LUX100_GATE" "$DEPLOY_DIR/index.html" "$NEXT_ISSUE" \
        --game "$LUX100_ASSETS/lux-fragments-100.html" \
        --image "$LUX100_ASSETS/lux100.png" \
        --output "$DEPLOY_DIR/index.html" \
        2>>"$LOGFILE" && echo "  ✓ lux-100 gate step ran" || echo "  ⚠ lux-100 gate step failed (non-fatal)"
else
    echo "  - inject_lux100_gate.py or assets not found, skipping"
fi
check_timeout

# ── Step 11: Headlines history + commit + push ───────────────
# (archiving the PREVIOUS issue already happened in step 1b, before this
# run's files were copied in — see the comment there for why)
echo "[step 11] updating headlines history + deploying..."
python3 "$SCRIPT_DIR/core/update_headlines_history.py" \
    "$V2_DIR/edition.json" \
    "$DEPLOY_DIR/headlines_history.json" \
    2>>"$LOGFILE" && echo "  ✓ headlines history updated" || echo "  ⚠ headlines history update failed"

# ── Step 11.5: Build markdown editions (PR #2) ───────────────
# Regenerates editions/*.md + latest.md + llms.txt from edition.json/archive
# so every new issue (and its future numbering) is served as LLM-readable
# markdown. Script lives in the deploy repo (synced via step 1b reset).
if [ -f "$DEPLOY_DIR/scripts/build_markdown.py" ]; then
    python3 "$DEPLOY_DIR/scripts/build_markdown.py" 2>>"$LOGFILE" \
        && echo "  ✓ markdown editions rebuilt" \
        || echo "  ⚠ markdown build failed, continuing"
else
    echo "  ⚠ build_markdown.py not found — markdown skipped"
fi

cd "$DEPLOY_DIR"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "Update AI news $TODAY" --quiet 2>/dev/null || true
fi
git push origin main --quiet 2>/dev/null || echo "  ⚠ git push failed — will retry on next run"
echo "  ✓ pushed to GitHub"

# ── Report ──────────────────────────────────────────────────
IMG_COUNT=$(find "$IMAGES_DIR" \( -name '*.jpg' -o -name '*.png' \) 2>/dev/null | wc -l)
echo ""
echo "═══════════════════════════════════════════════"
echo "✅ V2 PIPELINE COMPLETE — $(date '+%H:%M:%S')"
echo "  Issue:   #$NEXT_ISSUE"
echo "  Date:    $TODAY"
echo "  Scouts:  $SCOUT_COUNT/9"
echo "  Edition: ✅ ($([ -f "$V2_DIR/edition.json" ] && echo 'generated' || echo 'failed'))"
echo "  Wire:    ${WIRE_COUNT:-0} articles"
echo "  Images:  $IMG_COUNT ($([ "$SKIP_IMAGES" = true ] && echo 'skipped - no xAI credits' || echo 'generated'))"
echo "  Podcast: $([ "$SKIP_PODCAST" = true ] && echo 'skipped - no xAI credits' || echo 'attempted')"
echo "  Deploy:  $DEPLOY_DIR"
echo "  Pushed:  github.com/nttluke/luxintenebris-ai-news"
echo "═══════════════════════════════════════════════"

# Final milestone. Reports what degraded (images/podcast skipped on exhausted
# xAI credits) rather than claiming a clean run, so the message is worth
# trusting on the days it says everything worked.
RUN_MIN=$(( $(elapsed) / 60 ))
EXTRAS=""
[ "$SKIP_IMAGES" = true ]  && EXTRAS="$EXTRAS no images (xAI credits),"
[ "$SKIP_PODCAST" = true ] && EXTRAS="$EXTRAS no podcast (xAI credits),"
[ "${WIRE_COUNT:-0}" -eq 0 ] && EXTRAS="$EXTRAS no wire ticker,"
EXTRAS="${EXTRAS%,}"
notify "✅ Lux #$NEXT_ISSUE is live — ${ED_KEPT:-?} stories, $IMG_COUNT illustrations, ${WIRE_COUNT:-0} wire, in ${RUN_MIN}m.${EXTRAS:+ Degraded:$EXTRAS.}
https://luxintenebris.news"
