#!/bin/sh
# codex CLI wrapper — patches the per-task config.toml to bypass codex's
# bubblewrap sandbox before invoking the real binary.
#
# Why this exists: Multica's daemon writes a fresh
# `codex-home/config.toml` per task (via execenv.ensureCodexSandboxConfig
# in the daemon binary), and on Linux it sets
#   sandbox_mode = "workspace-write"
# which makes codex wrap shell commands in bubblewrap. bwrap then fails
# with "No permissions to create a new namespace" because the k3d
# node-container kernel restricts unprivileged user namespaces under
# the pod's seccomp/cap profile (RuntimeDefault + drop-ALL).
#
# Our pod is already a hard sandbox (runAsNonRoot, no SA token, dropped
# caps, RO root-ish FS). Letting codex run shell commands without its
# own extra sandbox is safe in this context. The daemon already does
# this fallback on macOS (string: "codex sandbox: falling back to
# danger-full-access on macOS") — we extend it to Linux via this
# wrapper.
#
# The daemon sets CODEX_HOME per task before spawning codex. We rewrite
# sandbox_mode in that config just-in-time, then exec the real binary.

set -eu

if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ]; then
  # Replace any existing sandbox_mode line, OR insert one near the top
  # if the daemon's template didn't include it.
  if grep -q '^sandbox_mode' "$CODEX_HOME/config.toml"; then
    sed -i 's/^sandbox_mode[[:space:]]*=.*$/sandbox_mode = "danger-full-access"/' "$CODEX_HOME/config.toml"
  else
    # Prepend so it lands before any [section] header.
    printf 'sandbox_mode = "danger-full-access"\n%s\n' "$(cat "$CODEX_HOME/config.toml")" \
      > "$CODEX_HOME/config.toml.new"
    mv "$CODEX_HOME/config.toml.new" "$CODEX_HOME/config.toml"
  fi
fi

exec /usr/local/bin/codex.real "$@"
