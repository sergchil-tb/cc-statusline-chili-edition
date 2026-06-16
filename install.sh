#!/usr/bin/env bash
#
# Installer for cc-statusline-chili-edition
# Copies statusline.sh into ~/.claude/ and wires it into settings.json.
#
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/sergchil-tb/cc-statusline-chili-edition/main"

# Run from a clone → copy the local statusline.sh. Piped via curl → download it.
SELF="${BASH_SOURCE[0]:-}"
LOCAL_SRC=""
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/statusline.sh" ]; then
    LOCAL_SRC="$(cd "$(dirname "$SELF")" && pwd)/statusline.sh"
fi

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
CMD='bash "$HOME/.claude/statusline.sh"'

c_ok="\033[38;5;157m"; c_info="\033[38;5;111m"; c_warn="\033[38;5;222m"; c_dim="\033[2m"; c_rst="\033[0m"
say()  { printf "${c_info}▸${c_rst} %s\n" "$1"; }
ok()   { printf "${c_ok}✓${c_rst} %s\n" "$1"; }
warn() { printf "${c_warn}!${c_rst} %s\n" "$1"; }

# ── Dependencies: auto-install any that are missing (Homebrew) ──
pkg_for() { case "$1" in awk) echo gawk ;; *) echo "$1" ;; esac; }

for dep in jq git curl awk; do
    command -v "$dep" >/dev/null 2>&1 && continue
    pkg="$(pkg_for "$dep")"
    if ! command -v brew >/dev/null 2>&1; then
        warn "'$dep' is missing and Homebrew isn't installed."
        warn "Install Homebrew (https://brew.sh) then run: brew install $pkg"
        exit 1
    fi
    say "Installing missing dependency: $pkg"
    if brew install "$pkg" >/dev/null 2>&1 && command -v "$dep" >/dev/null 2>&1; then
        ok "Installed $dep"
    else
        warn "Couldn't install '$dep'. Run manually: brew install $pkg"
        exit 1
    fi
done

mkdir -p "$CLAUDE_DIR"

# ── Install the script (back up any existing one) ───────
if [ -f "$DEST" ]; then
    backup="$DEST.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DEST" "$backup"
    say "Backed up existing statusline.sh → $(basename "$backup")"
fi
if [ -n "$LOCAL_SRC" ]; then
    cp "$LOCAL_SRC" "$DEST"
else
    say "Downloading statusline.sh…"
    curl -fsSL "$RAW_BASE/statusline.sh" -o "$DEST"
fi
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
