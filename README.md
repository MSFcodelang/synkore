# Synkore

**One command. Your Claude — same memory, every device.**

```bash
curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/install.sh | bash
```

---

```
  Mac            Pi / Server       Phone
  ───            ───────────       ─────
  Claude ──────► GitHub ◄────── Claude
  memory          (sync)          memory
    │                               │
    └──────────── Telegram ─────────┘
                 (optional)
```

---

## What it does

- Claude remembers everything — across sessions, across devices
- Every memory file auto-commits and pushes to a private GitHub repo
- All your repos pull from GitHub every 5 minutes, automatically
- A health check runs silently every time you open Claude
- One tap on your phone → Claude, with full context

## What it doesn't do

- Nothing runs in the cloud — your data stays on your hardware
- No subscription required for the core install
- No Anthropic account changes — it uses Claude Code's public hooks API

---

## Requirements

- [Claude Code](https://claude.ai/code) installed
- A GitHub account
- Mac or Linux (Raspberry Pi included)

---

## What gets installed

| Component | What it does |
|---|---|
| Memory hook | Auto-commits every Claude memory write to GitHub |
| Sync agent | Pulls all repos every 5 minutes (launchd on Mac, systemd on Linux) |
| Health check | Verifies GitHub + sync are working at session start |
| `claude` alias | Locks Claude to the right folder so memory is never lost |
| Memory repo | Private GitHub repo (`your-username/synkore-memory`) |

---

## After install

```bash
# Reload your shell
source ~/.zshrc   # or ~/.bashrc on Linux

# Then just use Claude normally
claude

# Verify sync is running (wait 5 min first)
cat ~/Claude_Code/sync.log

# Verify health check
cat ~/Claude_Code/health_check.log
```

---

## Uninstall

Everything the installer does can be undone:

```bash
# Stop sync agent (Mac)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.synkore.sync.plist

# Stop sync agent (Linux)
systemctl --user disable --now synkore-sync.timer

# Remove hooks from Claude settings
# Edit ~/.claude/settings.json — remove the PostToolUse and UserPromptSubmit blocks

# Remove the alias from ~/.zshrc or ~/.bashrc
# (the line that says: alias claude='cd $HOME/Claude_Code && claude')

# Delete the memory repo on GitHub if you want (optional — it's just a private repo)
```

---

## Managed version — coming soon

Self-hosting works great. But if you don't have a Pi or server:

- Hosted relay — no Pi needed
- Telegram bot — message Claude from your phone like a contact
- Health dashboard

→ Watch this repo to get notified when Pro launches.

---

> Synkore is an independent open-source project.
> Not affiliated with or endorsed by Anthropic.
> Works with [Claude Code](https://claude.ai/code).
