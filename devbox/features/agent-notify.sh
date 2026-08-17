#!/usr/bin/env bash
# Happy push notifications for Claude/Codex usage- and rate-limit hits
# (issue #59): installs the shared devbox-agent-limit-notify entry point plus
# the per-agent detectors that call into it (devbox-claude-limit-detect,
# devbox-codex-limit-detect). Registering the detectors as a Claude hook /
# Codex notify command happens in install.sh itself, next to where
# ~/.claude/settings.json and ~/.codex/config.toml are already written.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on msg_*() from install.sh's own bootstrap chain, and DEV_USER/DEV_HOME
# from install.sh. Must run after install_happy() (the scripts shell out to
# the `happy` CLI) and after create_developer_user() (needs
# ${DEV_HOME}/.local/bin to exist).

set -Eeuo pipefail

install_agent_limit_notify() {
  msg_info "Installing agent limit-notify scripts"

  cat <<'EOF' >"${DEV_HOME}/.local/bin/devbox-agent-limit-notify"
#!/usr/bin/env bash
# Managed by the DevBox installer.
#
# Shared entry point called by devbox-claude-limit-detect and
# devbox-codex-limit-detect once they've identified a usage/rate-limit hit.
# Sends one Happy push notification per agent within a short dedup window,
# and never blocks or fails the caller: every error path exits 0.
#
# Usage: devbox-agent-limit-notify <claude|codex>

set -Eeuo pipefail

agent="${1:-}"

case "$agent" in
  claude) title="Claude-Limit erreicht" ;;
  codex) title="Codex-Limit erreicht" ;;
  *) exit 0 ;;
esac

command -v happy >/dev/null 2>&1 || exit 0

state_dir="${HOME}/.config/devbox"
state_file="${state_dir}/agent-limit-notify.${agent}.state"

install -d -m 0700 "$state_dir" 2>/dev/null || exit 0

# A single limit event can trip more than one Stop/notify event; only push
# once per agent within this window.
dedup_window_seconds=300
now="$(date +%s)"

last="$(cat "$state_file" 2>/dev/null || true)"

if [[ "$last" =~ ^[0-9]+$ ]] &&
  (( now - last < dedup_window_seconds )); then

  exit 0
fi

message="Die Session auf devbox kann aktuell nicht weiterarbeiten. Bitte nach dem Reset erneut versuchen."

happy notify -p "$message" -t "$title" >/dev/null 2>&1 || true

printf '%s\n' "$now" >"$state_file" 2>/dev/null || true

exit 0
EOF

  cat <<'EOF' >"${DEV_HOME}/.local/bin/devbox-claude-limit-detect"
#!/usr/bin/env bash
# Managed by the DevBox installer. Registered as a Claude Code StopFailure
# hook (matcher: rate_limit|billing_error) in ~/.claude/settings.json.
#
# Reads the StopFailure hook payload from stdin and only forwards to
# devbox-agent-limit-notify for a known usage/billing limit - never for a
# normal Stop (this hook doesn't fire for those) and never for other API
# errors (overloaded, server_error, etc.), which stay silent by design.

set -Eeuo pipefail

command -v jq >/dev/null 2>&1 || exit 0

error_type="$(
  jq -r '.error_type // empty' 2>/dev/null || true
)"

case "$error_type" in
  rate_limit | billing_error)
    "${HOME}/.local/bin/devbox-agent-limit-notify" claude
    ;;
esac

exit 0
EOF

  cat <<'EOF' >"${DEV_HOME}/.local/bin/devbox-codex-limit-detect"
#!/usr/bin/env bash
# Managed by the DevBox installer. Registered as Codex's `notify` command in
# ~/.codex/config.toml.
#
# Codex has no structured rate-limit signal comparable to Claude's
# StopFailure error_type, so this is a conservative best-effort text match
# against the notify payload's last assistant message. It only fires on an
# unambiguous usage/rate-limit phrase and stays silent on anything else,
# including malformed or unrecognized input - a normal Codex turn must never
# raise a notification.

set -Eeuo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload="${1:-}"
[[ -n "$payload" ]] || payload="$(cat)"

text="$(
  jq -r '
    [.["last-assistant-message"], .message, .msg]
    | map(select(type == "string"))
    | first // empty
  ' <<<"$payload" 2>/dev/null || true
)"

[[ -n "$text" ]] || exit 0

shopt -s nocasematch

case "$text" in
  *"usage limit"* | *"rate limit"* | *"limit reached"* | *"resets at"* | \
    *"you've hit your limit"* | *"too many requests"* | *"quota exceeded"*)

    "${HOME}/.local/bin/devbox-agent-limit-notify" codex
    ;;
esac

exit 0
EOF

  chmod \
    0755 \
    "${DEV_HOME}/.local/bin/devbox-agent-limit-notify" \
    "${DEV_HOME}/.local/bin/devbox-claude-limit-detect" \
    "${DEV_HOME}/.local/bin/devbox-codex-limit-detect"

  chown \
    "$DEV_USER:$DEV_USER" \
    "${DEV_HOME}/.local/bin/devbox-agent-limit-notify" \
    "${DEV_HOME}/.local/bin/devbox-claude-limit-detect" \
    "${DEV_HOME}/.local/bin/devbox-codex-limit-detect"

  msg_ok "Installed agent limit-notify scripts"
}
