#!/usr/bin/env bash
#
# Installer for cc-statusline-chili-edition
# Copies statusline.sh into ~/.claude/ and wires it into settings.json.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
CMD='bash "$HOME/.claude/statusline.sh"'

c_ok="\033[38;5;157m"; c_info="\033[38;5;111m"; c_warn="\033[38;5;222m"; c_dim="\033[2m"; c_rst="\033[0m"
say()  { printf "${c_info}▸${c_rst} %s\n" "$1"; }
ok()   { printf "${c_ok}✓${c_rst} %s\n" "$1"; }
warn() { printf "${c_warn}!${c_rst} %s\n" "$1"; }

# ── Dependency check ────────────────────────────────────
missing=""
for dep in jq git curl awk; do
    command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
if [ -n "$missing" ]; then
    warn "Missing dependencies:$missing"
    warn "Install them first (macOS: 'brew install jq', git/curl/awk ship with the OS)."
    exit 1
fi

mkdir -p "$CLAUDE_DIR"

# ── Install the script (back up any existing one) ───────
if [ -f "$DEST" ]; then
    backup="$DEST.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DEST" "$backup"
    say "Backed up existing statusline.sh → $(basename "$backup")"
fi
cp "$SCRIPT_DIR/statusline.sh" "$DEST"
chmod +x "$DEST"
ok "Installed statusline.sh → $DEST"

# ── Wire it into settings.json (preserve everything else) ──
if [ -f "$SETTINGS" ]; then
    tmp="$(mktemp)"
    jq --arg cmd "$CMD" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "Updated statusLine in $SETTINGS"
else
    cat > "$SETTINGS" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "$CMD"
  }
}
EOF
    ok "Created $SETTINGS with statusLine configured"
fi

printf "\n"
ok "Done! Open Claude Code (or send a prompt) to see your status line."
printf "${c_dim}Preview:${c_rst}\n"
printf '%s\n' '{"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"context_window_size":1000000,"used_percentage":21},"cost":{"total_cost_usd":7.16},"workspace":{"project_dir":"'"$PWD"'"}}' | bash "$DEST" || true
printf "\n"
