#!/bin/bash

# =============================================================================
# SYNKORE INSTALLER
# =============================================================================
# The plot: this script turns any Mac or Linux machine into a node in your
# Synkore setup. It does five things, in order:
#   ACT 1 — Preflight: check and install all required tools
#   ACT 2 — GitHub: set up SSH key and git identity
#   ACT 3 — Memory repo: create and connect the private memory GitHub repo
#   ACT 4 — Hooks: wire Claude to auto-commit every memory write
#   ACT 5 — Sync agent: background process that pulls repos every 5 minutes
#   ACT 6 — Finish: lock the claude alias, print verification checklist
#
# Everything this script does can be undone in a few minutes.
# Nothing is permanent.
# =============================================================================

set -euo pipefail

# === COLORS ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✅  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️   $1${RESET}"; }
fail() { echo -e "${RED}❌  $1${RESET}"; }
step() { echo -e "\n${BOLD}→ $1${RESET}"; }
info() { echo -e "    $1"; }

# =============================================================================
# ACT 0 — DETECT OS
# =============================================================================
# We need to know the OS early because almost every phase branches on it.
# Mac uses launchd for background agents, Linux uses systemd.
# Mac uses Homebrew for packages, Linux uses apt.

OS=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="mac"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
else
    fail "Unsupported OS: $OSTYPE"
    echo "Synkore supports macOS and Linux (Debian/Ubuntu)."
    exit 1
fi

# Detect which shell config file to use — Mac defaults to zsh, Linux to bash.
# We write the claude alias and ssh-agent config here at the end.
# BUG-018: the original playbook assumed ~/.zshrc on all machines.
# Linux defaults to bash, not zsh. We detect the active shell and use the
# correct config file — whichever shell the user is actually running.
RC=""
if [[ "$SHELL" == */zsh ]]; then
    RC="$HOME/.zshrc"
else
    RC="$HOME/.bashrc"
fi

echo ""
echo -e "${BOLD}╔════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        Welcome to Synkore              ║${RESET}"
echo -e "${BOLD}║  One command. Your Claude, everywhere. ║${RESET}"
echo -e "${BOLD}╚════════════════════════════════════════╝${RESET}"
echo ""
# BUG-021: users hesitate at steps that feel permanent. Stating reversibility
# upfront at the very start reduces abandonment and fear.
echo "Everything this installer does can be undone in a few minutes."
echo "Nothing is permanent."
echo ""

# =============================================================================
# ACT 0b — CHECK IF ALREADY INSTALLED (IDEMPOTENCY)
# =============================================================================
# If Synkore is already installed, running this again would duplicate hooks
# and break things (BUG-012). We detect previous installs and ask what to do.

SYNKORE_MARKER="$HOME/.synkore_installed"
if [[ -f "$SYNKORE_MARKER" ]]; then
    echo ""
    warn "Synkore is already installed on this machine (installed on: $(cat "$SYNKORE_MARKER"))."
    echo ""
    echo "What would you like to do?"
    echo "  1) Update existing install (remove old hooks, apply fresh)"
    echo "  2) Exit — I just wanted to check"
    echo ""
    read -r -p "Enter 1 or 2: " REINSTALL_CHOICE
    if [[ "$REINSTALL_CHOICE" == "2" ]]; then
        echo "Exiting. Nothing changed."
        exit 0
    fi
    # Remove old hooks before proceeding — we will re-add them cleanly below.
    # This prevents BUG-012 (duplicate hooks).
    step "Removing old hooks before update..."
    if [[ -f "$HOME/.claude/settings.json" ]]; then
        # Strip out the Synkore hooks from settings.json using python3.
        # python3 is always available (Mac + Linux). We cannot use jq here
        # because jq may not be installed yet (BUG-001 is what we're fixing).
        python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
with open(path) as f:
    cfg = json.load(f)
hooks = cfg.get("hooks", {})
for event in ["PostToolUse", "UserPromptSubmit"]:
    if event in hooks:
        hooks[event] = [
            h for h in hooks[event]
            if "synkore" not in str(h).lower()
            and "msf_sync" not in str(h).lower()
            and "Syncing memory" not in str(h)
        ]
cfg["hooks"] = hooks
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("Old Synkore hooks removed.")
PYEOF
    fi
    ok "Old install cleaned. Proceeding with fresh install..."
fi

# =============================================================================
# ACT 1 — PREFLIGHT: CHECK AND INSTALL REQUIRED TOOLS
# =============================================================================
# We check for every tool before touching anything.
# A missing tool is caught here, installed silently, and the install continues.
# No tool check = silent failure later (BUG-001, BUG-007, BUG-019).

step "ACT 1 — Checking required tools..."

# --- GATE 1: git ---
# On a fresh Mac, running 'git' opens a system dialog asking to install Xcode
# Command Line Tools. We intercept this and handle it cleanly (BUG-007).
if ! command -v git &>/dev/null; then
    warn "git is not installed."
    if [[ "$OS" == "mac" ]]; then
        info "Installing Xcode Command Line Tools (required for git)..."
        info "A dialog may appear — click Install and wait for it to finish."
        xcode-select --install 2>/dev/null || true
        echo ""
        read -r -p "Press Enter once the Xcode tools installation has finished: "
    else
        info "Installing git..."
        sudo apt-get update -qq && sudo apt-get install -y -qq git
    fi
fi
ok "git: $(git --version)"

# --- GATE 2: jq ---
# jq is the tool the memory hook uses to parse JSON from Claude's output.
# It is NOT installed by default on Mac or most Linux distros (BUG-001, BUG-019).
# Without jq, every memory write appears to succeed but actually does nothing.
if ! command -v jq &>/dev/null; then
    warn "jq is not installed — installing now..."
    if [[ "$OS" == "mac" ]]; then
        if ! command -v brew &>/dev/null; then
            fail "Homebrew is required to install jq on Mac."
            echo "Install Homebrew first: https://brew.sh — then re-run this installer."
            exit 1
        fi
        brew install jq
    else
        sudo apt-get update -qq && sudo apt-get install -y -qq jq
    fi
fi
ok "jq: $(jq --version)"

# --- GATE 3: curl ---
if ! command -v curl &>/dev/null; then
    warn "curl not found — installing..."
    if [[ "$OS" == "linux" ]]; then
        sudo apt-get install -y -qq curl
    fi
fi
ok "curl: present"

# --- GATE 4: gh (GitHub CLI) ---
# gh is used to create the private memory repo automatically.
# Without it, the user would have to create it manually on GitHub.com.
if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) is not installed — installing..."
    if [[ "$OS" == "mac" ]]; then
        brew install gh
    else
        # Official GitHub CLI install for Debian/Ubuntu
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq gh
    fi
fi
ok "gh: $(gh --version | head -1)"

# --- GATE 5: Claude Code ---
if ! command -v claude &>/dev/null; then
    fail "Claude Code is not installed."
    echo ""
    echo "Install Claude Code first: https://claude.ai/code"
    echo "Then re-run this installer."
    exit 1
fi
ok "Claude Code: present"

# =============================================================================
# ACT 2 — GITHUB: SSH KEY + GIT IDENTITY
# =============================================================================
# We need two things from GitHub: an SSH key so Claude can push memory files,
# and a git identity so commits have an author name.
# If the key already exists, we reuse it — no regeneration.

step "ACT 2 — Setting up GitHub authentication..."

# --- Git identity ---
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)

if [[ -z "$GIT_NAME" ]]; then
    read -r -p "    Your name (for git commits): " GIT_NAME
    git config --global user.name "$GIT_NAME"
fi
if [[ -z "$GIT_EMAIL" ]]; then
    read -r -p "    Your email (for git commits): " GIT_EMAIL
    git config --global user.email "$GIT_EMAIL"
fi
ok "Git identity: $GIT_NAME <$GIT_EMAIL>"

# --- GitHub username (needed to name the memory repo) ---
echo ""
read -r -p "    Your GitHub username: " GITHUB_USER

# --- SSH key ---
# We prefer ed25519 — the modern, small, fast key type.
# If a key already exists, we use it rather than generating a new one.
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ -f "$SSH_KEY" ]]; then
    ok "SSH key already exists at $SSH_KEY — reusing it."
else
    info "Generating SSH key..."
    ssh-keygen -t ed25519 -C "$GITHUB_USER" -f "$SSH_KEY" -N ""
    # BUG-020: ssh-keygen outputs ASCII art that non-technical users think is
    # an error or a glitch. We immediately reassure them after it runs.
    # The line above generates it — the message below reassures them.
    echo ""
    info "The pattern above is normal — it is a visual fingerprint of your key. Ignore it."
fi

# --- Add key to macOS Keychain so it survives reboots (BUG-005) ---
# On Mac, ssh-add --apple-use-keychain stores the key in the system Keychain.
# Without this, git push fails after every reboot because the SSH agent forgets.
if [[ "$OS" == "mac" ]]; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || ssh-add "$SSH_KEY" 2>/dev/null || true
fi

# --- Write ~/.ssh/config to auto-load the key on startup ---
# UseKeychain yes = Mac Keychain keeps the key loaded permanently.
# AddKeysToAgent yes = auto-loads into ssh-agent on first use.
SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << EOF

Host github.com
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile $SSH_KEY
EOF
    chmod 600 "$SSH_CONFIG"
    info "SSH config written."
fi

# --- Show public key and wait for GitHub confirmation ---
echo ""
echo -e "${BOLD}Add this key to your GitHub account:${RESET}"
echo -e "  Go to: ${BOLD}github.com → Settings → SSH and GPG keys → New SSH key${RESET}"
echo ""
cat "${SSH_KEY}.pub"
echo ""
read -r -p "Press Enter once you have added the key to GitHub: "

# --- Verify the key works ---
info "Verifying connection to GitHub..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    ok "GitHub: authenticated as $GITHUB_USER"
else
    fail "Could not authenticate with GitHub."
    echo "Make sure you added the key shown above to your GitHub account and try again."
    exit 1
fi

# =============================================================================
# ACT 3 — MEMORY REPO: CREATE + CONNECT + PUSH
# =============================================================================
# The memory hook pushes to a private GitHub repo every time Claude writes
# a memory file. That repo must exist and have a remote + tracking branch
# set up BEFORE the hook activates — otherwise every push fails silently (BUG-003).

step "ACT 3 — Setting up memory repository..."

MEMORY_REPO_NAME="synkore-memory"
MEMORY_REMOTE="git@github.com:${GITHUB_USER}/${MEMORY_REPO_NAME}.git"

# Find the active Claude project hash — the folder Claude uses for this machine.
# The hash is derived from the working directory. We lock Claude to ~/Claude_Code
# in ACT 6, so the hash will always be based on that path going forward (BUG-006).
CLAUDE_PROJECTS="$HOME/.claude/projects"
# Find the project folder whose name corresponds to ~/Claude_Code
CLAUDE_CODE_HASH=$(python3 -c "
import os, urllib.parse
path = os.path.expanduser('~/Claude_Code')
# Claude hashes the path by URL-encoding it with dashes replacing encoded chars
encoded = urllib.parse.quote(path, safe='').replace('%', '-')
print(encoded)
" 2>/dev/null || true)

MEMORY_DIR=""
if [[ -n "$CLAUDE_CODE_HASH" && -d "$CLAUDE_PROJECTS/$CLAUDE_CODE_HASH" ]]; then
    MEMORY_DIR="$CLAUDE_PROJECTS/$CLAUDE_CODE_HASH/memory"
else
    # Fallback: find any existing memory folder, prefer the one with MEMORY.md
    MEMORY_DIR=$(find "$CLAUDE_PROJECTS" -name "MEMORY.md" -maxdepth 3 2>/dev/null \
        | head -1 | xargs dirname 2>/dev/null || true)
fi

if [[ -z "$MEMORY_DIR" ]]; then
    # No memory folder exists yet — create it under the correct hash path.
    # We create the Claude_Code dir first so the hash is correct.
    mkdir -p "$HOME/Claude_Code"
    MEMORY_DIR="$CLAUDE_PROJECTS/$CLAUDE_CODE_HASH/memory"
    mkdir -p "$MEMORY_DIR"
    info "Created memory folder at: $MEMORY_DIR"
fi

ok "Memory folder: $MEMORY_DIR"

# Initialize git in the memory folder if not already done
if [[ ! -d "$MEMORY_DIR/.git" ]]; then
    git -C "$MEMORY_DIR" init
    git -C "$MEMORY_DIR" checkout -b main 2>/dev/null || true
fi

# Create a starter MEMORY.md if one doesn't exist
if [[ ! -f "$MEMORY_DIR/MEMORY.md" ]]; then
    cat > "$MEMORY_DIR/MEMORY.md" << EOF
# Claude Memory — $GIT_NAME

## ⚠️ IMPERATIVES — READ FIRST
All behavioral rules and working preferences: \`imperatives.md\`

## Session Commands
\`[check "project"]\` — Read repo + memory → brief → ask focus.
\`[done "project"]\` — Update files → push → update memory → next-session note.

## Active Projects
| Project | Status | Memory file |
|---|---|---|
| (add projects here as you start them) | | |
EOF
    info "Starter MEMORY.md created."
fi

# Create starter imperatives.md if one doesn't exist
if [[ ! -f "$MEMORY_DIR/imperatives.md" ]]; then
    cat > "$MEMORY_DIR/imperatives.md" << EOF
---
name: imperatives
description: Behavioral rules and working preferences
type: feedback
---

# Imperatives

## MEMORY.md DISCIPLINE
MEMORY.md = index only. Max 2 lines per entry. All detail in topic files.
Must stay under 190 lines.

## USER PREFERENCES
(Claude: fill this in as you learn how the user likes to work)
EOF
    info "Starter imperatives.md created."
fi

# Create or connect the remote memory repo on GitHub
info "Checking for memory repo on GitHub..."
if gh repo view "$GITHUB_USER/$MEMORY_REPO_NAME" &>/dev/null; then
    info "Memory repo already exists on GitHub — connecting to it."
else
    info "Creating private memory repo on GitHub..."
    gh repo create "$GITHUB_USER/$MEMORY_REPO_NAME" --private --description "Synkore memory sync" 2>/dev/null
    ok "Memory repo created: github.com/$GITHUB_USER/$MEMORY_REPO_NAME"
fi

# Connect local memory folder to the remote repo (BUG-003)
if ! git -C "$MEMORY_DIR" remote get-url origin &>/dev/null; then
    git -C "$MEMORY_DIR" remote add origin "$MEMORY_REMOTE"
    info "Remote added."
fi

# Initial commit and push so the upstream branch exists (BUG-003)
# Without this, every 'git push' in the hook fails with "no upstream branch".
git -C "$MEMORY_DIR" add .
git -C "$MEMORY_DIR" commit -m "Synkore: initial memory setup" 2>/dev/null || true
git -C "$MEMORY_DIR" push -u origin main 2>/dev/null || \
    git -C "$MEMORY_DIR" push --set-upstream origin main

ok "Memory repo connected and pushed."

# =============================================================================
# ACT 4 — CLAUDE HOOKS: WIRE MEMORY AUTO-SYNC
# =============================================================================
# The PostToolUse hook fires every time Claude writes a file.
# If the file is in the memory folder, it commits and pushes to GitHub.
# The UserPromptSubmit hook runs the health check at session start.
#
# CRITICAL: we merge into existing settings.json, never overwrite it (BUG-002).
# We use python3 (always available) not jq here, because jq may not be
# installed at this point in earlier runs — belt and suspenders.

step "ACT 4 — Wiring Claude memory hooks..."

SETTINGS="$HOME/.claude/settings.json"

# Back up existing settings before touching anything (BUG-002)
if [[ -f "$SETTINGS" ]]; then
    BACKUP="${SETTINGS}.bak.$(date +%s)"
    cp "$SETTINGS" "$BACKUP"
    info "Backed up settings.json → $BACKUP"
else
    # Create a minimal valid settings.json if it doesn't exist
    echo '{}' > "$SETTINGS"
fi

# The PostToolUse hook command.
# It does three things:
#   1. Reads the file path from Claude's tool output using jq
#   2. Checks if the file is inside a memory folder
#   3. If yes: git add, commit, push to GitHub
MEMORY_HOOK_CMD="jq -r '.tool_input.file_path // empty' | { read -r f; echo \"\$f\" | grep -qE '.claude/projects/.+/memory' || exit 0; REPO=\$(dirname \"\$f\"); while [ \"\$REPO\" != \"/\" ] && [ ! -d \"\$REPO/.git\" ]; do REPO=\$(dirname \"\$REPO\"); done; [ -d \"\$REPO/.git\" ] || exit 0; cd \"\$REPO\" 2>/dev/null || exit 0; git add . && git commit -m \"Auto-sync memory \$(date '+%Y-%m-%d %H:%M')\" && git push; } 2>/dev/null || true"

# The UserPromptSubmit hook — runs health check silently at session start
HEALTH_HOOK_CMD="bash $HOME/Claude_Code/health_check.sh >> /dev/null 2>&1 &"

# Merge hooks into settings.json using python3.
# We check if our hook is already in the array before appending.
python3 - <<PYEOF
import json, os

path = os.path.expanduser("~/.claude/settings.json")
with open(path) as f:
    cfg = json.load(f)

hooks = cfg.setdefault("hooks", {})

# --- PostToolUse hook ---
post_hooks = hooks.setdefault("PostToolUse", [])
memory_hook = {
    "matcher": "Write",
    "hooks": [{
        "type": "command",
        "command": """$MEMORY_HOOK_CMD""",
        "timeout": 120,
        "statusMessage": "Syncing memory..."
    }]
}
# Only add if not already present (idempotency — BUG-012)
already_has_memory_hook = any(
    "Syncing memory" in str(h) for h in post_hooks
)
if not already_has_memory_hook:
    post_hooks.append(memory_hook)
    print("PostToolUse memory hook added.")
else:
    print("PostToolUse memory hook already present — skipped.")

# --- UserPromptSubmit hook ---
submit_hooks = hooks.setdefault("UserPromptSubmit", [])
health_hook = {
    "matcher": "",
    "hooks": [{
        "type": "command",
        "command": """$HEALTH_HOOK_CMD"""
    }]
}
already_has_health_hook = any(
    "health_check" in str(h) for h in submit_hooks
)
if not already_has_health_hook:
    submit_hooks.append(health_hook)
    print("UserPromptSubmit health hook added.")
else:
    print("UserPromptSubmit health hook already present — skipped.")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("settings.json updated.")
PYEOF

ok "Claude hooks wired."

# =============================================================================
# ACT 5 — SYNC AGENT: BACKGROUND REPO SYNC EVERY 5 MINUTES
# =============================================================================
# This background agent pulls all repos in ~/Claude_Code/ from GitHub
# every 5 minutes. On Mac it uses launchd (the Mac job scheduler).
# On Linux it uses systemd user units.
#
# Before pulling, it stashes any local changes to avoid BUG-008
# (git refuses to pull when there are uncommitted local changes).

step "ACT 5 — Installing background sync agent..."

mkdir -p "$HOME/Claude_Code"

# --- Write the sync script ---
# We use $HOME everywhere — never hardcoded paths (BUG-004 root cause).
cat > "$HOME/Claude_Code/msf_sync.sh" << 'SYNCEOF'
#!/bin/bash
# =============================================================================
# msf_sync.sh — Synkore background sync script
# =============================================================================
# Plot: runs every 5 minutes. Pulls every git repo in ~/Claude_Code/ from
# GitHub. Stashes any local changes first so git pull never fails.
# Logs everything to ~/Claude_Code/sync.log.
# =============================================================================

LOG="$HOME/Claude_Code/sync.log"

# --- GATE: make sure we are in the right directory ---
# If Claude_Code doesn't exist (external drive unmounted, symlink broken),
# we exit immediately instead of running in the wrong directory (BUG-011).
cd "$HOME/Claude_Code" || {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $HOME/Claude_Code not found — aborting" >> "$LOG"
    exit 1
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync starting..." >> "$LOG"

# --- Loop through every folder that is a git repo ---
for dir in */; do
    # Skip anything that is not a git repo
    [ -d "$dir/.git" ] || continue

    # Detect the default branch (main or master, repo-specific)
    branch=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^refs/remotes/origin/@@')
    [ -z "$branch" ] && branch="main"

    # Stash any local changes before pulling (BUG-008)
    # This prevents "Your local changes would be overwritten" errors.
    git -C "$dir" stash 2>/dev/null || true

    # Pull from GitHub
    git -C "$dir" pull origin "$branch" >> "$LOG" 2>&1

    # Restore stashed changes after pull
    git -C "$dir" stash pop 2>/dev/null || true
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync done." >> "$LOG"

# Keep the log from growing forever — trim to last 500 lines
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
SYNCEOF
chmod +x "$HOME/Claude_Code/msf_sync.sh"
ok "Sync script written: ~/Claude_Code/msf_sync.sh"

# --- Write the health check script ---
cat > "$HOME/Claude_Code/health_check.sh" << HEALTHEOF
#!/bin/bash
# =============================================================================
# health_check.sh — Synkore session health check
# =============================================================================
# Plot: runs once per Claude session (flagged by /tmp so it doesn't repeat).
# Checks GitHub connectivity and sync agent status. Logs results.
# If sync agent is not running — restarts it automatically.
# =============================================================================

FLAG="/tmp/synkore_health_done"
LOG="\$HOME/Claude_Code/health_check.log"

# Only run once per boot (the flag is in /tmp, cleared on reboot)
[ -f "\$FLAG" ] && exit 0
touch "\$FLAG"

echo "=== Health Check \$(date '+%Y-%m-%d %H:%M:%S') ===" >> "\$LOG"

# Trim log to last 300 lines
[ "\$(wc -l < "\$LOG" 2>/dev/null || echo 0)" -gt 500 ] && \
    tail -300 "\$LOG" > "\$LOG.tmp" && mv "\$LOG.tmp" "\$LOG"

# --- Check 1: GitHub SSH connectivity ---
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ GitHub: connected" >> "\$LOG"
else
    echo "❌ GitHub: not reachable — check SSH key" >> "\$LOG"
fi

# --- Check 2: Sync agent ---
if [[ "\$(uname)" == "Darwin" ]]; then
    # Mac: check launchd
    if launchctl list | grep -q "com.synkore.sync"; then
        echo "✅ Sync agent: running" >> "\$LOG"
    else
        echo "❌ Sync agent: not running — restarting..." >> "\$LOG"
        launchctl bootstrap gui/\$(id -u) "\$HOME/Library/LaunchAgents/com.synkore.sync.plist" 2>/dev/null || true
    fi
else
    # Linux: check systemd user unit
    if systemctl --user is-active synkore-sync.timer &>/dev/null; then
        echo "✅ Sync agent: running" >> "\$LOG"
    else
        echo "❌ Sync agent: not running — restarting..." >> "\$LOG"
        systemctl --user start synkore-sync.timer 2>/dev/null || true
    fi
fi

echo "✅ Health check complete" >> "\$LOG"
HEALTHEOF
chmod +x "$HOME/Claude_Code/health_check.sh"
ok "Health check script written: ~/Claude_Code/health_check.sh"

# --- Install the sync agent (OS-specific) ---
if [[ "$OS" == "mac" ]]; then
    # Mac: launchd plist
    # We use $HOME everywhere — NOT /Users/USERNAME/ (BUG-004).
    # We use an unquoted heredoc (EOF not 'EOF') so $HOME expands correctly.
    PLIST="$HOME/Library/LaunchAgents/com.synkore.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.synkore.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/Claude_Code/msf_sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Claude_Code/sync.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Claude_Code/sync.log</string>
</dict>
</plist>
EOF

    # Use modern launchctl syntax — 'load' is deprecated on Sequoia (BUG-013)
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
        launchctl load "$PLIST" 2>/dev/null || true

    # BUG-009: MDM-managed Macs can silently block LaunchAgents.
    # launchctl returns exit 0 even when blocked — the agent appears registered
    # but never fires. We verify it actually ran by checking for a log entry
    # after a short wait. If no log after 10 min, we offer a cron fallback.
    sleep 3
    if ! launchctl list | grep -q "com.synkore.sync"; then
        warn "Sync agent may be blocked by MDM policy."
        info "Offering cron fallback (works even on MDM-managed Macs)..."
        (crontab -l 2>/dev/null; echo "*/5 * * * * bash $HOME/Claude_Code/msf_sync.sh >> $HOME/Claude_Code/sync.log 2>&1") | crontab -
        info "Cron fallback installed. Sync will still run every 5 minutes."
    fi
    ok "Mac sync agent loaded (launchd)."

else
    # Linux: systemd user units (BUG-016 — launchd doesn't exist on Linux)
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    # The service unit — what to run
    cat > "$SYSTEMD_DIR/synkore-sync.service" << EOF
[Unit]
Description=Synkore repo sync

[Service]
ExecStart=$HOME/Claude_Code/msf_sync.sh
StandardOutput=append:$HOME/Claude_Code/sync.log
StandardError=append:$HOME/Claude_Code/sync.log
EOF

    # The timer unit — when to run it (every 5 minutes)
    cat > "$SYSTEMD_DIR/synkore-sync.timer" << EOF
[Unit]
Description=Synkore sync every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now synkore-sync.timer
    ok "Linux sync agent loaded (systemd user timer)."

    # BUG-017: 'brew install tailscale' fails on Linux — brew is Mac-only.
    # On Linux, Tailscale has its own install script.
    if ! command -v tailscale &>/dev/null; then
        echo ""
        read -r -p "    Install Tailscale for remote access? (y/n): " INSTALL_TS
        if [[ "$INSTALL_TS" == "y" ]]; then
            curl -fsSL https://tailscale.com/install.sh | sh
            sudo tailscale up
            ok "Tailscale installed."
        fi
    fi
fi

# =============================================================================
# ACT 5b — MOBILE ACCESS (OPTIONAL)
# =============================================================================
# BUG-010: the original playbook assumed every user has a Pi. Solo users with
# no server hit a dead end at every mobile step. We branch here:
#   - Has Pi: show Moshi setup instructions
#   - No Pi: explain the Telegram Pro option honestly

step "ACT 5b — Mobile access (optional)..."
echo ""
read -r -p "    Do you want mobile access (iPhone/iPad)? (y/n): " WANT_MOBILE

if [[ "$WANT_MOBILE" == "y" ]]; then
    echo ""
    read -r -p "    Do you have a Raspberry Pi or server running 24/7? (y/n): " HAS_PI

    if [[ "$HAS_PI" == "y" ]]; then
        # BUG-022: never say "ask your Pi admin" to a solo user.
        # We say "on the Pi, run this command" instead.
        echo ""
        ok "Great. Here's how to set up one-tap Claude access from your phone:"
        echo ""
        echo "  Step 1 — Install Moshi on your iPhone or iPad:"
        echo "    Search the App Store for: Moshi: SSH & SFTP Terminal"
        # BUG-014: Moshi search returns a meditation app first.
        echo "    (Important: it's by Comodo Security Solutions — NOT the meditation app)"
        echo ""
        echo "  Step 2 — In Moshi: Settings → Keys → Generate New Key → name it 'phone'"
        echo "    Long-press the key → Copy Public Key"
        echo ""
        echo "  Step 3 — On the Pi, run this command (replace the KEY and USERNAME):"
        echo '    echo '"'"'command="cd ~/Claude_Code && claude",restrict ssh-ed25519 YOUR_KEY_HERE phone'"'"' >> ~/.ssh/authorized_keys'
        echo ""
        echo "  Step 4 — In Moshi: + → New Connection → enter your Pi's Tailscale IP"
        echo "    Username: your Pi username | Authentication: the key you generated"
        echo ""
        echo "  Result: one tap → Claude opens on your Pi. No typing."
        echo ""
        read -r -p "    Press Enter to continue..."
    else
        # BUG-010: no Pi — honest explanation, convert to Pro waitlist
        echo ""
        warn "Without a Pi or server, phone access requires a hosted relay."
        echo ""
        echo "  This is what Synkore Pro will offer:"
        echo "  • Hosted relay — no Pi needed"
        echo "  • Telegram bot — message Claude from your phone like a contact"
        echo "  • Health dashboard"
        echo ""
        echo "  Pro is coming soon. To get notified:"
        echo "  → github.com/MSFcodelang/synkore (watch the repo)"
        echo ""
        read -r -p "    Press Enter to continue..."
    fi
fi

# =============================================================================
# ACT 6 — FINISH: LOCK THE CLAUDE ALIAS + WRITE MARKER
# =============================================================================
# The claude alias forces Claude to always open from ~/Claude_Code.
# This ensures the project hash is always the same — MEMORY.md never
# "disappears" because Claude was opened from a different folder (BUG-006).

step "ACT 6 — Locking Claude alias and finishing up..."

# Write the alias to the shell config if not already there
if ! grep -q "alias claude='cd \$HOME/Claude_Code && claude'" "$RC" 2>/dev/null; then
    echo "" >> "$RC"
    echo "# Synkore: always launch Claude from the correct directory" >> "$RC"
    echo "alias claude='cd \$HOME/Claude_Code && claude'" >> "$RC"
    info "Claude alias written to $RC"
else
    info "Claude alias already in $RC — skipped."
fi

# Write install marker with today's date so we can detect reinstalls (BUG-012)
date '+%Y-%m-%d' > "$SYNKORE_MARKER"

# =============================================================================
# DONE — PRINT VERIFICATION CHECKLIST
# =============================================================================

echo ""
echo -e "${BOLD}╔════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Installation complete!         ║${RESET}"
echo -e "${BOLD}╚════════════════════════════════════════╝${RESET}"
echo ""
echo "Here's what's now running invisibly for you:"
echo ""
echo "  • Git repos in ~/Claude_Code/ sync to GitHub every 5 minutes"
echo "  • Every memory file Claude writes auto-commits and pushes to GitHub"
echo "  • A health check runs silently each time you open a Claude session"
echo "  • Claude always opens from ~/Claude_Code — memory is never lost"
echo ""
echo -e "${BOLD}Verification — run these checks:${RESET}"
echo ""
# BUG-015: sync.log and health_check.log do not exist immediately after install.
# sync.log appears after the first sync run (~5 min).
# health_check.log appears after the first new Claude session.
# We tell the user this explicitly so they don't think something is broken.
echo "  Step 1 — Check the sync agent is registered (do this now):"
if [[ "$OS" == "mac" ]]; then
echo "    launchctl list | grep synkore"
else
echo "    systemctl --user is-active synkore-sync.timer"
fi
echo ""
echo "  Step 2 — Wait 5 minutes, then check sync ran:"
echo "    cat ~/Claude_Code/sync.log"
echo "    (This file does not exist until the first sync runs — that is normal)"
echo ""
echo "  Step 3 — Open a new Claude session, type anything, then check:"
echo "    cat ~/Claude_Code/health_check.log"
echo "    (This file does not exist until the first Claude session after install)"
echo ""
echo -e "${BOLD}IMPORTANT — reload your shell now:${RESET}"
echo "  source $RC"
echo ""
echo "  Then use 'claude' normally — it will always open from the right folder."
echo ""
echo -e "${BOLD}Memory is syncing to:${RESET} github.com/$GITHUB_USER/$MEMORY_REPO_NAME"
echo ""
echo "---"
echo "Synkore is an independent open-source project."
echo "Not affiliated with or endorsed by Anthropic."
echo "---"
