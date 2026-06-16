#!/usr/bin/env bash
set -euo pipefail

DATA=$(cat)

# ── Extract fields via single jq call ───────────────────
IFS=$'\t' read -r MODEL DIR PCT CTX_SIZE COST_RAW EFFORT_RAW THINK_RAW < <(
    echo "$DATA" | jq -r '[
        (.model.display_name // "Claude"),
        ((.workspace.project_dir // .cwd // "~") | split("/") | last),
        (try (
            if (.context_window.remaining_percentage // null) != null then
              100 - (.context_window.remaining_percentage | floor)
            elif (.context_window.used_percentage // null) != null then
              (.context_window.used_percentage | floor)
            elif (.context_window.context_window_size // 0) > 0 then
              (((.context_window.current_usage.input_tokens // 0) +
                (.context_window.current_usage.cache_creation_input_tokens // 0) +
                (.context_window.current_usage.cache_read_input_tokens // 0)) * 100 /
               .context_window.context_window_size) | floor
            else 0 end
        ) catch 0),
        (.context_window.context_window_size // 200000),
        (.cost.total_cost_usd // 0),
        (.effort.level // ""),
        (.thinking.enabled // "")
    ] | @tsv'
)

COST=$(printf "%.2f" "$COST_RAW")

# ── Model name: strip "(… context)" suffix, append [1m] only for 1M window ──
MODEL_BASE=$(printf '%s' "$MODEL" | sed -E 's/ *\([^)]*\)$//')
if [ "$CTX_SIZE" -ge 1000000 ] 2>/dev/null; then MODEL_TAG="[1m]"; else MODEL_TAG=""; fi

# ── Thinking + effort (fall back to persisted settings.json) ──
SETTINGS="$HOME/.claude/settings.json"
EFFORT="$EFFORT_RAW"
if [ -z "$EFFORT" ]; then
    [ -f "$SETTINGS" ] && EFFORT=$(jq -r '.effortLevel // "default"' "$SETTINGS" 2>/dev/null) || true
    [ -z "$EFFORT" ] && EFFORT="default"
fi
THINK="$THINK_RAW"
if [ -z "$THINK" ]; then
    [ -f "$SETTINGS" ] && THINK=$(jq -r '.alwaysThinkingEnabled // false' "$SETTINGS" 2>/dev/null) || true
    [ -z "$THINK" ] && THINK="false"
fi

# ── Git branch ──────────────────────────────────────────
BRANCH=$(git -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null || echo "")

# ── Helpers ─────────────────────────────────────────────
# mini block bar of given width, colored by pct threshold
mini_bar() {
    local pct=$1 width=$2 clr i out=""
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    local filled=$(( pct * width / 100 ))
    [ "$filled" -eq 0 ] && [ "$pct" -gt 0 ] && filled=1   # always show a sliver for nonzero
    if [ "$pct" -gt 80 ]; then clr="\033[38;5;203m"
    elif [ "$pct" -gt 50 ]; then clr="\033[38;5;222m"
    else clr="\033[38;5;157m"; fi
    for ((i=0; i<filled; i++)); do out+="${clr}▰"; done
    for ((i=filled; i<width; i++)); do out+="\033[38;5;238m▱"; done
    printf '%b\033[0m' "$out"
}
pct_clr() {
    if [ "$1" -gt 80 ]; then printf "\033[38;5;203m"
    elif [ "$1" -gt 50 ]; then printf "\033[38;5;222m"
    else printf "\033[38;5;157m"; fi
}
# ISO-8601 → "mon d" (lowercase); empty on failure
fmt_reset() {
    local iso="$1" stripped out=""
    [ -z "$iso" ] || [ "$iso" = "null" ] && return
    stripped="${iso%%.*}"; stripped="${stripped%%+*}"; stripped="${stripped%%Z}"
    out=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +"%b %-d" 2>/dev/null \
          || date -d "${stripped/T/ }" +"%b %-d" 2>/dev/null || true)
    printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}

# ── Context bar + cost color ────────────────────────────
BAR=$(mini_bar "$PCT" 14)
CTX_CLR=$(pct_clr "$PCT")
if (( $(echo "$COST > 10" | bc -l) )); then COST_CLR="\033[38;5;203m"
elif (( $(echo "$COST > 2" | bc -l) )); then COST_CLR="\033[38;5;222m"
else COST_CLR="\033[38;5;157m"; fi

# ── Thinking glyph + effort word ────────────────────────
if [ "$THINK" = "true" ]; then THINK_TOK="\033[38;5;176m✦\033[0m"
else THINK_TOK="\033[2m\033[38;5;241m✦\033[0m"
fi
case "$EFFORT" in
  xhigh|max)  EFFORT_TOK="\033[38;5;176;1m$EFFORT\033[0m" ;;
  high)       EFFORT_TOK="\033[38;5;176m$EFFORT\033[0m" ;;
  medium)     EFFORT_TOK="\033[38;5;222m$EFFORT\033[0m" ;;
  low)        EFFORT_TOK="\033[2m\033[38;5;241m$EFFORT\033[0m" ;;
  *)          EFFORT_TOK="\033[2m\033[38;5;241m$EFFORT\033[0m" ;;
esac

# ── Limits: cached usage API (full bucket set), fall back to stdin .rate_limits ──
USAGE=""
CACHE_FILE="/tmp/claude-statusline-usage.json"
if [ -f "$CACHE_FILE" ] && [ "$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))" -lt 60 ]; then
    USAGE=$(cat "$CACHE_FILE" 2>/dev/null || true)
fi
if [ -z "$USAGE" ]; then
    TOKEN=""
    blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
    [ -n "$blob" ] && TOKEN=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
    if [ -z "$TOKEN" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
        TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null || true)
    fi
    if [ -n "$TOKEN" ]; then
        if [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "${NODE_EXTRA_CA_CERTS:-/nonexistent}" ]; then
            RESP=$(curl -s --max-time 4 --cacert "$NODE_EXTRA_CA_CERTS" -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1.170" "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)
        else
            RESP=$(curl -s --max-time 4 -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1.170" "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)
        fi
        if [ -n "$RESP" ] && echo "$RESP" | jq -e . >/dev/null 2>&1; then
            USAGE="$RESP"; echo "$RESP" > "$CACHE_FILE"
        fi
    fi
fi
[ -z "$USAGE" ] && USAGE=$(echo "$DATA" | jq -c '.rate_limits // empty' 2>/dev/null || true)

SEP="\033[2m\033[38;5;241m │ \033[0m"
RATE_LINE=""    # session / weekly / quota (own line)
CREDIT_LINE=""  # extra credits (stacked under quota)
if [ -n "$USAGE" ]; then
    add_rate() { [ -n "$RATE_LINE" ] && RATE_LINE+="$SEP"; RATE_LINE+="$1"; }

    f_util=$(echo "$USAGE" | jq -r '.five_hour.utilization // empty' 2>/dev/null || true)
    w_util=$(echo "$USAGE" | jq -r '.seven_day.utilization // empty' 2>/dev/null || true)

    if [ -n "$f_util" ]; then
        p=$(printf "%.0f" "$f_util"); r=$(fmt_reset "$(echo "$USAGE" | jq -r '.five_hour.resets_at // empty')")
        seg="⏱ $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[2m\033[38;5;241m ⟳ ${r}\033[0m"
        add_rate "$seg"
    fi
    if [ -n "$w_util" ]; then
        p=$(printf "%.0f" "$w_util"); r=$(fmt_reset "$(echo "$USAGE" | jq -r '.seven_day.resets_at // empty')")
        seg="📅 $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[2m\033[38;5;241m ⟳ ${r}\033[0m"
        add_rate "$seg"
    fi
    # Enterprise: five_hour/seven_day null → highest non-null named bucket as quota
    if [ -z "$f_util" ] && [ -z "$w_util" ]; then
        top=$(echo "$USAGE" | jq -r 'to_entries
            | map(select(.key!="extra_usage" and (.value|type=="object") and (.value.utilization!=null)))
            | sort_by(.value.utilization) | last
            | if . == null then empty else "\(.value.utilization)\t\(.value.resets_at // "")" end' 2>/dev/null || true)
        if [ -n "$top" ]; then
            p=$(printf "%.0f" "$(echo "$top" | cut -f1)"); r=$(fmt_reset "$(echo "$top" | cut -f2)")
            seg="🚦 $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[2m\033[38;5;241m ⟳ ${r}\033[0m"
            add_rate "$seg"
        fi
    fi
    # Extra credits — own line, with progress bar
    extra_on=$(echo "$USAGE" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null || true)
    if [ "$extra_on" = "true" ]; then
        eu=$(echo "$USAGE" | jq -r '.extra_usage.used_credits // 0' 2>/dev/null)
        el=$(echo "$USAGE" | jq -r '.extra_usage.monthly_limit // 0' 2>/dev/null)
        ep=$(echo "$USAGE" | jq -r '.extra_usage.utilization // 0' 2>/dev/null)
        eud=$(awk "BEGIN{printf \"%.0f\", $eu/100}"); eld=$(awk "BEGIN{printf \"%.0f\", $el/100}")
        epi=$(printf "%.0f" "$ep")
        CREDIT_LINE="💳 $(mini_bar "$epi" 14) $(pct_clr "$epi")\$${eud}\033[2m\033[38;5;241m/\033[0m\$${eld} ${epi}%\033[0m"
    fi
fi

# ── Output ──────────────────────────────────────────────
# Line 1 — identity:  Model[1m] │ 📁 dir │ 🌿 branch
echo -e "\033[38;5;111;1m${MODEL_BASE}\033[0m\033[2m\033[38;5;245m${MODEL_TAG}\033[0m${SEP}\033[38;5;111m📁 ${DIR}\033[0m$([ -n "$BRANCH" ] && printf '%b' "${SEP}\033[38;5;176m🌿 ${BRANCH}\033[0m")"
# Line 2 — session:  🧠 [bar] % │ $cost │ ✦ effort
echo -e "🧠 ${BAR} ${CTX_CLR}${PCT}%\033[0m${SEP}${COST_CLR}\$${COST}\033[0m${SEP}${THINK_TOK} ${EFFORT_TOK}"
# Line 3 — rate limit / quota ; Line 4 — credits (under quota)
[ -n "$RATE_LINE" ] && echo -e "$RATE_LINE"
[ -n "$CREDIT_LINE" ] && echo -e "$CREDIT_LINE"
