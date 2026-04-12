#!/bin/bash
# =============================================================================
# SYNKORE INSTALLER v2
# Copyright (c) 2026 Bosko Begovic — MIT License
# https://github.com/MSFcodelang/synkore
# =============================================================================
# The plot: this script turns any Mac or Linux machine into a Synkore node.
# It works when run directly (bash install.sh) AND when piped through curl
# (curl -fsSL .../install.sh | bash). All interactive prompts read from /dev/tty
# so they work even when stdin is the script pipe.
#
#   ACT 1 — Preflight:  check and install all required tools
#   ACT 2 — GitHub:     SSH key, git identity, gh authentication
#   ACT 3 — Memory:     create and connect the private memory repo on GitHub
#   ACT 4 — Hooks:      wire Claude to auto-commit every memory write
#   ACT 5 — Sync:       background agent that pulls repos every 5 minutes
#   ACT 5b — Mobile:    optional iPhone/iPad access instructions
#   ACT 6 — Finish:     lock the claude alias, write marker, print checklist
#
# Everything this script does can be undone. Nothing is permanent.
# =============================================================================

set -euo pipefail

# =============================================================================
# OUTPUT HELPERS
# =============================================================================
# We use printf instead of echo -e throughout.
# On macOS, /bin/bash is bash 3.2 — echo -e is NOT supported and prints the
# literal "-e" prefix on every line. printf is POSIX and works everywhere.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "${GREEN}✅  %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}⚠️   %s${RESET}\n" "$1"; }
fail() { printf "${RED}❌  %s${RESET}\n" "$1"; }
step() { printf "\n${BOLD}→ %s${RESET}\n" "$1"; }
info() { printf "    %s\n" "$1"; }

# =============================================================================
# TTY-SAFE READ
# =============================================================================
# When the script is run via `curl | bash`, bash's stdin is the script itself.
# A plain `read` call would get EOF immediately and exit non-zero — set -e
# would then kill the entire install on the first prompt.
#
# The fix: redirect read from /dev/tty — the actual terminal — instead of stdin.
# This is the same technique used by rustup, nvm, and Homebrew.
# The prompt (-p) still goes to stderr (visible to user); input comes from /dev/tty.
#
# Usage: tty_read VARNAME "Prompt text: "
tty_read() {
    local varname="$1"
    local prompt="$2"
    local val=""
    printf "%s" "$prompt" >/dev/tty
    read -r val </dev/tty
    printf -v "$varname" '%s' "$val"
}

# =============================================================================
# CROSS-PLATFORM TIMEOUT
# =============================================================================
# 'timeout' is a GNU coreutils command — available on Linux by default,
# NOT available on macOS unless Homebrew coreutils is installed (as 'gtimeout').
# We try timeout, then gtimeout, then fall back to running without timeout.
safe_timeout() {
    local duration="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$duration" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$duration" "$@"
    else
        "$@"
    fi
}

# =============================================================================
# ACT 0a — OS DETECTION
# =============================================================================
OS=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="mac"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
else
    fail "Unsupported OS: $OSTYPE"
    info "Synkore supports macOS and Linux (Debian/Ubuntu)."
    exit 1
fi

# Detect shell config file — Mac defaults to zsh, Linux to bash (BUG-018)
RC=""
if [[ "$SHELL" == */zsh ]]; then
    RC="$HOME/.zshrc"
else
    RC="$HOME/.bashrc"
fi

# =============================================================================
# ACT 0b — PYTHON 3 CHECK
# =============================================================================
# On macOS before Xcode CLT, /usr/bin/python3 is a stub that pops a dialog.
# On some systems, 'python3' is aliased to Python 2.
# We verify we have real Python 3 before going further.
_PYTHON3=""
for _py in python3 python3.11 python3.10 python3.9; do
    if command -v "$_py" &>/dev/null; then
        if "$_py" -c "import sys; sys.exit(0 if sys.version_info.major == 3 else 1)" 2>/dev/null; then
            _PYTHON3="$_py"
            break
        fi
    fi
done

# =============================================================================
# WELCOME
# =============================================================================
printf "\n"
printf "${BOLD}╔════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║        Welcome to Synkore              ║${RESET}\n"
printf "${BOLD}║  One command. Your Claude, everywhere. ║${RESET}\n"
printf "${BOLD}╚════════════════════════════════════════╝${RESET}\n"
printf "\n"
# BUG-021: state reversibility upfront to prevent hesitation and abandonment
info "Everything this installer does can be undone in a few minutes."
info "Nothing is permanent."
printf "\n"

# =============================================================================
# ACT 0c — IDEMPOTENCY CHECK (BUG-012)
# =============================================================================
# If Synkore is already installed, running again would duplicate hooks and
# possibly add duplicate cron entries. Detect and ask what to do.

SYNKORE_MARKER="$HOME/.synkore_installed"
if [[ -f "$SYNKORE_MARKER" ]]; then
    warn "Synkore is already installed on this machine (installed: $(cat "$SYNKORE_MARKER"))."
    printf "\n"
    printf "    What would you like to do?\n"
    printf "      1) Update existing install (remove old hooks, apply fresh)\n"
    printf "      2) Exit\n\n"
    REINSTALL_CHOICE=""
    tty_read REINSTALL_CHOICE "    Enter 1 or 2: "
    if [[ "$REINSTALL_CHOICE" != "1" ]]; then
        info "Exiting. Nothing changed."
        exit 0
    fi

    # Remove old Synkore hooks from settings.json (BUG-012)
    # We do this before the backup so the backup is clean.
    step "Removing old hooks before update..."
    if [[ -f "$HOME/.claude/settings.json" ]] && [[ -n "$_PYTHON3" ]]; then
        "$_PYTHON3" - <<'PYEOF'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f"Could not read settings.json: {e}")
    sys.exit(0)  # Don't abort — just skip cleanup
hooks = cfg.get("hooks", {})
for event in ["PostToolUse", "UserPromptSubmit"]:
    if event in hooks:
        hooks[event] = [
            h for h in hooks[event]
            if "synkore" not in str(h).lower()
            and "Syncing memory" not in str(h)
            and "health_check" not in str(h)
        ]
cfg["hooks"] = hooks
try:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("Old Synkore hooks removed.")
except Exception as e:
    print(f"Could not write settings.json: {e}")
PYEOF
    fi
    ok "Old install cleaned."
fi

# =============================================================================
# ACT 1 — PREFLIGHT: CHECK AND INSTALL REQUIRED TOOLS
# =============================================================================
# We check every tool before touching anything.
# A missing tool is caught here, installed, and the script continues.
# No silently missing tool = no silent failure later (BUG-001, BUG-007, BUG-019).

step "ACT 1 — Checking required tools..."

# --- GATE 1: git ---
# On a fresh Mac, 'git' triggers a dialog to install Xcode CLT.
# We intercept this and handle it explicitly (BUG-007).
if ! command -v git &>/dev/null; then
    warn "git is not installed."
    if [[ "$OS" == "mac" ]]; then
        info "A dialog will appear — click Install and wait for it to finish."
        info "Do NOT press Enter here until the Xcode installation dialog is complete."
        xcode-select --install 2>/dev/null || true
        tty_read _DUMMY "    Press Enter only after Xcode tools installation is complete: "
    else
        info "Installing git..."
        sudo apt-get update -qq && sudo apt-get install -y -qq git
    fi
fi
ok "git: $(git --version)"

# --- GATE 2: jq ---
# jq is used by the memory hook to parse Claude's tool output JSON.
# It is NOT installed by default on Mac or most Linux distros (BUG-001, BUG-019).
# Without jq, every memory write silently does nothing.
if ! command -v jq &>/dev/null; then
    warn "jq is not installed — installing now..."
    if [[ "$OS" == "mac" ]]; then
        if ! command -v brew &>/dev/null; then
            fail "Homebrew is required to install jq on Mac."
            info "Install Homebrew first: https://brew.sh — then re-run this installer."
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
    if [[ "$OS" == "linux" ]]; then
        sudo apt-get install -y -qq curl
    fi
fi
ok "curl: present"

# --- GATE 4: gh (GitHub CLI) ---
# gh is used to create the private memory repo automatically (BUG-003).
if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) not installed — installing..."
    if [[ "$OS" == "mac" ]]; then
        brew install gh
    else
        # Download to a tempfile first so a failed/interrupted download
        # does not leave a zero-byte or corrupt keyring file (BUG-Network-3).
        # A zero-byte keyring file poisons ALL future apt operations permanently.
        _GPG_TMPFILE=$(mktemp)
        curl --max-time 30 --connect-timeout 10 -fsSL \
            https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            -o "$_GPG_TMPFILE"
        # Verify the file is non-empty before installing as a trusted key
        if [[ ! -s "$_GPG_TMPFILE" ]]; then
            fail "Failed to download gh CLI GPG key — file is empty."
            rm -f "$_GPG_TMPFILE"
            exit 1
        fi
        sudo dd if="$_GPG_TMPFILE" of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        rm -f "$_GPG_TMPFILE"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq gh
    fi
fi
ok "gh: $(gh --version | head -1)"

# --- GATE 5: Claude Code ---
# We check for 'claude' using 'command -v' which bypasses any alias.
if ! command -v claude &>/dev/null; then
    fail "Claude Code is not installed."
    printf "\n"
    info "Install Claude Code first: https://claude.ai/code"
    info "Then re-run this installer."
    exit 1
fi
ok "Claude Code: present"

# --- GATE 6: Python 3 ---
if [[ -z "$_PYTHON3" ]]; then
    fail "Python 3 is required but not found (or 'python3' points to Python 2)."
    if [[ "$OS" == "mac" ]]; then
        info "Install Python 3: brew install python3"
    else
        info "Install Python 3: sudo apt-get install python3"
    fi
    exit 1
fi
ok "Python 3: $($_PYTHON3 --version)"

# =============================================================================
# ACT 2 — GITHUB: SSH KEY + GIT IDENTITY + GH AUTHENTICATION
# =============================================================================

step "ACT 2 — Setting up GitHub authentication..."

# --- Git identity ---
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)

if [[ -z "$GIT_NAME" ]]; then
    tty_read GIT_NAME "    Your name (for git commits): "
    git config --global user.name "$GIT_NAME"
fi
if [[ -z "$GIT_EMAIL" ]]; then
    tty_read GIT_EMAIL "    Your email (for git commits): "
    git config --global user.email "$GIT_EMAIL"
fi
ok "Git identity: $GIT_NAME <$GIT_EMAIL>"

# --- GitHub username ---
# BUG-030: validate — empty username crashes everything downstream
printf "\n"
GITHUB_USER=""
while [[ -z "$GITHUB_USER" ]]; do
    tty_read GITHUB_USER "    Your GitHub username (required): "
done

# --- SSH key ---
# We prefer ed25519 — modern, fast, small. If a key exists, reuse it.
SSH_KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ -f "$SSH_KEY" ]]; then
    ok "SSH key already exists — reusing: $SSH_KEY"
else
    info "Generating SSH key..."
    ssh-keygen -t ed25519 -C "$GITHUB_USER" -f "$SSH_KEY" -N ""
    # BUG-020: the randomart output looks alarming to non-technical users.
    printf "\n"
    info "The pattern above is normal — it is a visual fingerprint of your key. Ignore it."
fi

# --- ssh-agent + keychain setup (BUG-005, BUG-027) ---
# On Mac: store key in Keychain so it survives reboots.
# On Linux: start ssh-agent if not already running, then add key.
if [[ "$OS" == "mac" ]]; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || ssh-add "$SSH_KEY" 2>/dev/null || true
else
    # BUG-027: on Linux, no ssh-agent may be running (headless Pi/VPS).
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" > /dev/null 2>&1
    fi
    ssh-add "$SSH_KEY" 2>/dev/null || true
fi

# --- Write ~/.ssh/config (BUG-026) ---
# UseKeychain is macOS-only. Writing it on Linux causes:
# "Bad configuration option: usekeychain" on every SSH call,
# which fails the ssh -T verification and exits the script.
# We also add ConnectTimeout to prevent infinite hangs on network ops.
SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
    if [[ "$OS" == "mac" ]]; then
        cat >> "$SSH_CONFIG" << EOF

Host github.com
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile $SSH_KEY
    ConnectTimeout 30
EOF
    else
        cat >> "$SSH_CONFIG" << EOF

Host github.com
    AddKeysToAgent yes
    IdentityFile $SSH_KEY
    ConnectTimeout 30
EOF
    fi
    chmod 600 "$SSH_CONFIG"
    info "SSH config written."
fi

# --- Pre-populate known_hosts with GitHub's verified fingerprint ---
# BUG-029: on a fresh machine, GitHub's host key is not in known_hosts.
# ssh -T would show "Are you sure you want to continue connecting?" — an
# interactive prompt that hangs or fails in a script context.
#
# SECURITY NOTE (from web research agent): blind ssh-keyscan is a MITM risk.
# The right approach is to compare against GitHub's known published fingerprint.
# GitHub publishes their SSH key fingerprints at:
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
#
# We scan and then verify the fingerprint matches GitHub's published key.
info "Adding GitHub to known hosts (with fingerprint verification)..."
_SCAN_TMP=$(mktemp)
safe_timeout 15 ssh-keyscan -H github.com > "$_SCAN_TMP" 2>/dev/null || true

if [[ -s "$_SCAN_TMP" ]]; then
    # Verify the scanned key matches GitHub's published ed25519 fingerprint
    _SCANNED_FP=$(ssh-keygen -lf "$_SCAN_TMP" 2>/dev/null | grep ed25519 | awk '{print $2}' || true)
    _GITHUB_KNOWN_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
    if [[ "$_SCANNED_FP" == "$_GITHUB_KNOWN_FP" ]]; then
        cat "$_SCAN_TMP" >> "$HOME/.ssh/known_hosts"
        ok "GitHub host key verified and cached."
    else
        warn "GitHub host key fingerprint mismatch — not caching (possible MITM)."
        warn "Expected: $_GITHUB_KNOWN_FP"
        warn "Got:      $_SCANNED_FP"
        info "You can add it manually: ssh-keyscan -H github.com >> ~/.ssh/known_hosts"
    fi
fi
rm -f "$_SCAN_TMP"

# --- Show public key, wait for GitHub confirmation ---
printf "\n"
printf "${BOLD}Add this SSH key to your GitHub account:${RESET}\n"
printf "  Go to: ${BOLD}github.com → Settings → SSH and GPG keys → New SSH key${RESET}\n\n"
cat "${SSH_KEY}.pub"
printf "\n"
tty_read _DUMMY "Press Enter once you have added the key to GitHub: "

# --- Verify the key works ---
info "Verifying connection to GitHub..."
if safe_timeout 30 ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    ok "GitHub: authenticated as $GITHUB_USER"
else
    fail "Could not authenticate with GitHub."
    info "Make sure you added the key above to your GitHub account, then try again."
    exit 1
fi

# --- Authenticate gh CLI (BUG-024) ---
# gh is installed in ACT 1 but needs authentication before it can create repos.
# gh repo view and gh repo create both fail silently without this.
info "Checking gh authentication..."
if ! gh auth status &>/dev/null; then
    printf "\n"
    info "The GitHub CLI needs to authenticate."
    info "A browser window will open — log in and approve."
    printf "\n"
    gh auth login --git-protocol ssh --web </dev/tty
fi
ok "gh: authenticated"

# =============================================================================
# ACT 3 — MEMORY REPO: CREATE + CONNECT + PUSH
# =============================================================================
# The memory hook pushes to a private GitHub repo on every memory write.
# That repo must exist and have a git remote + tracking branch configured
# BEFORE the hook activates — otherwise every push fails silently (BUG-003).

step "ACT 3 — Setting up memory repository..."

MEMORY_REPO_NAME="synkore-memory"
MEMORY_REMOTE="git@github.com:${GITHUB_USER}/${MEMORY_REPO_NAME}.git"

# Find or create the Claude project memory directory.
#
# Claude Code stores project state in ~/.claude/projects/[hash]/
# where the hash is derived from the working directory.
# We lock Claude to ~/Claude_Code via alias (ACT 6), so the hash will always
# be based on that path. But we cannot know the hash before Claude runs.
#
# SELF-HEALING DESIGN: instead of trying to guess the hash, we bake the
# GitHub username into the hook command itself (below). The hook auto-initializes
# the git remote the FIRST time it fires — even if our memory dir detection
# here is imperfect, the first Claude session self-corrects.
#
# We still set up a git repo in the best candidate memory dir so the FIRST
# session is already wired up correctly if our detection succeeds.

CLAUDE_PROJECTS="$HOME/.claude/projects"

# Try to find an existing memory dir (any project with a MEMORY.md)
MEMORY_DIR=""
if [[ -d "$CLAUDE_PROJECTS" ]]; then
    MEMORY_DIR=$(find "$CLAUDE_PROJECTS" -name "MEMORY.md" -maxdepth 3 2>/dev/null \
        | head -1 | xargs dirname 2>/dev/null || true)
fi

# If no memory dir found: create one under the first existing project hash,
# or make a staging dir that the hook will move from on first fire.
if [[ -z "$MEMORY_DIR" ]]; then
    if [[ -d "$CLAUDE_PROJECTS" ]]; then
        _FIRST_HASH=$(ls "$CLAUDE_PROJECTS" 2>/dev/null | head -1)
        if [[ -n "$_FIRST_HASH" ]]; then
            MEMORY_DIR="$CLAUDE_PROJECTS/$_FIRST_HASH/memory"
        fi
    fi
    if [[ -z "$MEMORY_DIR" ]]; then
        # No Claude project exists yet — create a staging location.
        # The hook will set up the remote correctly when Claude first runs.
        MEMORY_DIR="$HOME/.claude/synkore-memory-staging"
    fi
fi

mkdir -p "$MEMORY_DIR"
ok "Memory folder: $MEMORY_DIR"

# Initialize git in the memory folder if not already done
if [[ ! -d "$MEMORY_DIR/.git" ]]; then
    git -C "$MEMORY_DIR" init
    git -C "$MEMORY_DIR" checkout -b main 2>/dev/null || true
fi

# Create starter files if they don't exist
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

# Create or connect the GitHub memory repo
info "Checking for memory repo on GitHub..."
if gh repo view "$GITHUB_USER/$MEMORY_REPO_NAME" &>/dev/null; then
    info "Memory repo already exists on GitHub — connecting."
else
    info "Creating private memory repo on GitHub..."
    gh repo create "$GITHUB_USER/$MEMORY_REPO_NAME" \
        --private \
        --description "Synkore memory sync" 2>/dev/null
    ok "Memory repo created: github.com/$GITHUB_USER/$MEMORY_REPO_NAME"
fi

# Connect local memory dir to the remote repo (BUG-003)
if ! git -C "$MEMORY_DIR" remote get-url origin &>/dev/null; then
    git -C "$MEMORY_DIR" remote add origin "$MEMORY_REMOTE"
    info "Remote added."
fi

# Initial commit + push to establish the upstream branch (BUG-003)
# Without this, every 'git push' fails with "no upstream branch".
git -C "$MEMORY_DIR" add . 2>/dev/null || true
git -C "$MEMORY_DIR" commit -m "Synkore: initial memory setup" 2>/dev/null || true
# Use --force-with-lease to handle the case where the remote already has commits
# (e.g., user is reinstalling after a previous partial attempt) (BUG-031)
git -C "$MEMORY_DIR" push -u origin main --force-with-lease 2>/dev/null || \
    git -C "$MEMORY_DIR" push --set-upstream origin main --force-with-lease 2>/dev/null || true

ok "Memory repo connected."

# =============================================================================
# ACT 4 — CLAUDE HOOKS: WIRE MEMORY AUTO-SYNC
# =============================================================================
# The PostToolUse hook fires after every file write Claude makes.
# If the file is inside a memory folder, it commits and pushes to GitHub.
# The UserPromptSubmit hook runs the health check at session start.
#
# CRITICAL: we MERGE into existing settings.json, never overwrite (BUG-002).
# We use Python (always available) to do the JSON merge safely.
# CRITICAL: we use a QUOTED heredoc ('PYEOF') so no shell expansion happens
# inside the Python source — hook commands are passed via env vars (BUG-025).

step "ACT 4 — Wiring Claude memory hooks..."

SETTINGS="$HOME/.claude/settings.json"

# Back up existing settings before touching anything (BUG-002)
if [[ -f "$SETTINGS" ]]; then
    BACKUP="${SETTINGS}.bak.$(date +%s)"
    cp "$SETTINGS" "$BACKUP"
    info "Backed up settings.json → $BACKUP"
else
    printf '{}' > "$SETTINGS"
fi

# The PostToolUse hook — fires on every file write by Claude.
# Self-healing design: if the memory dir has no git remote (wrong hash at install
# time, or first run after install), the hook auto-initializes it (baking in
# GITHUB_USER and MEMORY_REPO_NAME at install time so the hook is self-contained).
export SYNKORE_MEMORY_HOOK="jq -r '.tool_input.file_path // empty' | { read -r f; echo \"\$f\" | grep -qE '.claude/projects/.+/memory' || exit 0; REPO=\$(dirname \"\$f\"); while [ \"\$REPO\" != \"/\" ] && [ ! -d \"\$REPO/.git\" ]; do REPO=\$(dirname \"\$REPO\"); done; [ -d \"\$REPO/.git\" ] || exit 0; if ! git -C \"\$REPO\" remote get-url origin &>/dev/null; then git -C \"\$REPO\" remote add origin git@github.com:${GITHUB_USER}/${MEMORY_REPO_NAME}.git && git -C \"\$REPO\" push -u origin main --force-with-lease 2>/dev/null; fi; cd \"\$REPO\" 2>/dev/null || exit 0; git add . && git commit -m \"Auto-sync memory \$(date '+%Y-%m-%d %H:%M')\" && git push; } 2>/dev/null || true"

# The UserPromptSubmit hook — runs health check silently at session start.
export SYNKORE_HEALTH_HOOK="bash $HOME/Claude_Code/health_check.sh >> /dev/null 2>&1 &"

# Merge hooks into settings.json using Python.
# Quoted heredoc ('PYEOF') prevents ANY shell expansion inside Python source.
# Hook commands arrive via environment variables — clean string values, no escaping.
"$_PYTHON3" - <<'PYEOF'
import json, os, sys

path = os.path.expanduser("~/.claude/settings.json")

# BUG: malformed settings.json — wrap load in try/except with user-readable error
try:
    with open(path) as f:
        cfg = json.load(f)
except json.JSONDecodeError as e:
    print(f"ERROR: ~/.claude/settings.json is not valid JSON: {e}")
    print("Fix: open that file, validate the JSON (e.g. with jsonlint.com), then re-run.")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: could not read ~/.claude/settings.json: {e}")
    sys.exit(1)

hooks = cfg.setdefault("hooks", {})

# Read hook commands from environment variables (never shell-expanded here)
try:
    memory_cmd = os.environ["SYNKORE_MEMORY_HOOK"]
    health_cmd  = os.environ["SYNKORE_HEALTH_HOOK"]
except KeyError as e:
    print(f"ERROR: required environment variable not set: {e}")
    sys.exit(1)

# --- PostToolUse hook ---
post_hooks = hooks.setdefault("PostToolUse", [])
memory_hook = {
    "matcher": "Write",
    "hooks": [{
        "type": "command",
        "command": memory_cmd,
        "timeout": 120,
        "statusMessage": "Syncing memory..."
    }]
}
# Idempotency: only add if not already present (BUG-012)
already_has_memory_hook = any("Syncing memory" in str(h) for h in post_hooks)
if not already_has_memory_hook:
    post_hooks.append(memory_hook)
    print("PostToolUse memory hook added.")
else:
    print("PostToolUse memory hook already present — skipped.")

# --- UserPromptSubmit hook ---
submit_hooks = hooks.setdefault("UserPromptSubmit", [])
health_hook = {
    "matcher": "",
    "hooks": [{"type": "command", "command": health_cmd}]
}
already_has_health_hook = any("health_check" in str(h) for h in submit_hooks)
if not already_has_health_hook:
    submit_hooks.append(health_hook)
    print("UserPromptSubmit health hook added.")
else:
    print("UserPromptSubmit health hook already present — skipped.")

try:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("settings.json updated.")
except Exception as e:
    print(f"ERROR: could not write settings.json: {e}")
    sys.exit(1)
PYEOF

ok "Claude hooks wired."

# =============================================================================
# ACT 5 — SYNC AGENT: BACKGROUND REPO SYNC EVERY 5 MINUTES
# =============================================================================

step "ACT 5 — Installing background sync agent..."

mkdir -p "$HOME/Claude_Code"

# --- Write msf_sync.sh ---
cat > "$HOME/Claude_Code/msf_sync.sh" << 'SYNCEOF'
#!/bin/bash
# =============================================================================
# msf_sync.sh — Synkore background sync script
# =============================================================================
# Plot: runs every 5 minutes. For every git repo in ~/Claude_Code/, it pulls
# the latest changes from GitHub. Handles uncommitted local changes safely by
# checking git status before stashing — prevents corrupting unrelated stashes.
# Logs everything to sync.log. Trims the log when it grows too large.
# =============================================================================

LOG="$HOME/Claude_Code/sync.log"

# GATE: abort if Claude_Code can't be reached (external drive, symlink broken)
cd "$HOME/Claude_Code" || {
    printf "[%s] ERROR: $HOME/Claude_Code not found — aborting\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
    exit 1
}

printf "[%s] Sync starting...\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

for dir in */; do
    [ -d "$dir/.git" ] || continue

    # Detect the actual default branch from the remote.
    # Don't assume 'main' — many repos still use 'master' (BUG-sync-4).
    branch=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
        | grep "^ref:" | sed 's|ref: refs/heads/||;s|\s.*||')
    # Fall back to symbolic-ref if ls-remote didn't work
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
            | sed 's@^refs/remotes/origin/@@')
    fi
    # Final fallback: try current branch
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    fi

    # Safe stash: only stash if there are actual local changes (BUG-sync-3).
    # Unconditional 'git stash' pushes an empty entry onto the stash stack.
    # Then 'git stash pop' pops the PREVIOUS session's stash, corrupting
    # a different repo's working tree.
    STASHED=false
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
        git -C "$dir" stash push -m "synkore-autostash" 2>/dev/null && STASHED=true
    fi

    git -C "$dir" pull origin "$branch" >> "$LOG" 2>&1

    if [[ "$STASHED" == "true" ]]; then
        git -C "$dir" stash pop 2>/dev/null || true
    fi
done

printf "[%s] Sync done.\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

# Safe log trim: use if block so a failed tail doesn't destroy the log (BUG-sync-6)
_LOG_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
if [[ "$_LOG_LINES" -gt 500 ]]; then
    if tail -300 "$LOG" > "$LOG.tmp"; then
        mv "$LOG.tmp" "$LOG"
    else
        rm -f "$LOG.tmp"  # clean up partial file, keep original
    fi
fi
SYNCEOF
chmod +x "$HOME/Claude_Code/msf_sync.sh"
ok "Sync script written."

# --- Write health_check.sh ---
# Note: this heredoc uses $HOME which expands at write time (install) — intentional.
# The script is written with the correct absolute path baked in.
cat > "$HOME/Claude_Code/health_check.sh" << HEALTHEOF
#!/bin/bash
# =============================================================================
# health_check.sh — Synkore session health check
# =============================================================================
# Plot: runs once per Claude session (flagged by /tmp, cleared on reboot).
# Checks GitHub SSH and sync agent. Restarts sync agent if not running.
# Logs to health_check.log.
# =============================================================================

# Atomic single-instance gate using mkdir (race-condition safe vs touch) (BUG-hc-9)
LOCK="/tmp/synkore_health_lock"
mkdir "\$LOCK" 2>/dev/null || exit 0
trap 'rmdir "\$LOCK" 2>/dev/null' EXIT

LOG="\$HOME/Claude_Code/health_check.log"

printf "=== Health Check %s ===\n" "\$(date '+%Y-%m-%d %H:%M:%S')" >> "\$LOG"

# Safe log trim (BUG-hc-6)
_LOG_LINES=\$(wc -l < "\$LOG" 2>/dev/null || echo 0)
if [[ "\$_LOG_LINES" -gt 500 ]]; then
    if tail -300 "\$LOG" > "\$LOG.tmp"; then
        mv "\$LOG.tmp" "\$LOG"
    else
        rm -f "\$LOG.tmp"
    fi
fi

# Check 1: GitHub SSH connectivity (with timeout)
if ssh -o ConnectTimeout=10 -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    printf "✅ GitHub: connected\n" >> "\$LOG"
else
    printf "❌ GitHub: not reachable — check SSH key\n" >> "\$LOG"
fi

# Check 2: Sync agent (BUG-hc-7: handle both old and new macOS launchctl output formats)
if [[ "\$(uname)" == "Darwin" ]]; then
    # On macOS 13+, 'launchctl list' shows just the label in column 3.
    # On older macOS, same format. 'launchctl print' shows gui/UID/ prefix.
    # We check both patterns to be safe.
    if launchctl list 2>/dev/null | grep -qE "com\.synkore\.sync" || \
       launchctl print "gui/\$(id -u)/com.synkore.sync" &>/dev/null; then
        printf "✅ Sync agent: running\n" >> "\$LOG"
    else
        printf "❌ Sync agent: not running — restarting...\n" >> "\$LOG"
        launchctl bootstrap "gui/\$(id -u)" "\$HOME/Library/LaunchAgents/com.synkore.sync.plist" 2>/dev/null || \
            launchctl load "\$HOME/Library/LaunchAgents/com.synkore.sync.plist" 2>/dev/null || true
    fi
else
    # Linux: BUG-hc-8: systemctl --user may fail on headless Pi without D-Bus.
    # We check exit code and handle gracefully.
    if systemctl --user is-active synkore-sync.timer &>/dev/null 2>&1; then
        printf "✅ Sync agent: running\n" >> "\$LOG"
    else
        printf "❌ Sync agent: not running — restarting...\n" >> "\$LOG"
        systemctl --user start synkore-sync.timer 2>/dev/null || true
    fi
fi

printf "✅ Health check complete\n" >> "\$LOG"
HEALTHEOF
chmod +x "$HOME/Claude_Code/health_check.sh"
ok "Health check script written."

# --- Install the OS-specific sync agent ---
if [[ "$OS" == "mac" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.synkore.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    # BUG-004: use $HOME everywhere — NEVER /Users/USERNAME/.
    # BUG-013: use modern launchctl bootstrap, with fallback to load.
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

    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
        launchctl load "$PLIST" 2>/dev/null || true

    # BUG-009: MDM-managed Macs can silently block LaunchAgents.
    # launchctl returns exit 0 even when blocked. Verify with a different approach.
    sleep 3
    if ! launchctl list 2>/dev/null | grep -qE "com\.synkore\.sync" && \
       ! launchctl print "gui/$(id -u)/com.synkore.sync" &>/dev/null; then
        warn "Sync agent may be blocked by MDM. Installing cron fallback..."
        # BUG-035: deduplicate cron entries on reinstall
        # BUG-env-9: quote the path in case $HOME has spaces
        ( crontab -l 2>/dev/null | grep -v "msf_sync.sh";
          printf '*/5 * * * * bash "%s/Claude_Code/msf_sync.sh" >> "%s/Claude_Code/sync.log" 2>&1\n' \
              "$HOME" "$HOME" ) | crontab -
        info "Cron fallback installed."
    fi
    ok "Mac sync agent loaded."

else
    # Linux: systemd user units (BUG-016)
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/synkore-sync.service" << EOF
[Unit]
Description=Synkore repo sync

[Service]
ExecStart=$HOME/Claude_Code/msf_sync.sh
StandardOutput=append:$HOME/Claude_Code/sync.log
StandardError=append:$HOME/Claude_Code/sync.log
EOF

    cat > "$SYSTEMD_DIR/synkore-sync.timer" << EOF
[Unit]
Description=Synkore sync every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOF

    # BUG-028: on headless Pi/VPS, systemd --user requires a D-Bus user session.
    # loginctl enable-linger creates a persistent user session that survives
    # without an active login — required for user services to work at boot.
    loginctl enable-linger "$USER" 2>/dev/null || true
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now synkore-sync.timer 2>/dev/null || true
    ok "Linux sync agent loaded."

    # BUG-017: Tailscale on Linux — do NOT curl | sh inside an already-running
    # curl | bash installer (nested pipe + no checksum = critical security risk).
    # Instead: offer a link to the official install.
    printf "\n"
    info "Optional: install Tailscale for remote access from any network."
    info "Official installer: https://tailscale.com/install"
    info "(Run it separately, not here — their installer requires interactive steps.)"
fi

# =============================================================================
# ACT 5b — MOBILE ACCESS (OPTIONAL)
# =============================================================================
# BUG-010: original playbook assumed every user has a Pi. Users without a Pi
# hit a dead end. We branch: Pi → Moshi setup; no Pi → honest Pro waitlist info.

step "ACT 5b — Mobile access (optional)..."
printf "\n"
WANT_MOBILE=""
tty_read WANT_MOBILE "    Do you want mobile access (iPhone/iPad)? (y/n): "

if [[ "$WANT_MOBILE" == "y" ]]; then
    HAS_PI=""
    tty_read HAS_PI "    Do you have a Raspberry Pi or server running 24/7? (y/n): "

    if [[ "$HAS_PI" == "y" ]]; then
        printf "\n"
        ok "Here's how to set up one-tap Claude access from your phone:"
        printf "\n"
        printf "  Step 1 — Install Moshi on your iPhone/iPad:\n"
        # BUG-014: Moshi search returns a meditation app first
        printf "    Search App Store for: Moshi: SSH & SFTP Terminal\n"
        printf "    (by Comodo Security Solutions — NOT the meditation app)\n\n"
        printf "  Step 2 — In Moshi: Settings → Keys → Generate New Key → name it 'phone'\n"
        printf "    Long-press the key → Copy Public Key\n\n"
        # BUG-022: say "On the Pi, run this" not "ask your Pi admin"
        printf "  Step 3 — On the Pi, run this command (paste your key):\n"
        printf '    echo '"'"'command="cd ~/Claude_Code && command claude",restrict ssh-ed25519 YOUR_KEY_HERE phone'"'"' >> ~/.ssh/authorized_keys\n\n'
        printf "  Step 4 — In Moshi: + → New Connection → enter your Pi's Tailscale IP\n"
        printf "    Username: your Pi username | Auth: the key from Step 2\n\n"
        printf "  Result: one tap → Claude opens on Pi, full context, no typing.\n\n"
        tty_read _DUMMY "    Press Enter to continue..."
    else
        # BUG-010: no Pi path
        printf "\n"
        warn "Without a Pi or server, phone access requires a hosted relay."
        printf "\n"
        printf "  This is what Synkore Pro will offer:\n"
        printf "  • Hosted relay — no Pi needed\n"
        printf "  • Telegram bot — message Claude from your phone\n"
        printf "  • Health dashboard\n\n"
        printf "  Pro is coming soon → watch: github.com/MSFcodelang/synkore\n\n"
        tty_read _DUMMY "    Press Enter to continue..."
    fi
fi

# =============================================================================
# ACT 6 — FINISH: CLAUDE ALIAS + MARKER
# =============================================================================
# The alias forces Claude to always open from ~/Claude_Code.
# This ensures the project hash is always the same — MEMORY.md never
# "disappears" because Claude was opened from a different folder (BUG-006).
#
# BUG-023: the alias must use 'command claude' not 'claude' — otherwise
# the alias calls itself recursively (infinite loop).
#
# BUG-alias-grep: the grep check must match the EXACT string we write.
# Previous version checked for 'claude' but wrote 'command claude' — mismatch
# caused duplicate alias lines to accumulate on every reinstall.

step "ACT 6 — Locking Claude alias and finishing up..."

ALIAS_LINE="alias claude='cd \$HOME/Claude_Code && command claude'"
if ! grep -qF "command claude" "$RC" 2>/dev/null; then
    printf "\n# Synkore: always launch Claude from the correct directory\n" >> "$RC"
    printf "%s\n" "$ALIAS_LINE" >> "$RC"
    info "Claude alias written to $RC"
else
    info "Claude alias already in $RC — skipped."
fi

# Write install marker
date '+%Y-%m-%d' > "$SYNKORE_MARKER"

# =============================================================================
# DONE — VERIFICATION CHECKLIST
# =============================================================================

printf "\n"
printf "${BOLD}╔════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║         Installation complete!         ║${RESET}\n"
printf "${BOLD}╚════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "Here's what's now running invisibly for you:\n\n"
printf "  • Git repos in ~/Claude_Code/ sync to GitHub every 5 minutes\n"
printf "  • Every memory file Claude writes auto-commits and pushes to GitHub\n"
printf "  • A health check runs silently each time you open Claude\n"
printf "  • Claude always opens from ~/Claude_Code — memory is never lost\n\n"

printf "${BOLD}Now do these three things:${RESET}\n\n"
printf "  1. Reload your shell:\n"
printf "     source %s\n\n" "$RC"
printf "  2. Open Claude once with the new alias:\n"
printf "     claude\n\n"
printf "  3. After 5 minutes, verify sync is running:\n"

if [[ "$OS" == "mac" ]]; then
printf "     launchctl list | grep synkore\n"
else
printf "     systemctl --user is-active synkore-sync.timer\n"
fi

# BUG-015: logs do not exist until after the first sync and first Claude session.
# Tell the user this explicitly so they don't think something is broken.
printf "\n"
printf "${BOLD}Verification logs (they appear after first use — that is normal):${RESET}\n\n"
printf "  # After 5 minutes:\n"
printf "  cat ~/Claude_Code/sync.log\n\n"
printf "  # After first new Claude session:\n"
printf "  cat ~/Claude_Code/health_check.log\n\n"

printf "  Memory syncing to: github.com/%s/%s\n\n" "$GITHUB_USER" "$MEMORY_REPO_NAME"

printf "---\n"
printf "Synkore is an independent open-source project.\n"
printf "Not affiliated with or endorsed by Anthropic.\n"
printf "---\n\n"
