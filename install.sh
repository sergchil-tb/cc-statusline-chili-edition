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
# Absolute path baked in at install time so $HOME doesn't need shell expansion at runtime
CMD="bash \"$DEST\""

c_ok="\033[38;5;157m"; c_info="\033[38;5;111m"; c_warn="\033[38;5;222m"; c_dim="\033[2m"; c_rst="\033[0m"
say()  { printf "${c_info}▸${c_rst} %s\n" "$1"; }
ok()   { printf "${c_ok}✓${c_rst} %s\n" "$1"; }
warn() { printf "${c_warn}!${c_rst} %s\n" "$1"; }

# ── Dependencies: auto-install any that are missing ─────────────
# apt/dnf/pacman/zypper use "gawk"; everything else matches the binary name
pkg_for() { case "$1" in awk) echo gawk ;; *) echo "$1" ;; esac; }

# winget uses vendor IDs; scoop/choco use the plain package name
winget_id() {
    case "$1" in
        jq)   echo "jqlang.jq" ;;
        git)  echo "Git.Git" ;;
        curl) echo "cURL.cURL" ;;
        awk|gawk) echo "GnuWin32.Gawk" ;;
        *)    echo "$1" ;;
    esac
}

is_windows() { [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "$(uname -s 2>/dev/null)" == MINGW* ]]; }

try_install() {
    local dep="$1" pkg; pkg="$(pkg_for "$1")"
    if is_windows; then
        local wid; wid="$(winget_id "$dep")"
        if command -v winget >/dev/null 2>&1; then
            say "Installing $dep via winget…"
            winget install --id "$wid" -e --accept-source-agreements >/dev/null 2>&1 && return 0
        fi
        if command -v scoop >/dev/null 2>&1; then
            say "Installing $dep via scoop…"
            scoop install "$pkg" >/dev/null 2>&1 && return 0
        fi
        if command -v choco >/dev/null 2>&1; then
            say "Installing $dep via choco…"
            choco install "$pkg" -y >/dev/null 2>&1 && return 0
        fi
        warn "'$dep' is missing. Install it then re-run this script:"
        warn "  winget install $wid"
        warn "  scoop install $pkg   (if you use Scoop)"
        warn "  choco install $pkg   (if you use Chocolatey)"
        exit 1
    elif command -v brew >/dev/null 2>&1; then
        say "Installing $pkg via Homebrew…"
        brew install "$pkg" >/dev/null 2>&1 && return 0
        warn "Couldn't install '$dep'. Run: brew install $pkg"
        exit 1
    elif command -v apt-get >/dev/null 2>&1; then
        say "Installing $pkg via apt…"
        sudo apt-get install -y "$pkg" >/dev/null 2>&1 && return 0
    elif command -v dnf >/dev/null 2>&1; then
        say "Installing $pkg via dnf…"
        sudo dnf install -y "$pkg" >/dev/null 2>&1 && return 0
    elif command -v yum >/dev/null 2>&1; then
        say "Installing $pkg via yum…"
        sudo yum install -y "$pkg" >/dev/null 2>&1 && return 0
    elif command -v pacman >/dev/null 2>&1; then
        say "Installing $pkg via pacman…"
        sudo pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1 && return 0
    elif command -v zypper >/dev/null 2>&1; then
        say "Installing $pkg via zypper…"
        sudo zypper install -y "$pkg" >/dev/null 2>&1 && return 0
    else
        warn "'$dep' is missing and no supported package manager was found."
        warn "Install it manually, then re-run this script."
        exit 1
    fi
    warn "Couldn't auto-install '$dep'. Install it manually, then re-run."
    exit 1
}

for dep in jq git curl awk; do
    command -v "$dep" >/dev/null 2>&1 && continue
    try_install "$dep"
    # PATH may not yet include a freshly installed binary; re-check before continuing
    if ! command -v "$dep" >/dev/null 2>&1; then
        warn "'$dep' was installed but isn't in PATH yet. Restart your shell and re-run."
        exit 1
    fi
    ok "Installed $dep"
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
