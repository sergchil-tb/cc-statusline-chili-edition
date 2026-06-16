#!/usr/bin/env bash
# cc-statusline-chili-edition — a resilient Claude Code status line.
#
# Resilient by design: it NEVER aborts mid-render and ALWAYS exits 0 — Claude Code
# renders a blank line on any non-zero exit, so a partial line beats a blank one.
# No `set -e`. jq/awk/coreutils are discovered across common install dirs so they
# resolve even when Claude Code runs this with a minimal PATH (Apple Silicon brew,
# Intel brew, MacPorts, asdf, nix, or the macOS system /usr/bin).

for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin /opt/local/bin \
         "$HOME/.asdf/shims" "$HOME/.nix-profile/bin" /run/current-system/sw/bin /usr/bin /bin; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
[ -n "${HOMEBREW_PREFIX:-}" ] && PATH="$HOMEBREW_PREFIX/bin:$PATH"
export PATH

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

DATA=$(cat)

if ! command -v jq >/dev/null 2>&1; then
    printf 'cc-statusline: jq not found — run: brew install jq\n'
    exit 0
fi

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
) || true

# Defensive defaults in case the read came back partial/empty
MODEL="${MODEL:-Claude}"; PCT="${PCT:-0}"; CTX_SIZE="${CTX_SIZE:-200000}"
COST_RAW="${COST_RAW:-0}"; EFFORT_RAW="${EFFORT_RAW:-}"; THINK_RAW="${THINK_RAW:-}"

# Clamp PCT to 0..100 (matches the bar; guards odd/out-of-range payloads)
case "$PCT" in ''|*[!0-9-]*) PCT=0 ;; esac
[ "$PCT" -gt 100 ] 2>/dev/null && PCT=100
[ "$PCT" -lt 0 ] 2>/dev/null && PCT=0

COST=$(printf "%.2f" "$COST_RAW" 2>/dev/null || echo "0.00")

# ── Model name: strip "(… context)" suffix, append [1m] only for 1M window ──
MODEL_BASE=$(printf '%s' "$MODEL" | sed -E 's/ *\([^)]*\)$//')
if [ "$CTX_SIZE" -ge 1000000 ] 2>/dev/null; then MODEL_TAG="[1m]"; else MODEL_TAG=""; fi

# ── Thinking + effort (fall back to persisted settings.json) ──
SETTINGS="$CFG_DIR/settings.json"
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
mini_bar() {
    local pct=$1 width=$2 clr i out=""
    case "$pct" in ''|*[!0-9-]*) pct=0 ;; esac
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    local filled=$(( pct * width / 100 ))
    [ "$filled" -eq 0 ] && [ "$pct" -gt 0 ] && filled=1   # always show a sliver for nonzero
    if [ "$pct" -gt 80 ]; then clr="\033[38;5;203m"
    elif [ "$pct" -gt 50 ]; then clr="\033[38;5;222m"
    else clr="\033[38;5;157m"; fi
    for ((i=0; i<filled; i++)); do out+="${clr}▰"; done
    for ((i=filled; i<width; i++)); do out+="\033[38;5;242m▱"; done
    printf '%b\033[0m' "$out"
}
pct_clr() {
    local p="${1:-0}"
    if   [ "$p" -gt 80 ] 2>/dev/null; then printf "\033[38;5;203m"
    elif [ "$p" -gt 50 ] 2>/dev/null; then printf "\033[38;5;222m"
    else printf "\033[38;5;157m"; fi
}
fmt_reset() {
    local iso="$1" stripped out=""
    [ -z "$iso" ] || [ "$iso" = "null" ] && return
    stripped="${iso%%.*}"; stripped="${stripped%%+*}"; stripped="${stripped%%Z}"
    out=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +"%b %-d" 2>/dev/null \
          || date -d "${stripped/T/ }" +"%b %-d" 2>/dev/null || true)
    printf '%s' "$out" | tr '[:upper:]' '[:lower:]'
}
cache_age() {  # seconds since mtime, or a huge number if absent
    local f="$1"
    [ -f "$f" ] || { echo 999999; return; }
    echo $(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0) ))
}

# ── Context bar + cost color (awk math — no bc dependency) ──
BAR=$(mini_bar "$PCT" 14)
CTX_CLR=$(pct_clr "$PCT")
COST_CENTS=$(awk "BEGIN{printf \"%.0f\", ${COST_RAW:-0}*100}" 2>/dev/null || echo 0)
case "$COST_CENTS" in ''|*[!0-9]*) COST_CENTS=0 ;; esac
if   [ "$COST_CENTS" -gt 1000 ]; then COST_CLR="\033[38;5;203m"
elif [ "$COST_CENTS" -gt 200 ];  then COST_CLR="\033[38;5;222m"
else COST_CLR="\033[38;5;157m"; fi

# ── Thinking glyph + effort word ────────────────────────
if [ "$THINK" = "true" ]; then THINK_TOK="\033[38;5;176m✦\033[0m"
else THINK_TOK="\033[38;5;245m✦\033[0m"; fi
case "$EFFORT" in
  xhigh|max)  EFFORT_TOK="\033[38;5;176;1m$EFFORT\033[0m" ;;
  high)       EFFORT_TOK="\033[38;5;176m$EFFORT\033[0m" ;;
  medium)     EFFORT_TOK="\033[38;5;222m$EFFORT\033[0m" ;;
  low)        EFFORT_TOK="\033[38;5;245m$EFFORT\033[0m" ;;
  *)          EFFORT_TOK="\033[38;5;245m$EFFORT\033[0m" ;;
esac

# ── Limits: cached usage API (negative-cached + stale fallback), then stdin ──
USAGE=""
CACHE_FILE="/tmp/claude-statusline-usage.json"
FAIL_FILE="/tmp/claude-statusline-usage.fail"
[ "$(cache_age "$CACHE_FILE")" -lt 60 ] && USAGE=$(cat "$CACHE_FILE" 2>/dev/null)

# Only hit the network if no fresh cache AND no recent failure (avoids stalling every
# render behind a black-holed/captive-portal connection).
if [ -z "$USAGE" ] && [ "$(cache_age "$FAIL_FILE")" -ge 60 ]; then
    TOKEN=""
    blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
    [ -n "$blob" ] && TOKEN=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
    if [ -z "$TOKEN" ] && [ -f "$CFG_DIR/.credentials.json" ]; then
        TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CFG_DIR/.credentials.json" 2>/dev/null || true)
    fi
    if [ -n "$TOKEN" ]; then
        if [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "${NODE_EXTRA_CA_CERTS:-/nonexistent}" ]; then
            RESP=$(curl -s --connect-timeout 2 --max-time 3 --cacert "$NODE_EXTRA_CA_CERTS" -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1.170" "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)
        else
            RESP=$(curl -s --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code/2.1.170" "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)
        fi
        if [ -n "$RESP" ] && echo "$RESP" | jq -e . >/dev/null 2>&1; then
            USAGE="$RESP"; echo "$RESP" > "$CACHE_FILE"; rm -f "$FAIL_FILE"
        else
            : > "$FAIL_FILE" 2>/dev/null || true   # negative cache
        fi
    fi
fi
# Stale-cache fallback: show slightly-old limits instead of nothing
[ -z "$USAGE" ] && [ -f "$CACHE_FILE" ] && USAGE=$(cat "$CACHE_FILE" 2>/dev/null)
# Last resort: whatever the status payload itself carried
[ -z "$USAGE" ] && USAGE=$(echo "$DATA" | jq -c '.rate_limits // empty' 2>/dev/null || true)

SEP="\033[38;5;245m │ \033[0m"
RATE_LINE=""    # session / weekly / quota (own line)
CREDIT_LINE=""  # extra credits (stacked under quota)
if [ -n "$USAGE" ]; then
    add_rate() { [ -n "$RATE_LINE" ] && RATE_LINE+="$SEP"; RATE_LINE+="$1"; }

    f_util=$(echo "$USAGE" | jq -r '.five_hour.utilization // empty' 2>/dev/null || true)
    w_util=$(echo "$USAGE" | jq -r '.seven_day.utilization // empty' 2>/dev/null || true)

    if [ -n "$f_util" ]; then
        p=$(printf "%.0f" "$f_util" 2>/dev/null || echo 0); r=$(fmt_reset "$(echo "$USAGE" | jq -r '.five_hour.resets_at // empty')")
        seg="⏱️ $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[38;5;245m ⟳ ${r}\033[0m"
        add_rate "$seg"
    fi
    if [ -n "$w_util" ]; then
        p=$(printf "%.0f" "$w_util" 2>/dev/null || echo 0); r=$(fmt_reset "$(echo "$USAGE" | jq -r '.seven_day.resets_at // empty')")
        seg="📅 $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[38;5;245m ⟳ ${r}\033[0m"
        add_rate "$seg"
    fi
    # Enterprise: five_hour/seven_day null → highest non-null named bucket as quota
    if [ -z "$f_util" ] && [ -z "$w_util" ]; then
        top=$(echo "$USAGE" | jq -r 'to_entries
            | map(select(.key!="extra_usage" and (.value|type=="object") and (.value.utilization!=null)))
            | sort_by(.value.utilization) | last
            | if . == null then empty else "\(.value.utilization)\t\(.value.resets_at // "")" end' 2>/dev/null || true)
        if [ -n "$top" ]; then
            p=$(printf "%.0f" "$(echo "$top" | cut -f1)" 2>/dev/null || echo 0); r=$(fmt_reset "$(echo "$top" | cut -f2)")
            seg="🚦 $(mini_bar "$p" 14) $(pct_clr "$p")${p}%\033[0m"; [ -n "$r" ] && seg+="\033[38;5;245m ⟳ ${r}\033[0m"
            add_rate "$seg"
        fi
    fi
    # Extra credits — own line, with progress bar
    extra_on=$(echo "$USAGE" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null || true)
    if [ "$extra_on" = "true" ]; then
        eu=$(echo "$USAGE" | jq -r '.extra_usage.used_credits // 0' 2>/dev/null)
        el=$(echo "$USAGE" | jq -r '.extra_usage.monthly_limit // 0' 2>/dev/null)
        ep=$(echo "$USAGE" | jq -r '.extra_usage.utilization // 0' 2>/dev/null)
        eud=$(awk "BEGIN{printf \"%.0f\", ${eu:-0}/100}" 2>/dev/null || echo 0)
        eld=$(awk "BEGIN{printf \"%.0f\", ${el:-0}/100}" 2>/dev/null || echo 0)
        epi=$(printf "%.0f" "${ep:-0}" 2>/dev/null || echo 0)
        CREDIT_LINE="💳 $(mini_bar "$epi" 14) $(pct_clr "$epi")\$${eud}\033[38;5;245m/\033[0m\$${eld} ${epi}%\033[0m"
    fi
fi

# ── Output ──────────────────────────────────────────────
# Line 1 — identity. Data fields (model/dir/branch) go through printf %s so a name
# containing a tab, %, or backslash can never inject control chars or desync columns.
printf '\033[38;5;111;1m%s\033[0m\033[38;5;245m%s\033[0m\033[38;5;245m │ \033[0m\033[38;5;111m📁 %s\033[0m' "$MODEL_BASE" "$MODEL_TAG" "$DIR"
[ -n "$BRANCH" ] && printf '\033[38;5;245m │ \033[0m\033[38;5;176m🌿 %s\033[0m' "$BRANCH"
printf '\n'
# Line 2 — session (only numeric/enum data here)
echo -e "🧠 ${BAR} ${CTX_CLR}${PCT}%\033[0m${SEP}${COST_CLR}\$${COST}\033[0m${SEP}${THINK_TOK} ${EFFORT_TOK}"
# Lines 3-4 — limits
[ -n "$RATE_LINE" ] && echo -e "$RATE_LINE"
[ -n "$CREDIT_LINE" ] && echo -e "$CREDIT_LINE"

exit 0   # ALWAYS succeed — a non-zero exit makes Claude Code render a blank line
