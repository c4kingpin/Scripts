#!/usr/bin/env bash
# Developer user (dev) provisioning: account creation, migration from the
# old codex-devbox naming, stale mise-managed BEAM toolchain cleanup, and
# the developer's directory scaffolding.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on DEV_USER/DEV_HOME (from install.sh) and run_as_dev (from lib/common.sh).

set -Eeuo pipefail

create_developer_user() {
  msg_info "Creating Developer User"

  if ! id "$DEV_USER" >/dev/null 2>&1; then
    useradd \
      --create-home \
      --user-group \
      --shell /bin/bash \
      "$DEV_USER"

    random_password="$(openssl rand -hex 32)"
    password_hash="$(openssl passwd -6 "$random_password")"

    usermod \
      --password "$password_hash" \
      "$DEV_USER"

    unset random_password
    unset password_hash
  fi

  if [[ -d "${DEV_HOME}/.config/codex-devbox" &&
        ! -d "${DEV_HOME}/.config/devbox" ]]; then

    msg_info "Migrating state from ~/.config/codex-devbox"

    mv \
      "${DEV_HOME}/.config/codex-devbox" \
      "${DEV_HOME}/.config/devbox"

    msg_ok "Migrated state to ~/.config/devbox"
  fi

  rm -f \
    /usr/local/bin/codex-devbox \
    /etc/sudoers.d/90-codex-devbox \
    /etc/profile.d/codex-devbox.sh

  if [[ -d "${DEV_HOME}/.local/share/mise" ]]; then
    msg_info "Removing previously mise-managed BEAM toolchain"

    rm -rf \
      "${DEV_HOME}/.local/share/mise/installs/erlang" \
      "${DEV_HOME}/.local/share/mise/installs/elixir" \
      "${DEV_HOME}/.local/share/elixir"

    for stale_bin in \
      elixir \
      elixirc \
      iex \
      mix \
      erl \
      erlc \
      escript; do

      rm -f \
        "${DEV_HOME}/.local/share/mise/shims/${stale_bin}" \
        "${DEV_HOME}/.local/bin/${stale_bin}"
    done

    if [[ -f "${DEV_HOME}/.config/mise/config.toml" ]]; then
      sed \
        -i \
        '/^\(erlang\|elixir\) *=/d' \
        "${DEV_HOME}/.config/mise/config.toml"
    fi

    msg_ok "Removed previously mise-managed BEAM toolchain"
  fi

  # P0.1: on a re-run (devbox update/reinstall), dev already owns and can
  # have replaced any of these with a symlink; `install -d` would then
  # chown/chmod through it. Reject before creating/touching any of them.
  for developer_scaffold_dir in \
    "${DEV_HOME}/.ssh" \
    "${DEV_HOME}/.codex" \
    "${DEV_HOME}/.claude" \
    "${DEV_HOME}/.happy" \
    "${DEV_HOME}/.config" \
    "${DEV_HOME}/.config/devbox" \
    "${DEV_HOME}/.cache" \
    "${DEV_HOME}/.local" \
    "${DEV_HOME}/.local/bin" \
    "${DEV_HOME}/workspace"; do

    reject_symlink "$developer_scaffold_dir"
  done

  install \
    -d \
    -m 0700 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "${DEV_HOME}/.ssh" \
    "${DEV_HOME}/.codex" \
    "${DEV_HOME}/.claude" \
    "${DEV_HOME}/.happy" \
    "${DEV_HOME}/.config" \
    "${DEV_HOME}/.config/devbox" \
    "${DEV_HOME}/.cache"

  install \
    -d \
    -m 0755 \
    -o "$DEV_USER" \
    -g "$DEV_USER" \
    "${DEV_HOME}/.local" \
    "${DEV_HOME}/.local/bin" \
    "${DEV_HOME}/workspace"

  for developer_dir in \
    "${DEV_HOME}/.config" \
    "${DEV_HOME}/.cache" \
    "${DEV_HOME}/.local" \
    "${DEV_HOME}/.happy" \
    "${DEV_HOME}/workspace"; do

    if ! run_as_dev test \
      -w "$developer_dir"; then

      msg_error "Developer directory is not writable: ${developer_dir}"
      exit 1
    fi
  done

  msg_ok "Created Developer User"
}
