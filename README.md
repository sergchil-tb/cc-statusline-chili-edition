# cc-statusline-chili-edition 🌶️

An informative, multi-line status line for [Claude Code](https://code.claude.com) — model & repo identity, live context usage, session cost, reasoning mode, and your **account limits** (rate-limit quota + extra credits) rendered as clean segmented bars.

Built for **Claude Enterprise** accounts (where the standard 5-hour / weekly buckets are `null` and usage lives in a plan-quota + credits bucket instead), but it degrades gracefully to Pro/Max session limits too.

```
Opus 4.8[1m] │ 📁 talabat-mobile-app-flutter │ 🌿 master
🧠 ▰▰▱▱▱▱▱▱▱▱▱▱▱▱ 21% │ $7.16 │ ✦ high
🚦 ▰▰▰▰▰▰▱▱▱▱▱▱▱▱ 45% ⟳ sep 3
💳 ▰▱▱▱▱▱▱▱▱▱▱▱▱▱ $21/$300 7%
```

## What each part means

**Line 1 — identity**
| Widget | Meaning |
|---|---|
| `Opus 4.8[1m]` | Model name. `[1m]` is appended only for a 1M-token context window (nothing shown at 200k). |
| `📁 name` | Current project folder. |
| `🌿 branch` | Current git branch (omitted outside a repo). |

**Line 2 — this session**
| Widget | Meaning |
|---|---|
| `🧠 ▰▰▱… 21%` | Context-window usage. Green < 50% · yellow 50–80% · red > 80%. |
| `$7.16` | Total session cost so far. |
| `✦ effort` | Reasoning effort (`low`/`medium`/`high`/`xhigh`). The `✦` glyph is bright when extended thinking is on, dim when off. |

**Line 3 — rate limit**
| Widget | Meaning |
|---|---|
| `⏱ …` | 5-hour session limit (Pro/Max). |
| `📅 …` | Weekly limit (Pro/Max). |
| `🚦 … ⟳ sep 3` | Enterprise plan quota (shown when the standard buckets are `null`), with reset date. |

**Line 4 — credits**
| Widget | Meaning |
|---|---|
| `💳 ▰… $21/$300 7%` | Extra-usage credits: used / monthly limit and percentage. |

Limit data comes from the Claude Code status payload when present, otherwise from the OAuth usage API (cached for 60s). Honors `NODE_EXTRA_CA_CERTS` for corporate TLS interception.

## Install

### Option A — clone & run (works for private repos)
```bash
git clone <REPO_URL> cc-statusline-chili-edition
cd cc-statusline-chili-edition
./install.sh
```

### Option B — one-liner (only if the repo is public)
```bash
curl -fsSL <RAW_URL>/install.sh | bash
```

The installer:
1. Copies `statusline.sh` → `~/.claude/statusline.sh` (backing up any existing one).
2. Sets `statusLine` in `~/.claude/settings.json` (other settings are preserved).

Then open Claude Code or send a prompt — the status line refreshes automatically.

### Manual install
Copy `statusline.sh` to `~/.claude/statusline.sh`, then add to `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\""
  }
}
```

## Requirements
- `jq`, `git`, `curl`, `awk` (all standard on macOS; `brew install jq` if missing).
- A terminal with a Nerd-Font-ish / emoji-capable font and 256-color support.
- macOS or Linux. Token is read from the macOS Keychain or `~/.claude/.credentials.json`.

## Customizing
Everything lives in `statusline.sh`:
- **Bar width** — the `14` in the `mini_bar … 14` calls.
- **Bar glyphs** — `▰`/`▱` in `mini_bar()` (swap for `▮`/`▯` or `■`/`□` to taste).
- **Colors** — 256-color codes (`111` blue, `176` mauve, `157/222/203` green/yellow/red thresholds, `238/241` dim).
- **Thresholds** — edit `mini_bar()` / `pct_clr()`.

## Notes
- On a cold cache, the limits line makes one ≤4s API call, then caches for 60s.
- No secrets are stored in this repo; your OAuth token never leaves your machine.

---
🌶️ *Chili edition — seasoned by [@sergchil](https://github.com/sergchil).*
