#!/usr/bin/env bash
# Erlang/OTP and Elixir/Phoenix, installed outside any version manager: mise
# shims produced a BEAM runtime that died during kernel startup in this
# container class, so both live under /opt/devbox with plain symlinks into
# /usr/local/bin instead.
#
# Downloaded and sourced by install.sh after its bootstrap preflight; relies
# on curl_with_retry()/msg_*()/LOG_FILE from install.sh's own bootstrap
# chain, verify_checksum()/run_as_dev() from lib/common.sh, and
# ERLANG_VERSION/ELIXIR_VERSION/PHOENIX_VERSION/DEVBOX_CHECKSUMS/DEV_USER/
# DEV_HOME from install.sh's version manifest.

set -Eeuo pipefail

readonly OTP_ROOT="/opt/devbox/otp"
readonly ELIXIR_ROOT="/opt/devbox/elixir"

ERLANG_OTP_MAJOR="${ERLANG_VERSION%%.*}"

install_erlang() {
  msg_info "Installing Erlang/OTP ${ERLANG_VERSION}"

  otp_arch="$(dpkg --print-architecture)"

  otp_os="ubuntu-$(
    . /etc/os-release
    printf '%s' "${VERSION_ID}"
  )"

  otp_tarball="$(mktemp)"

  curl_with_retry \
    "https://builds.hex.pm/builds/otp/${otp_arch}/${otp_os}/OTP-${ERLANG_VERSION}.tar.gz" \
    "$otp_tarball"

  verify_checksum \
    "$otp_tarball" \
    "${DEVBOX_CHECKSUMS["otp:${ERLANG_VERSION}:${otp_os}:${otp_arch}"]:-}" \
    "Erlang/OTP ${ERLANG_VERSION} (${otp_os}, ${otp_arch})"

  rm -rf "$OTP_ROOT"

  install \
    -d \
    -m 0755 \
    "$OTP_ROOT"

  tar \
    -xzf "$otp_tarball" \
    -C "$OTP_ROOT" \
    --strip-components=1

  rm -f "$otp_tarball"

  (
    cd "$OTP_ROOT"

    ./Install \
      -minimal \
      "$OTP_ROOT"
  ) >>"$LOG_FILE" 2>&1

  for otp_bin in \
    erl \
    erlc \
    escript \
    epmd \
    dialyzer \
    typer \
    ct_run \
    run_erl \
    to_erl; do

    if [[ -x "${OTP_ROOT}/bin/${otp_bin}" ]]; then
      ln \
        -sfn \
        "${OTP_ROOT}/bin/${otp_bin}" \
        "/usr/local/bin/${otp_bin}"
    fi
  done

  if [[ ! -f "${DEV_HOME}/.erlang.cookie" ]]; then
    openssl rand \
      -hex 32 \
      >"${DEV_HOME}/.erlang.cookie"
  fi

  chown \
    "$DEV_USER:$DEV_USER" \
    "${DEV_HOME}/.erlang.cookie"

  chmod \
    0400 \
    "${DEV_HOME}/.erlang.cookie"

  if ! run_as_dev erl \
    -noshell \
    -eval 'halt(0).'; then

    msg_error "Erlang ${ERLANG_VERSION} was installed but cannot execute BEAM code."
    exit 1
  fi

  msg_ok "Installed Erlang/OTP ${ERLANG_VERSION}"
}

install_elixir_and_phoenix() {
  msg_info "Installing Elixir ${ELIXIR_VERSION} and Phoenix ${PHOENIX_VERSION}"

  elixir_zip="$(mktemp)"

  curl_with_retry \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${ERLANG_OTP_MAJOR}.zip" \
    "$elixir_zip"

  verify_checksum \
    "$elixir_zip" \
    "${DEVBOX_CHECKSUMS["elixir:${ELIXIR_VERSION}:${ERLANG_OTP_MAJOR}"]:-}" \
    "Elixir ${ELIXIR_VERSION} (OTP ${ERLANG_OTP_MAJOR})"

  rm -rf "$ELIXIR_ROOT"

  install \
    -d \
    -m 0755 \
    "$ELIXIR_ROOT"

  unzip \
    -q \
    "$elixir_zip" \
    -d "$ELIXIR_ROOT"

  rm -f "$elixir_zip"

  chmod \
    0755 \
    "$ELIXIR_ROOT"/bin/*

  for elixir_bin in \
    elixir \
    elixirc \
    iex \
    mix; do

    ln \
      -sfn \
      "${ELIXIR_ROOT}/bin/${elixir_bin}" \
      "/usr/local/bin/${elixir_bin}"
  done

  run_as_dev mix local.hex --force
  run_as_dev mix local.rebar --force

  run_as_dev mix archive.install \
    hex \
    phx_new \
    "$PHOENIX_VERSION" \
    --force

  msg_ok "Installed Elixir ${ELIXIR_VERSION} (OTP ${ERLANG_OTP_MAJOR}) and Phoenix ${PHOENIX_VERSION}"
}
