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

*Log new bugs as BUG-NNN in sequence. Mark fixed with date.*
