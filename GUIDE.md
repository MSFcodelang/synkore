# Synkore — Beginner Guide

> New to GitHub? Never used the terminal? Start here.

---

## How it actually works across all your devices

This is the most important thing to understand before you install.

**Synkore uses GitHub as a hub.** Think of it like iCloud, but for your Claude's memory — and only you can access it.

```
Your Mac                    GitHub                    Your Pi / other Mac
─────────                   ──────                    ───────────────────
Claude writes               (private repo,             Claude reads
a memory file    ────────►  only yours)   ────────►   that memory file
                 push                     pull every
                 instantly                5 minutes
```

When Claude learns something about you on your Mac — your preferences, your projects, your working style — it writes a memory file. Synkore's hook catches that write and pushes it to a private GitHub repository that belongs to you. Your Pi (or any other device with Synkore installed) pulls from that repo every 5 minutes. Claude on your Pi now knows everything Claude on your Mac knows.

**The result:** Claude is the same Claude on every device. Same memory. Same context. Everywhere.

---

## What you need before installing

**1. A GitHub account** — free, takes 2 minutes to create.

GitHub is a service that stores files online — like Google Drive, but for code and text. Over 100 million people use it. Synkore uses it to store your Claude memory privately.

→ Create one at [github.com](https://github.com) — click Sign Up, enter email, pick a username, verify email, choose the free plan.

**2. Claude Code installed** — install it with one command:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then add it to your PATH (the installer tells you this too):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Verify it works:

```bash
claude --version
```

---

## Install Synkore

Once you have GitHub and Claude Code:

```bash
curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/install.sh | bash
```

The installer will:
1. Check all required tools (git, gh, curl, jq) — install any that are missing
2. Generate an SSH key for this device and ask you to add it to GitHub (copy-paste, takes 30 seconds)
3. Open a browser to authenticate with GitHub
4. Create your private memory repository (`your-username/synkore-memory`)
5. Wire Claude so every memory write auto-pushes to GitHub
6. Start a background sync agent that pulls from GitHub every 5 minutes

---

## What each install step is doing — in plain language

**"Generating SSH key..."**
An SSH key is a pair of files — a private key (stays on your machine, never shared) and a public key (you give to GitHub). It lets your machine talk to GitHub securely without a password every time. The randomart pattern printed after is just a visual fingerprint of your key — ignore it.

**"Add this SSH key to your GitHub account"**
GitHub needs your public key so it knows your machine is allowed to push to your repos. You copy the key shown on screen, go to github.com → Settings → SSH and GPG keys → New SSH key, paste it in, save. One time per device.

**"A browser window will open — log in and approve"**
This is GitHub's CLI tool (`gh`) authenticating itself. You log in once and it stores a token on your machine so it can create repos and do GitHub operations on your behalf.

**"Memory repo already exists on GitHub — skipping"**
If you're installing on a second device, this means Synkore found your existing memory repo. It won't create a new one — it connects to the existing one. Your memory is shared across all devices through this single repo.

**"Installation complete!"**
Claude is now wired. Every memory write pushes to GitHub. Every 5 minutes, GitHub is pulled. Done.

---

## Installing on a second (or third) device

Run the exact same command on every device you want to connect:

```bash
curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/install.sh | bash
```

Use the **same GitHub account** on every device. The installer will detect your existing `synkore-memory` repo and connect to it. All devices share the same memory through GitHub.

Each device needs its own SSH key added to GitHub (the installer walks you through it per device — takes 30 seconds).

---

## After install — what to do

```bash
# 1. Reload your shell
source ~/.zshrc

# 2. Open Claude
claude

# 3. After 5 minutes, verify sync is running
cat ~/Claude_Code/sync.log

# 4. Verify health check
cat ~/Claude_Code/health_check.log
```

---

## How to verify it's working

1. On device 1 — open Claude and say: `remember that I prefer dark mode`
2. Wait 5 minutes
3. On device 2 — open Claude and ask: `what do you know about my preferences?`
4. Claude should mention dark mode

If it does: Synkore is working.

---

## Uninstall

One command. Clean removal. Nothing left behind.

```bash
curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/uninstall.sh | bash
```

Your memory files and GitHub repo are **not** deleted — they're yours. Delete the GitHub repo manually if you want: go to github.com → your-username/synkore-memory → Settings → Delete this repository.

---

> Synkore is an independent open-source project.
> Not affiliated with or endorsed by Anthropic.
> Works with [Claude Code](https://claude.ai/code).
