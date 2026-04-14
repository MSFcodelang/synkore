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

> **New to GitHub or the terminal?** → [Start here: GUIDE.md](GUIDE.md)

## Requirements

- Claude Code installed — `curl -fsSL https://claude.ai/install.sh | bash`
- A GitHub account
- Mac or Linux (Raspberry Pi included)

---

## What is GitHub and why do you need it?

GitHub is a free service that stores files online — like Google Drive, but for code and text files. It's used by over 100 million people, from professional engineers to writers and researchers.

**For Synkore, GitHub does one thing: it holds a backup of your Claude memory.**

Every time Claude learns something about you — your preferences, your projects, your working style — that memory gets saved to a private GitHub repository that only you can access. When you open Claude on a different device, it pulls that memory down automatically. That's how it remembers you everywhere.

**You don't need to know anything about code to use GitHub with Synkore.** The installer handles everything. You just need a free account.

→ Create one at [github.com](https://github.com) — takes 2 minutes. Free forever for private repos.

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

One command. Clean removal. Nothing left behind.

```bash
curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/uninstall.sh | bash
```

This removes: sync agent, Claude hooks, shell alias, Synkore scripts.

This does NOT remove: your repos in `~/Claude_Code/`, your SSH key, your memory files, your GitHub memory repo (it's private and yours — delete it manually if you want: `gh repo delete synkore-memory --yes`).

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
