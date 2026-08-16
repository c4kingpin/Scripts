#!/usr/bin/env bash
# PostgreSQL: the optional "postgres" feature. Installing the package,
# enabling the system service, and provisioning the dev role, database and
# credentials the dev user needs to reach it.
#
# Downloaded and sourced by install.sh after its bootstrap preflight.
# configure_postgres_dev_access() relies on PG_DB_NAME/PG_DB_USER/
# PG_ENV_FILE/DEV_USER/DEV_HOME, which install.sh declares before calling it
# (PG_DB_NAME/PG_DB_USER are read again later during validation, so they stay
# in install.sh rather than moving here).

set -Eeuo pipefail

install_postgres_package() {
  msg_info "Installing PostgreSQL"

  silent apt-get install \
    -y \
    --no-install-recommends \
    postgresql

  msg_ok "Installed PostgreSQL"
}

enable_postgresql_service() {
  msg_info "Enabling PostgreSQL"

  systemctl enable \
    --now \
    postgresql.service

  msg_ok "Enabled PostgreSQL"
}

configure_postgres_dev_access() {
  msg_info "Configuring PostgreSQL Development Access"

  if [[ -r "$PG_ENV_FILE" ]] &&
    grep \
      -q \
      '^PGPASSWORD=' \
      "$PG_ENV_FILE"; then

    PG_DB_PASS="$(
      sed \
        -n \
        's/^PGPASSWORD=//p' \
        "$PG_ENV_FILE"
    )"
  else
    PG_DB_PASS="$(openssl rand -hex 24)"
  fi

  if runuser \
    -u postgres \
    -- \
    psql \
      --tuples-only \
      --no-align \
      --command "SELECT 1 FROM pg_roles WHERE rolname = '${PG_DB_USER}';" \
    | grep -q '^1$'; then

    runuser \
      -u postgres \
      -- \
      psql \
        --set ON_ERROR_STOP=on \
        --command "ALTER ROLE ${PG_DB_USER} WITH PASSWORD '${PG_DB_PASS}' CREATEDB;"
  else
    runuser \
      -u postgres \
      -- \
      psql \
        --set ON_ERROR_STOP=on \
        --command "CREATE ROLE ${PG_DB_USER} WITH LOGIN PASSWORD '${PG_DB_PASS}' CREATEDB;"
  fi

  if ! runuser \
    -u postgres \
    -- \
    psql \
      --tuples-only \
      --no-align \
      --command "SELECT 1 FROM pg_database WHERE datname = '${PG_DB_NAME}';" \
    | grep -q '^1$'; then

    runuser \
      -u postgres \
      -- \
      psql \
        --set ON_ERROR_STOP=on \
        --command "CREATE DATABASE ${PG_DB_NAME} OWNER ${PG_DB_USER};"
  fi

  local pgpass_content
  pgpass_content="$(cat <<EOF
127.0.0.1:5432:*:${PG_DB_USER}:${PG_DB_PASS}
localhost:5432:*:${PG_DB_USER}:${PG_DB_PASS}
EOF
  )"

  local pg_env_content
  pg_env_content="$(cat <<EOF
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=${PG_DB_USER}
PGPASSWORD=${PG_DB_PASS}
PGDATABASE=${PG_DB_NAME}
DATABASE_URL=ecto://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1/${PG_DB_NAME}
EOF
  )"

  write_root_owned_file "${DEV_HOME}/.pgpass" 0600 "${pgpass_content}"$'\n'
  write_root_owned_file "$PG_ENV_FILE" 0600 "${pg_env_content}"$'\n'

  unset PG_DB_PASS

  msg_ok "Configured PostgreSQL Development Access"
}
