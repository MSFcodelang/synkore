#!/bin/bash
# =============================================================================
# SYNKORE UNINSTALLER
# Copyright (c) 2026 Bosko Begovic — MIT License
# https://github.com/MSFcodelang/synkore
# =============================================================================
# One command. Clean removal. Nothing left behind.
# Run this to completely remove Synkore from your machine.
#
# What this removes:
#   - Sync agent (launchd on Mac, systemd on Linux, cron fallback)
#   - Memory auto-commit hook from ~/.claude/settings.json
#   - Health check hook from ~/.claude/settings.json
#   - claude alias from your shell RC file
#   - msf_sync.sh and health_check.sh from ~/Claude_Code/
#   - The ~/.synkore_installed marker
#
# What this does NOT remove (your data):
#   - ~/Claude_Code/ directory and all repos inside it
#   - Your SSH key (~/.ssh/id_ed25519)
#   - The synkore-memory repo on GitHub (private repo, yours to keep or delete)
#   - Your Claude memory files (~/.claude/projects/)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "${GREEN}✅  %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}⚠️   %s${RESET}\n" "$1"; }
step() { printf "\n${BOLD}→ %s${RESET}\n" "$1"; }
info() { printf "    %s\n" "$1"; }

OS=""
if [[ "$OSTYPE" == "darwin"* ]]; then OS="mac"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then OS="linux"
fi

printf "\n"
printf "${BOLD}╔════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║       Synkore — Clean Uninstall        ║${RESET}\n"
printf "${BOLD}╚════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "    This will completely remove Synkore from this machine.\n"
printf "    Your data (repos, memory files, GitHub repo) is NOT touched.\n\n"
printf "    Continue? (y/n): "
read -r _CONFIRM </dev/tty
if [[ "$_CONFIRM" != "y" ]]; then
    printf "\n    Nothing changed.\n\n"
    exit 0
fi

# =============================================================================
# 1 — STOP AND REMOVE SYNC AGENT
# =============================================================================

step "Removing sync agent..."

if [[ "$OS" == "mac" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.synkore.sync.plist"
    launchctl bootout "gui/$(id -u)/com.synkore.sync" 2>/dev/null || true
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    ok "launchd agent removed."
elif [[ "$OS" == "linux" ]]; then
    systemctl --user disable --now synkore-sync.timer 2>/dev/null || true
    systemctl --user disable --now synkore-sync.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/synkore-sync.timer"
    rm -f "$HOME/.config/systemd/user/synkore-sync.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd timer removed."
fi

# Remove cron fallback (both platforms)
if crontab -l 2>/dev/null | grep -q "msf_sync.sh"; then
    ( crontab -l 2>/dev/null | grep -v "msf_sync.sh" ) | crontab - 2>/dev/null || true
    ok "Cron entry removed."
fi

# =============================================================================
# 2 — REMOVE HOOKS FROM CLAUDE SETTINGS
# =============================================================================

step "Removing Claude hooks..."

SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
    _PYTHON3=""
    for _py in python3 python3.12 python3.11 python3.10 python3.9; do
        if command -v "$_py" &>/dev/null; then
            _PYTHON3="$_py"
            break
        fi
    done

    if [[ -n "$_PYTHON3" ]]; then
        "$_PYTHON3" - <<'PYEOF'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f"Could not read settings.json: {e}")
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
    print("    Hooks removed from settings.json.")
except Exception as e:
    print(f"    Could not write settings.json: {e}")
PYEOF
    else
        warn "Python 3 not found — remove hooks manually from ~/.claude/settings.json"
        info "Delete the PostToolUse block containing 'Syncing memory'"
        info "Delete the UserPromptSubmit block containing 'health_check'"
    fi
else
    info "No settings.json found — skipped."
fi

# =============================================================================
# 3 — REMOVE CLAUDE ALIAS FROM SHELL RC
# =============================================================================

step "Removing claude alias..."

_CLEANED=false
for _RC in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [[ -f "$_RC" ]] && grep -qE "alias claude=.*command claude" "$_RC" 2>/dev/null; then
        # Remove the alias line and the comment line above it
        grep -v "Synkore: always launch Claude" "$_RC" | \
            grep -v "alias claude=.*command claude" > "$_RC.synkore_tmp" && \
            mv "$_RC.synkore_tmp" "$_RC" || rm -f "$_RC.synkore_tmp"
        ok "Alias removed from $_RC"
        _CLEANED=true
    fi
done
[[ "$_CLEANED" == "false" ]] && info "No alias found in RC files — skipped."

# =============================================================================
# 4 — REMOVE SYNKORE SCRIPTS
# =============================================================================

step "Removing Synkore scripts..."

rm -f "$HOME/Claude_Code/msf_sync.sh"
rm -f "$HOME/Claude_Code/health_check.sh"
ok "Scripts removed from ~/Claude_Code/"

# =============================================================================
# 5 — REMOVE MARKER
# =============================================================================

rm -f "$HOME/.synkore_installed"

# =============================================================================
# DONE
# =============================================================================

printf "\n"
printf "${BOLD}╔════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║         Synkore removed. Done.         ║${RESET}\n"
printf "${BOLD}╚════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "    Reload your shell to clear the alias from this session:\n\n"

if [[ "$OS" == "mac" ]]; then
    printf "    exec zsh    # or: exec bash\n\n"
else
    printf "    exec bash\n\n"
fi

printf "    Your data is untouched:\n"
printf "    • ~/Claude_Code/ — all repos still there\n"
printf "    • github.com/YOUR_USERNAME/synkore-memory — still private, still yours\n"
printf "    • ~/.claude/ — all memory files still there\n\n"

printf "    To delete the memory repo on GitHub:\n"
printf "    gh repo delete synkore-memory --yes\n\n"

printf "---\n"
printf "Synkore — independent open-source project.\n"
printf "Not affiliated with or endorsed by Anthropic.\n"
printf "---\n\n"
