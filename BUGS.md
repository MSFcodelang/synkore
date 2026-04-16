# Synkore — Known Bugs & Fixes

All bugs found during install.sh testing. Format: BUG-NNN, status, root cause, fix.

---

## BUG-043 — sudo not found as root ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Docker (Ubuntu 22.04), any root-user Linux
**Symptom:** `sudo: command not found` on first apt-get call
**Root cause:** Docker runs as root. sudo is not installed.
**Fix:** Detect root with `id -u`. Set `SUDO=""` if root, `SUDO="sudo"` otherwise. Use `$SUDO` everywhere.

---

## BUG-044 — Node version too old ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Ubuntu 22.04 default repos
**Symptom:** Claude Code install failed silently. Installer skipped Node install because Node was present, but Node 12 is too old.
**Root cause:** Ubuntu 22.04 ships Node 12. No version gate existed in installer.
**Fix:** Check `node --version` major. If < 18: remove old Node packages, install Node 20 via NodeSource.

---

## BUG-045 — SSH exits silently in curl|bash ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Any curl|bash invocation
**Symptom:** `ssh -T git@github.com` returned no output. GitHub verification appeared to pass but didn't authenticate.
**Root cause:** When run inside `curl | bash`, SSH inherits the dead curl stdin (EOF). Exits immediately.
**Fix:** `ssh -T git@github.com </dev/null` — redirect stdin explicitly.

---

## BUG-046 — python3 not found after NodeSource installs it ✅ FIXED

**Status:** Fixed 2026-04-13 (required two attempts)
**Environment:** Any system where python3 isn't pre-installed
**Symptom:** `❌ Python 3 is required but not found` — despite python3 being installed mid-script by NodeSource as a Node dependency.
**Root cause (attempt 1):** `_PYTHON3` evaluated at script start before python3 existed. Added re-check loop — still failed.
**Root cause (attempt 2):** `command -v` uses bash's internal hash table which caches "not found". Newly installed binary invisible to it.
**Fix:** `hash -r` clears cache. `type -P` does a fresh PATH scan. Re-check loop now finds python3.

---

## BUG-047 — gh SSH key upload prompt unkillable in Docker ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Docker pseudo-TTY, any non-standard terminal
**Symptom:** After `gh auth login`, TUI prompt asks to upload SSH key. Arrow keys output `^[[B` garbage. Filter chars partially worked but couldn't confirm selection. Ctrl+C did nothing. Had to kill container from outside.
**Root cause:** gh's survey library relies on proper arrow-key terminal support. Docker pseudo-TTY doesn't pass arrow keys correctly.
**Fix:** `gh auth login --skip-ssh-key` — key already added to GitHub manually. Prompt is redundant.

---

## BUG-048 — gh auth login Enter press ignored in curl|bash ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** curl|bash pipe, Docker
**Symptom:** After GitHub device auth in browser, pressing Enter in terminal did nothing. Process hung.
**Root cause:** `gh auth login --web` reads stdin for confirmation. In curl|bash, stdin is the pipe (EOF). `</dev/tty` on stdin alone wasn't enough — stdout/stderr also needed to be on the TTY.
**Fix:** `gh auth login ... </dev/tty >/dev/tty 2>/dev/tty` — all I/O forced directly to terminal.

---

## BUG-049 — name/email prompts unusable in Docker terminal ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Docker, any terminal where arrow keys don't work
**Symptom:** Typing email address with a typo — no way to correct it. Arrow keys output `^[[D` escape codes. Backspace partially worked but cursor didn't move.
**Root cause:** bash `read` has no cursor movement support. Docker pseudo-TTY doesn't translate arrow key sequences.
**Fix:** Removed name/email prompts from ACT 2. Pull from GitHub API after gh auth: `gh api user -q .name/.email`. Only prompt as fallback if API returns empty.

---

## BUG-050 — ~/.claude/ directory missing on fresh install ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Any system where Claude Code was just installed (never run yet)
**Symptom:** `bash: /root/.claude/settings.json: No such file or directory`
**Root cause:** Claude Code creates `~/.claude/` on first run. Installer writes settings.json before Claude has ever been run.
**Fix:** `mkdir -p "$HOME/.claude"` before writing settings.json.

---

## BUG-051 — USER unbound variable in Docker ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** Docker (Ubuntu 22.04), possibly other minimal Linux environments
**Symptom:** `bash: USER: unbound variable` in ACT 5 Linux sync agent block.
**Root cause:** `set -u` is active. Docker root environment doesn't set the `USER` env var.
**Fix:** `_CURRENT_USER=$(id -un 2>/dev/null || echo root)` — derive user from `id` instead of env var.

---

## BUG-052 — printf "---" parsed as option flag ✅ FIXED

**Status:** Fixed 2026-04-13
**Environment:** bash builtin printf (any system)
**Symptom:** `printf: --: invalid option` at the very last line of the script, after "Installation complete!" already printed. Cosmetic only.
**Root cause:** `printf "---\n"` — bash's builtin printf tries to parse leading `-` in the format string as option flags. `--` triggers "end of options" handling.
**Fix:** `printf "%s\n" "---"` — pass `---` as an argument to `%s` format, not as the format string itself.

---

## BUG-053 — Claude Code install command in error message ✅ FIXED

**Status:** Fixed 2026-04-14
**Environment:** Any system where Claude Code is not installed
**Symptom:** Error message said `npm install -g @anthropic-ai/claude-code`. Anthropic deprecated npm. User following this installs an outdated version.
**Root cause:** Error message written before Anthropic switched to native installer.
**Fix:** Error message now shows `curl -fsSL https://claude.ai/install.sh | bash`.

---

*Log new bugs as BUG-NNN in sequence. Mark fixed with date.*
