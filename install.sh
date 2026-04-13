#!/bin/bash
# =============================================================================
# SYNKORE INSTALLER v3
# Copyright (c) 2026 Bosko Begovic — MIT License
# https://github.com/MSFcodelang/synkore
# =============================================================================
# The plot: turns any Mac or Linux machine into a Synkore node.
# Works via direct run (bash install.sh) AND curl pipe (curl -fsSL ... | bash).
#
#   ACT 1 — Preflight:  check and install all required tools
#   ACT 2 — GitHub:     SSH key, git identity, gh authentication
#   ACT 3 — Memory:     create the private GitHub memory repo with starter files
#   ACT 4 — Hooks:      wire Claude to auto-commit every memory write
#   ACT 5 — Sync:       background agent that pulls repos every 5 minutes
#   ACT 5b — Mobile:    optional iPhone/iPad access instructions
#   ACT 6 — Finish:     lock the claude alias, write marker, print checklist
#
# Everything this script does can be undone. Nothing is permanent.
# =============================================================================

set -euo pipefail

# =============================================================================
# OUTPUT — use printf throughout, NOT echo -e
# =============================================================================
# On macOS, /bin/bash is bash 3.2 where echo -e is unsupported and prints
# the literal "-e" prefix on every line. printf is POSIX and works everywhere.

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
# TTY GUARD — detect non-interactive environments early
# =============================================================================
# Docker, CI/CD, and headless scripts have no /dev/tty.
# We detect this BEFORE the welcome banner so the user gets a clear message,
# not a silent crash from a failed /dev/tty redirect.

if [[ ! -c /dev/tty ]]; then
    fail "This installer requires an interactive terminal."
    printf "\n"
    info "You are running in a non-interactive environment (Docker, CI, etc.)"
    info "The installer needs to prompt you for a GitHub username and SSH key setup."
    printf "\n"
    info "Run it directly instead:"
    info "  curl -fsSL https://raw.githubusercontent.com/MSFcodelang/synkore/main/install.sh -o install.sh"
    info "  bash install.sh"
    exit 1
fi

# =============================================================================
# TTY-SAFE READ — works in both direct run and curl | bash
# =============================================================================
# When run via `curl | bash`, bash's stdin is the script pipe.
# Plain `read` gets EOF immediately → exit code 1 → set -e kills the script.
# Fix: read from /dev/tty (the actual terminal), not stdin.
# This is the same technique used by rustup, nvm, and Homebrew.
#
# bash 3.2 (macOS default) does NOT support `printf -v varname`.
# We use `eval` with careful quoting instead (bash 3.2 compatible).

tty_read() {
    local _varname="$1"
    local _prompt="$2"
    local _val=""
    printf "%s" "$_prompt" >/dev/tty
    IFS= read -r _val </dev/tty
    eval "$_varname=\"\$_val\""
}

# =============================================================================
# CROSS-PLATFORM TIMEOUT
# =============================================================================
# 'timeout' is GNU coreutils — available on Linux, NOT on macOS by default.
# We try timeout, then gtimeout (Homebrew coreutils on Mac), then fall back
# to running without timeout (still bounded by SSH ConnectTimeout in ~/.ssh/config).

safe_timeout() {
    local _dur="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$_dur" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$_dur" "$@"
    else
        "$@"
    fi
}

# BUG-043: Docker/root detection — sudo is not available when running as root.
# Use direct commands instead. All install commands go through RUN_AS_ROOT.
if [[ "$(id -u)" == "0" ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# =============================================================================
# ACT 0a — OS AND SHELL DETECTION
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

# Detect shell config file (BUG-018: never assume zshrc on all systems)
# BUG-bashrc: on macOS, bash login shells read ~/.bash_profile NOT ~/.bashrc.
# Terminal.app opens login shells. ~/.bashrc is never sourced automatically.
# Writing the alias there means it vanishes in every new Terminal window.
RC=""
if [[ "$SHELL" == */zsh ]]; then
    RC="$HOME/.zshrc"
elif [[ "$OS" == "mac" ]]; then
    RC="$HOME/.bash_profile"
else
    RC="$HOME/.bashrc"
fi

# =============================================================================
# ACT 0b — PYTHON 3 CHECK
# =============================================================================
# On macOS before Xcode CLT, /usr/bin/python3 is a stub that pops a GUI dialog.
# On some systems, 'python3' is aliased to Python 2 (urllib.parse missing in Py2).
# We verify we have real Python 3 before using it anywhere.

_PYTHON3=""
for _py in python3 python3.12 python3.11 python3.10 python3.9; do
    if command -v "$_py" &>/dev/null; then
        if "$_py" -c "import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)" 2>/dev/null; then
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
# BUG-021: say "nothing is permanent" upfront — prevents hesitation and abandonment
info "Everything this installer does can be undone in a few minutes."
info "Nothing is permanent."
printf "\n"

# =============================================================================
# ACT 0c — IDEMPOTENCY CHECK
# =============================================================================
# Detect existing installs to prevent duplicate hooks and cron entries (BUG-012).

SYNKORE_MARKER="$HOME/.synkore_installed"
if [[ -f "$SYNKORE_MARKER" ]]; then
    warn "Synkore is already installed (installed: $(cat "$SYNKORE_MARKER"))."
    printf "\n"
    printf "    1) Update — remove old hooks, apply fresh\n"
    printf "    2) Exit\n\n"
    _CHOICE=""
    tty_read _CHOICE "    Enter 1 or 2: "
    if [[ "$_CHOICE" != "1" ]]; then
        info "Nothing changed."
        exit 0
    fi

    step "Removing old hooks before update..."
    if [[ -f "$HOME/.claude/settings.json" ]] && [[ -n "$_PYTHON3" ]]; then
        "$_PYTHON3" - <<'PYEOF'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f"Could not read settings.json: {e} — skipping cleanup")
    sys.exit(0)
hooks = cfg.get("hooks", {})
for event in ["PostToolUse", "UserPromptSubmit"]:
    if event in hooks:
        hooks[event] = [h for h in hooks[event]
            if "Syncing memory" not in str(h) and "health_check" not in str(h)]
cfg["hooks"] = hooks
try:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("Old hooks removed.")
except Exception as e:
    print(f"Could not write settings.json: {e}")
PYEOF
    fi
    ok "Old install cleaned."
fi

# =============================================================================
# ACT 1 — PREFLIGHT: CHECK AND INSTALL REQUIRED TOOLS
# =============================================================================

step "ACT 1 — Checking required tools..."

# --- git ---
if ! command -v git &>/dev/null; then
    warn "git is not installed."
    if [[ "$OS" == "mac" ]]; then
        info "A dialog will appear — click Install, wait for it to finish."
        info "Do NOT press Enter until the Xcode dialog is complete."
        xcode-select --install 2>/dev/null || true
        tty_read _DUMMY "    Press Enter only after Xcode tools installation is complete: "
    else
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git
    fi
fi
ok "git: $(git --version)"

# --- jq (BUG-001, BUG-019) ---
# jq is used by the memory hook to parse Claude's tool output.
# NOT installed by default on Mac or most Linux systems.
# We also capture the FULL PATH here — Claude Code subprocess environments
# may have a minimal PATH that doesn't include /opt/homebrew/bin (Apple Silicon).
# The full path is baked into the hook command at install time (BUG-hook-jq).
if ! command -v jq &>/dev/null; then
    warn "jq not installed — installing now..."
    if [[ "$OS" == "mac" ]]; then
        # BUG-homebrew: auto-install Homebrew if absent — one-command promise requires it.
        # After install, eval shellenv to add /opt/homebrew/bin (Apple Silicon) or
        # /usr/local/bin (Intel) to the current shell session's PATH.
        if ! command -v brew &>/dev/null; then
            info "Homebrew not found — installing Homebrew first..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
            # Make Homebrew available in the current session immediately
            if [[ "$(uname -m)" == "arm64" ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
            else
                eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
            fi
        fi
        brew install jq
    else
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq jq
    fi
fi
JQ_PATH=$(command -v jq)   # full path — baked into hook command below
ok "jq: $JQ_PATH"

# --- curl ---
if ! command -v curl &>/dev/null; then
    [[ "$OS" == "linux" ]] && $SUDO apt-get install -y -qq curl
fi
ok "curl: present"

# --- gh (GitHub CLI) ---
if ! command -v gh &>/dev/null; then
    warn "GitHub CLI not installed — installing..."
    if [[ "$OS" == "mac" ]]; then
        brew install gh
    else
        # Download GPG key to tempfile first — never pipe directly to dd.
        # A network interruption leaves a zero-byte keyring that permanently
        # poisons all future apt operations on this machine (BUG-network-3).
        _GPG_TMP=$(mktemp)
        if ! curl --max-time 30 --connect-timeout 10 -fsSL \
            https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            -o "$_GPG_TMP" || [[ ! -s "$_GPG_TMP" ]]; then
            fail "Failed to download gh CLI GPG key."
            rm -f "$_GPG_TMP"
            exit 1
        fi
        $SUDO dd if="$_GPG_TMP" of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        rm -f "$_GPG_TMP"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq gh
    fi
fi
ok "gh: $(gh --version | head -1)"

# --- Claude Code ---
# BUG-044: Ubuntu apt ships Node 12 which is too old (Claude Code needs Node 18+).
# Install Node 20 from NodeSource if node is missing or too old, then install claude.
if ! command -v claude &>/dev/null; then
    if [[ "$OS" == "linux" ]]; then
        info "Claude Code not found — installing..."
        # Check Node version
        _NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo 0)
        if [[ "$_NODE_VER" -lt 18 ]]; then
            info "Node.js $_NODE_VER is too old (need 18+) — installing Node 20 from NodeSource..."
            $SUDO apt-get remove -y libnode-dev libnode72 nodejs npm 2>/dev/null || true
            curl -fsSL https://deb.nodesource.com/setup_20.x </dev/null | $SUDO bash -
            $SUDO apt-get install -y nodejs
        fi
        npm install -g @anthropic-ai/claude-code
    else
        fail "Claude Code is not installed."
        info "Install it: https://claude.ai/code — then re-run."
        exit 1
    fi
fi
ok "Claude Code: present"

# --- Python 3 ---
# BUG-046: Re-evaluate _PYTHON3 here — NodeSource/Node install may have brought
# in python3 as a dependency after ACT 0b ran and set _PYTHON3="".
# hash -r clears bash's command cache so newly installed binaries are visible.
if [[ -z "$_PYTHON3" ]]; then
    hash -r 2>/dev/null || true
    for _py in python3 python3.12 python3.11 python3.10 python3.9; do
        if type -P "$_py" &>/dev/null; then
            if "$_py" -c "import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)" 2>/dev/null; then
                _PYTHON3="$_py"
                break
            fi
        fi
    done
fi
if [[ -z "$_PYTHON3" ]]; then
    fail "Python 3 is required but not found (or 'python3' points to Python 2)."
    [[ "$OS" == "mac" ]] && info "brew install python3"
    [[ "$OS" == "linux" ]] && info "$SUDO apt-get install python3"
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

# --- GitHub username (BUG-030: validate — empty crashes everything downstream) ---
printf "\n"
GITHUB_USER=""
while [[ -z "$GITHUB_USER" ]]; do
    tty_read GITHUB_USER "    Your GitHub username (required): "
done

# --- SSH key ---
SSH_KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [[ -f "$SSH_KEY" ]]; then
    ok "SSH key already exists — reusing: $SSH_KEY"
else
    info "Generating SSH key..."
    ssh-keygen -t ed25519 -C "$GITHUB_USER" -f "$SSH_KEY" -N ""
    printf "\n"
    # BUG-020: randomart alarms non-technical users — immediately reassure
    info "The pattern above is normal — visual fingerprint of your key. Ignore it."
fi

# --- SSH agent + keychain (BUG-005, BUG-027) ---
if [[ "$OS" == "mac" ]]; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || ssh-add "$SSH_KEY" 2>/dev/null || true
else
    # BUG-027: on Linux, no ssh-agent may be running (headless Pi, VPS)
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" > /dev/null 2>&1
    fi
    ssh-add "$SSH_KEY" 2>/dev/null || true
fi

# --- SSH config (BUG-026: UseKeychain is mac-only — kills Linux SSH if written there) ---
# BUG-port22: corporate firewalls often block port 22. GitHub supports SSH over port 443
# via ssh.github.com. Setting Hostname+Port here means SSH uses 443 transparently —
# works everywhere port 22 works, AND works when port 22 is blocked.
if ! grep -q "Host github.com" "$HOME/.ssh/config" 2>/dev/null; then
    if [[ "$OS" == "mac" ]]; then
        cat >> "$HOME/.ssh/config" << EOF

Host github.com
    Hostname ssh.github.com
    Port 443
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile $SSH_KEY
    ConnectTimeout 30
EOF
    else
        cat >> "$HOME/.ssh/config" << EOF

Host github.com
    Hostname ssh.github.com
    Port 443
    AddKeysToAgent yes
    IdentityFile $SSH_KEY
    ConnectTimeout 30
EOF
    fi
    chmod 600 "$HOME/.ssh/config"
    info "SSH config written (using port 443 — works on all networks including corporate)."
fi

# --- GitHub host key verification (BUG-029) ---
# We scan GitHub's host key and compare against their published fingerprint.
# If the fingerprint matches: safe to add to known_hosts.
# If mismatch (key rotation, old OpenSSH MD5 format, or MITM): warn but still
# add the key — a mismatch warning is better than breaking every install.
# GitHub's published ed25519 fingerprint (from docs.github.com):
_GITHUB_ED25519_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

info "Caching GitHub host key..."
_SCAN_TMP=$(mktemp)
safe_timeout 30 ssh-keyscan -H github.com > "$_SCAN_TMP" 2>/dev/null || true

if [[ -s "$_SCAN_TMP" ]]; then
    _SCANNED_FP=$(ssh-keygen -lf "$_SCAN_TMP" 2>/dev/null | grep -i ed25519 | awk '{print $2}' || true)
    if [[ "$_SCANNED_FP" == "$_GITHUB_ED25519_FP" ]]; then
        cat "$_SCAN_TMP" >> "$HOME/.ssh/known_hosts"
        ok "GitHub host key verified."
    else
        # BUG-fp-rotation: GitHub may rotate keys; old OpenSSH uses MD5 format.
        # A mismatch is a warning, not a fatal error — we still cache the key
        # so the install can proceed. The user sees the expected vs actual FP.
        cat "$_SCAN_TMP" >> "$HOME/.ssh/known_hosts"
        warn "Host key fingerprint mismatch (key rotation or old OpenSSH MD5 format)."
        info "Expected: $_GITHUB_ED25519_FP"
        info "Got:      ${_SCANNED_FP:-<empty — old OpenSSH format>}"
        info "Key cached anyway. Verify manually: ssh-keygen -lf ~/.ssh/known_hosts"
    fi
else
    # Scan timed out or failed — still try to proceed, ssh -T may work if
    # known_hosts was already populated from a previous session.
    warn "Could not scan GitHub host key (network timeout?) — continuing anyway."
fi
rm -f "$_SCAN_TMP"

# --- Show public key, wait for confirmation ---
printf "\n"
printf "${BOLD}Add this SSH key to your GitHub account:${RESET}\n"
printf "  ${BOLD}github.com → Settings → SSH and GPG keys → New SSH key${RESET}\n\n"
cat "${SSH_KEY}.pub"
printf "\n"
tty_read _DUMMY "Press Enter once you have added the key to GitHub: "

# --- Verify SSH works — retry loop + account mismatch check ---
# BUG-ssh-timing: key propagation on GitHub can take 5-30 seconds. One premature
# Enter → full reinstall. Fix: 3 attempts, 10 seconds apart.
# BUG-ssh-account: if ~/.ssh/id_ed25519 belongs to a DIFFERENT GitHub account,
# SSH succeeds but "Hi <wrong_user>!" — hook is silently wired to an unwritable remote.
info "Verifying connection to GitHub..."
_SSH_OK=false
_SSH_USER=""
for _attempt in 1 2 3; do
    _SSH_OUT=$(safe_timeout 30 ssh -o StrictHostKeyChecking=accept-new -T git@github.com </dev/null 2>&1 || true)
    if printf '%s' "$_SSH_OUT" | grep -q "successfully authenticated"; then
        _SSH_OK=true
        _SSH_USER=$(printf '%s' "$_SSH_OUT" | grep -oE 'Hi [^!]+' | sed 's/Hi //' || true)
        break
    fi
    if [[ "$_attempt" -lt 3 ]]; then
        warn "Not authenticated yet — retrying in 10s (attempt $_attempt/3)..."
        sleep 10
    fi
done

if [[ "$_SSH_OK" == "false" ]]; then
    fail "Could not authenticate with GitHub after 3 attempts."
    info "Make sure the key above is added to your GitHub account, then re-run."
    exit 1
fi

# Verify the key belongs to the right account
if [[ -n "$_SSH_USER" ]] && [[ "$_SSH_USER" != "$GITHUB_USER" ]]; then
    fail "SSH key belongs to GitHub account '$_SSH_USER', not '$GITHUB_USER'."
    info "Either use the correct GitHub username above, or delete ~/.ssh/id_ed25519 and re-run."
    exit 1
fi
ok "GitHub SSH: authenticated as ${_SSH_USER:-$GITHUB_USER}"

# --- Authenticate gh CLI (BUG-024: gh installed but never authenticated) ---
# BUG-gh-hang: gh auth status calls api.github.com. Corporate firewalls that block
# api.github.com cause gh to hang indefinitely (TCP drop, no RST). Must use safe_timeout
# on EVERY gh call. Check API reachability before attempting web auth.
info "Checking gh authentication..."
if ! safe_timeout 15 gh auth status &>/dev/null; then
    # Pre-check: is api.github.com reachable at all?
    if ! curl --max-time 8 --connect-timeout 5 -sf https://api.github.com/zen &>/dev/null; then
        fail "api.github.com is not reachable (firewall or network issue)."
        info "gh CLI requires api.github.com for authentication."
        info "On corporate networks: check if api.github.com is blocked."
        info "Alternative: create a Personal Access Token at github.com/settings/tokens"
        info "Then run: gh auth login --with-token"
        exit 1
    fi
    printf "\n"
    info "The GitHub CLI needs to authenticate."
    info "A browser window will open — log in and approve."
    info "If the browser does not open, copy the URL printed below."
    printf "\n"
    safe_timeout 120 gh auth login --git-protocol ssh --web </dev/tty || {
        fail "gh authentication timed out or failed."
        info "Run 'gh auth login --git-protocol ssh --web' manually, then re-run this installer."
        exit 1
    }
fi
ok "gh: authenticated"

# =============================================================================
# ACT 3 — MEMORY REPO: CREATE ON GITHUB WITH STARTER FILES
# =============================================================================
# The memory hook pushes to a private GitHub repo on every memory write.
# Design: we create the GitHub repo here with starter files (MEMORY.md,
# imperatives.md) using a temp local dir, then push and discard the local dir.
#
# The ACTUAL local memory dir (inside ~/.claude/projects/[hash]/memory/) is
# set up by the SELF-HEALING HOOK on the first Claude session — not here.
# This avoids the staging-dir conflict where two repos point at the same
# GitHub remote and get divergent histories (BUG-staging-conflict).

step "ACT 3 — Setting up memory repository on GitHub..."

MEMORY_REPO_NAME="synkore-memory"
MEMORY_REMOTE="git@github.com:${GITHUB_USER}/${MEMORY_REPO_NAME}.git"

# Create or verify the GitHub memory repo
# BUG-gh-hang: all gh calls need safe_timeout — api.github.com can hang on firewalls.
# BUG-gh-silent: removing 2>/dev/null — silent failures leave partial state and
# produce cryptic downstream errors (git push to non-existent remote).
if safe_timeout 15 gh repo view "$GITHUB_USER/$MEMORY_REPO_NAME" &>/dev/null; then
    info "Memory repo already exists on GitHub."
    _REPO_EXISTS=true
else
    info "Creating private memory repo on GitHub..."
    if ! safe_timeout 15 gh repo create "$GITHUB_USER/$MEMORY_REPO_NAME" \
        --private --description "Synkore memory sync"; then
        fail "Could not create memory repo on GitHub."
        info "Possible causes: auth scope issue, rate limit, or api.github.com unreachable."
        info "Create manually: gh repo create $MEMORY_REPO_NAME --private"
        info "Then re-run this installer."
        exit 1
    fi
    ok "Created: github.com/$GITHUB_USER/$MEMORY_REPO_NAME"
    _REPO_EXISTS=false
fi

# Push starter files only if this is a brand new repo (not reinstall)
if [[ "$_REPO_EXISTS" == "false" ]]; then
    _MEM_STAGING=$(mktemp -d)
    git -C "$_MEM_STAGING" init
    git -C "$_MEM_STAGING" checkout -b main 2>/dev/null || true

    cat > "$_MEM_STAGING/MEMORY.md" << EOF
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

    cat > "$_MEM_STAGING/imperatives.md" << EOF
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

    git -C "$_MEM_STAGING" add .
    git -C "$_MEM_STAGING" commit -m "Synkore: initial memory setup"
    git -C "$_MEM_STAGING" remote add origin "$MEMORY_REMOTE"
    # BUG-git-timeout: git push/pull have no built-in timeout. On slow networks or
    # stalled SSH handshakes they hang indefinitely. Wrap in safe_timeout.
    if ! safe_timeout 60 git -C "$_MEM_STAGING" push -u origin main; then
        fail "Could not push starter files to GitHub (timeout or network error)."
        info "The repo was created on GitHub. Re-run to complete setup."
        rm -rf "$_MEM_STAGING"
        exit 1
    fi
    ok "Starter files pushed to GitHub memory repo."

    # Clean up staging dir — the self-healing hook sets up the local repo
    # in the correct ~/.claude/projects/[hash]/memory/ location on first use
    rm -rf "$_MEM_STAGING"
else
    info "Existing memory repo — skipping starter file push."
fi

# =============================================================================
# ACT 4 — CLAUDE HOOKS: WIRE MEMORY AUTO-SYNC
# =============================================================================
# The PostToolUse hook fires after every file write Claude makes.
# If the file is inside a memory folder, it:
#   1. Initializes git in that memory dir if not already set up (self-healing)
#   2. Fetches from GitHub to get existing memory content
#   3. Commits and pushes the new file
#
# SELF-HEALING: the hook uses `dirname $f` to get the memory dir directly —
# no walking up the tree looking for .git. If no .git exists, it creates one,
# sets the remote, fetches existing content, and pushes. This fires correctly
# on the very first Claude session regardless of the project hash.
#
# JQ PATH: baked in as full path at install time so the hook works in Claude's
# minimal subprocess PATH (Apple Silicon: /opt/homebrew/bin not in subprocess PATH).
#
# Settings.json: MERGED not overwritten (BUG-002). Python with try/except (BUG-003).
# Quoted heredoc 'PYEOF': no shell expansion inside Python. Env vars pass hook
# commands safely (BUG-025).

step "ACT 4 — Wiring Claude memory hooks..."

SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"
    info "Backed up settings.json"
else
    printf '{}' > "$SETTINGS"
fi

# PostToolUse hook: uses full $JQ_PATH (baked at install) and the GitHub username.
# The hook self-heals: if the memory dir has no .git, it initializes one,
# fetches the existing MEMORY.md from GitHub, then commits and pushes.
# Memory hook — key fixes applied:
# BUG-hook-empty:  explicit [ -z "$f" ] check before grep (read returns 1 on empty jq output)
# BUG-hook-regex:  \.claude (escaped dot), trailing slash, [^/]+ (no path traversal)
# BUG-hook-master: dynamic branch detection via ls-remote, not hardcoded 'main'
# BUG-hook-diverge: git pull --rebase before push — prevents permanent diverged history
#                   when concurrent hook instances create split push histories
export SYNKORE_MEMORY_HOOK="${JQ_PATH} -r '.tool_input.file_path // empty' | { read -r f || true; [ -z \"\$f\" ] && exit 0; echo \"\$f\" | grep -qE '\\.claude/projects/[^/]+/memory/' || exit 0; D=\$(dirname \"\$f\"); if [ ! -d \"\$D/.git\" ]; then git -C \"\$D\" init 2>/dev/null && git -C \"\$D\" remote add origin git@github.com:${GITHUB_USER}/${MEMORY_REPO_NAME}.git 2>/dev/null && git -C \"\$D\" fetch origin 2>/dev/null; B=\$(git -C \"\$D\" ls-remote --symref origin HEAD 2>/dev/null | grep '^ref:' | sed 's|ref: refs/heads/||;s|[[:space:]].*||'); B=\${B:-main}; git -C \"\$D\" checkout -b \"\$B\" --track \"origin/\$B\" 2>/dev/null || git -C \"\$D\" checkout \"\$B\" 2>/dev/null || true; fi; cd \"\$D\" || exit 0; B=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null); B=\${B:-main}; git pull --rebase origin \"\$B\" 2>/dev/null || true; git add . && git commit -m \"Auto-sync memory \$(date '+%Y-%m-%d %H:%M')\" && git push origin \"\$B\"; } 2>/dev/null || true"

# UserPromptSubmit hook: runs health check silently at session start
export SYNKORE_HEALTH_HOOK="bash $HOME/Claude_Code/health_check.sh >> /dev/null 2>&1 &"

"$_PYTHON3" - <<'PYEOF'
import json, os, sys

path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        cfg = json.load(f)
except json.JSONDecodeError as e:
    print(f"ERROR: settings.json is invalid JSON: {e}")
    print("Fix: validate the file at jsonlint.com, then re-run.")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: could not read settings.json: {e}")
    sys.exit(1)

hooks = cfg.setdefault("hooks", {})

try:
    memory_cmd = os.environ["SYNKORE_MEMORY_HOOK"]
    health_cmd  = os.environ["SYNKORE_HEALTH_HOOK"]
except KeyError as e:
    print(f"ERROR: required env var not set: {e}")
    sys.exit(1)

# PostToolUse
post = hooks.setdefault("PostToolUse", [])
if not any("Syncing memory" in str(h) for h in post):
    post.append({"matcher": "Write", "hooks": [{
        "type": "command",
        "command": memory_cmd,
        "timeout": 120,
        "statusMessage": "Syncing memory..."
    }]})
    print("PostToolUse hook added.")
else:
    print("PostToolUse hook already present — skipped.")

# UserPromptSubmit
submit = hooks.setdefault("UserPromptSubmit", [])
if not any("health_check" in str(h) for h in submit):
    submit.append({"matcher": "", "hooks": [{"type": "command", "command": health_cmd}]})
    print("UserPromptSubmit hook added.")
else:
    print("UserPromptSubmit hook already present — skipped.")

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

# --- msf_sync.sh ---
cat > "$HOME/Claude_Code/msf_sync.sh" << 'SYNCEOF'
#!/bin/bash
# =============================================================================
# msf_sync.sh — Synkore background sync
# =============================================================================
# Pulls every git repo in ~/Claude_Code/ from GitHub every 5 minutes.
# Uses a mkdir lock so only one instance runs at a time — prevents concurrent
# agents from fighting over the same stash stack (BUG-sync-concurrent).
# Stash is only pushed when there are actual local changes — prevents popping
# the wrong stash (BUG-sync-stashpop). Pops our specific stash by name.
# =============================================================================

LOG="$HOME/Claude_Code/sync.log"

# Atomic single-instance lock: mkdir is atomic, touch is not
LOCK="/tmp/synkore_sync_lock"
mkdir "$LOCK" 2>/dev/null || {
    printf "[%s] Another sync instance running — skipping\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
    exit 0
}
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# GATE: abort if Claude_Code can't be reached (BUG-011)
cd "$HOME/Claude_Code" || {
    printf "[%s] ERROR: Claude_Code not found — aborting\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
    exit 1
}

printf "[%s] Sync starting...\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

for dir in */; do
    [ -d "$dir/.git" ] || continue

    # Branch detection: try ls-remote, fall back to symbolic-ref, then current branch
    branch=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
        | grep "^ref:" | sed 's|ref: refs/heads/||;s|[[:space:]].*||') || true
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
            | sed 's@^refs/remotes/origin/@@') || true
    fi
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    fi
    [[ -z "$branch" ]] && branch="main"

    # Safe stash: only stash if there are actual local changes.
    # Unconditional stash pushes an empty entry, then pop removes the
    # PREVIOUS stash — silently corrupting a different repo's working tree.
    STASH_REF=""
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
        git -C "$dir" stash push -m "synkore-autostash-$(date +%s)" 2>/dev/null || true
        # Capture the exact ref of OUR stash so we pop the right one
        STASH_REF=$(git -C "$dir" stash list 2>/dev/null \
            | grep "synkore-autostash" | head -1 | cut -d: -f1) || true
    fi

    git -C "$dir" pull origin "$branch" >> "$LOG" 2>&1 || true

    # Pop only OUR stash by its specific ref — not whatever is on top
    if [[ -n "$STASH_REF" ]]; then
        git -C "$dir" stash pop "$STASH_REF" 2>/dev/null || true
    fi
done

printf "[%s] Sync done.\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

# Safe log trim
_LOG_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
if [[ "$_LOG_LINES" -gt 500 ]]; then
    if tail -300 "$LOG" > "$LOG.tmp"; then
        mv "$LOG.tmp" "$LOG"
    else
        rm -f "$LOG.tmp"
    fi
fi
SYNCEOF
chmod +x "$HOME/Claude_Code/msf_sync.sh"
ok "Sync script written."

# --- health_check.sh ---
# Note: this heredoc is UNQUOTED (<<HEALTHEOF) so $HOME and $JQ_PATH expand
# at install time — intentional, bakes the correct paths into the written script.
# All other $ references are escaped with \ to expand at runtime.
cat > "$HOME/Claude_Code/health_check.sh" << HEALTHEOF
#!/bin/bash
# Synkore health check — runs once per Claude session

# Atomic single-instance lock (race-condition safe vs touch)
LOCK="/tmp/synkore_health_lock"
mkdir "\$LOCK" 2>/dev/null || exit 0
trap 'rmdir "\$LOCK" 2>/dev/null' EXIT

LOG="\$HOME/Claude_Code/health_check.log"
printf "=== Health Check %s ===\n" "\$(date '+%Y-%m-%d %H:%M:%S')" >> "\$LOG"

# Safe log trim
_LINES=\$(wc -l < "\$LOG" 2>/dev/null || echo 0)
if [[ "\$_LINES" -gt 500 ]]; then
    if tail -300 "\$LOG" > "\$LOG.tmp"; then mv "\$LOG.tmp" "\$LOG"; else rm -f "\$LOG.tmp"; fi
fi

# Check GitHub SSH
if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -T git@github.com 2>&1 \
    | grep -q "successfully authenticated"; then
    printf "✅ GitHub: connected\n" >> "\$LOG"
else
    printf "❌ GitHub: not reachable\n" >> "\$LOG"
fi

# Check sync agent
if [[ "\$(uname)" == "Darwin" ]]; then
    if launchctl list 2>/dev/null | grep -qE "com\.synkore\.sync" || \
       launchctl print "gui/\$(id -u)/com.synkore.sync" &>/dev/null 2>&1; then
        printf "✅ Sync agent: running\n" >> "\$LOG"
    else
        printf "❌ Sync agent: not running — restarting...\n" >> "\$LOG"
        launchctl bootstrap "gui/\$(id -u)" "$HOME/Library/LaunchAgents/com.synkore.sync.plist" 2>/dev/null || \
            launchctl load "$HOME/Library/LaunchAgents/com.synkore.sync.plist" 2>/dev/null || true
    fi
else
    if systemctl --user is-active synkore-sync.timer &>/dev/null 2>&1; then
        printf "✅ Sync agent: running\n" >> "\$LOG"
    else
        printf "❌ Sync agent: restarting...\n" >> "\$LOG"
        systemctl --user start synkore-sync.timer 2>/dev/null || true
    fi
fi

printf "✅ Health check complete\n" >> "\$LOG"
HEALTHEOF
chmod +x "$HOME/Claude_Code/health_check.sh"
ok "Health check script written."

# --- Install sync agent ---
if [[ "$OS" == "mac" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.synkore.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.synkore.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/Claude_Code/msf_sync.sh</string>
    </array>
    <key>StartInterval</key><integer>300</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Claude_Code/sync.log</string>
    <key>StandardErrorPath</key><string>$HOME/Claude_Code/sync.log</string>
</dict>
</plist>
EOF
    # BUG-reinstall-plist: on reinstall, the old plist is still loaded.
    # bootstrap on an already-loaded service returns EALREADY (exit 37) and is silently
    # swallowed — the OLD running agent keeps using stale config. Bootout first.
    launchctl bootout "gui/$(id -u)/com.synkore.sync" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true

    # BUG-013: use modern bootstrap, fallback to load for older macOS
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
        launchctl load "$PLIST" 2>/dev/null || true

    # BUG-009/MDM: MDM can silently accept then kill the agent. launchctl list
    # shows the service name even when MDM-blocked. More reliable check: verify
    # that RunAtLoad actually produced a sync.log entry within the window.
    # Also increase window to 10s — MDM enforcement is asynchronous (5-15s delay).
    _SYNC_AGENT_OK=false
    sleep 10
    if [[ -f "$HOME/Claude_Code/sync.log" ]]; then
        _SYNC_AGENT_OK=true
    fi
    if [[ "$_SYNC_AGENT_OK" == "false" ]]; then
        warn "Sync agent blocked or not running (MDM policy?). Installing cron fallback..."
        # BUG-crontab-sete: crontab -  returns non-zero on managed Macs (Full Disk Access
        # required). Wrap in || warn to prevent set -e from killing the script here.
        # BUG-035: deduplicate cron entry on reinstall.
        ( crontab -l 2>/dev/null | grep -v "msf_sync.sh";
          printf '*/5 * * * * /bin/bash "%s/Claude_Code/msf_sync.sh" >> "%s/Claude_Code/sync.log" 2>&1\n' \
              "$HOME" "$HOME" ) | crontab - 2>/dev/null || \
            warn "Cron install failed — Terminal may need Full Disk Access in System Settings → Privacy."
        ok "Cron fallback installed (syncs every 5 minutes)."
    else
        ok "Mac sync agent loaded (launchd)."
    fi

else
    # BUG-016: Linux uses systemd user units, not launchd
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
    # BUG-028: headless Pi/VPS needs linger to keep user units alive without login
    loginctl enable-linger "$USER" 2>/dev/null || true
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now synkore-sync.timer 2>/dev/null || true
    ok "Linux sync agent loaded."

    # BUG-017: Tailscale on Linux — do NOT nest another curl|sh inside this installer
    printf "\n"
    info "Optional: install Tailscale for remote access from any network."
    info "Run separately: https://tailscale.com/install"
fi

# =============================================================================
# ACT 5b — MOBILE ACCESS (OPTIONAL)
# =============================================================================

step "ACT 5b — Mobile access (optional)..."
printf "\n"
_MOBILE=""
tty_read _MOBILE "    Do you want mobile access (iPhone/iPad)? (y/n): "

if [[ "$_MOBILE" == "y" ]]; then
    _HAS_PI=""
    tty_read _HAS_PI "    Do you have a Raspberry Pi or server running 24/7? (y/n): "

    if [[ "$_HAS_PI" == "y" ]]; then
        printf "\n"
        ok "One-tap Claude from your phone:"
        printf "\n"
        printf "  1. Install Moshi on iPhone/iPad (App Store)\n"
        # BUG-014: search returns meditation app first
        printf "     Search: 'Moshi: SSH & SFTP Terminal' by Comodo — NOT the meditation app\n\n"
        printf "  2. In Moshi: Settings → Keys → Generate New Key → name it 'phone'\n"
        printf "     Long-press → Copy Public Key\n\n"
        # BUG-022: say "on the Pi, run this" not "ask your Pi admin"
        printf "  3. On the Pi, run:\n"
        printf '     echo '"'"'command="cd ~/Claude_Code && command claude",restrict ssh-ed25519 YOUR_KEY phone'"'"' >> ~/.ssh/authorized_keys\n\n'
        printf "  4. In Moshi: + → New Connection → Pi Tailscale IP, your Pi username, your key\n\n"
        printf "  Result: one tap → Claude with full context. No typing.\n\n"
        tty_read _DUMMY "    Press Enter to continue..."
    else
        # BUG-010: no Pi — honest path to Pro waitlist
        printf "\n"
        warn "Without a Pi, phone access requires a hosted relay."
        printf "\n"
        printf "  Synkore Pro (coming soon):\n"
        printf "  • Hosted relay — no Pi needed\n"
        printf "  • Telegram bot — message Claude from your phone\n\n"
        printf "  Get notified: github.com/MSFcodelang/synkore (watch repo)\n\n"
        tty_read _DUMMY "    Press Enter to continue..."
    fi
fi

# =============================================================================
# ACT 6 — FINISH: CLAUDE ALIAS + MARKER
# =============================================================================
# BUG-023: alias must use 'command claude' not 'claude' — otherwise the alias
# calls itself recursively (infinite loop, Claude becomes unusable).
#
# BUG-alias-grep: we check for the specific substring 'command claude' so the
# grep matches what we actually write. But we use a more specific pattern
# to avoid false-matches on unrelated aliases that happen to contain
# 'command claude' as a substring (e.g., alias cc='command claude --help').

step "ACT 6 — Locking Claude alias..."

# BUG-alias-grep: grep -qF with literal "$HOME" does NOT match the stored literal "$HOME"
# in the file (grep expands $HOME to /Users/username; file has literal $HOME).
# Fix: use -qE with a regex pattern that matches any form of the alias.
if ! grep -qE "alias claude=.*command claude" "$RC" 2>/dev/null; then
    printf "\n# Synkore: always launch Claude from the correct directory\n" >> "$RC"
    printf "alias claude='cd \$HOME/Claude_Code && command claude'\n" >> "$RC"
    info "Claude alias written to $RC"
else
    info "Claude alias already in $RC — skipped."
fi

# Write install marker with today's date
date '+%Y-%m-%d' > "$SYNKORE_MARKER"

# =============================================================================
# DONE — VERIFICATION CHECKLIST
# =============================================================================

printf "\n"
printf "${BOLD}╔════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║         Installation complete!         ║${RESET}\n"
printf "${BOLD}╚════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "What's now running invisibly:\n\n"
printf "  • Repos in ~/Claude_Code/ pull from GitHub every 5 minutes\n"
printf "  • Every memory write auto-commits and pushes to GitHub\n"
printf "  • Health check runs silently each Claude session\n"
printf "  • claude alias always opens from ~/Claude_Code — memory never lost\n\n"

printf "${BOLD}Do these three things now:${RESET}\n\n"
printf "  1. Reload your shell:\n"
printf "     source %s\n\n" "$RC"
printf "  2. Open Claude once (creates your memory folder):\n"
printf "     claude\n\n"
printf "  3. After 5 minutes, verify sync:\n"
if [[ "$OS" == "mac" ]]; then
printf "     launchctl list | grep synkore\n\n"
else
printf "     systemctl --user is-active synkore-sync.timer\n\n"
fi

# BUG-015: logs appear after first use, not immediately — tell user this
printf "${BOLD}Verification logs (appear after first use — normal):${RESET}\n\n"
printf "  cat ~/Claude_Code/sync.log        # after 5 minutes\n"
printf "  cat ~/Claude_Code/health_check.log  # after first Claude session\n\n"

printf "  Memory repo: github.com/%s/%s\n\n" "$GITHUB_USER" "$MEMORY_REPO_NAME"

printf "---\n"
printf "Synkore — independent open-source project.\n"
printf "Not affiliated with or endorsed by Anthropic.\n"
printf "---\n\n"
