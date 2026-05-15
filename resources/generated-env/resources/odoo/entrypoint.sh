#!/usr/bin/env bash
set -euo pipefail

: "${HOST:=db}"
: "${PORT:=5432}"
: "${USER:=odoo}"
: "${PASSWORD:=${POSTGRES_PASSWORD:-odoo}}"
: "${ODOO_RC:=/etc/odoo/odoo.conf}"
: "${WPMOO_SRC_DIR:=/mnt/wpmoo-src/private}"
: "${WPMOO_ADDONS_DIR:=/mnt/wpmoo-addons}"

if [ -s /etc/odoo/requirements.txt ]; then
  pip3 install -r /etc/odoo/requirements.txt
fi

if [[ -f "$ODOO_RC" && ! -w "$ODOO_RC" ]]; then
  runtime_odoo_rc="$(mktemp)"
  cp "$ODOO_RC" "$runtime_odoo_rc"
  ODOO_RC="$runtime_odoo_rc"
fi
export ODOO_RC

upsert_odoo_config() {
  local param="$1"
  local value="$2"
  local tmp_config line replaced
  replaced=0

  if grep -q -E "^[[:space:]]*${param}[[:space:]]*=" "$ODOO_RC"; then
    tmp_config="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*${param}[[:space:]]*= && "$replaced" -eq 0 ]]; then
        printf '%s = %s\n' "$param" "$value" >>"$tmp_config"
        replaced=1
      else
        printf '%s\n' "$line" >>"$tmp_config"
      fi
    done <"$ODOO_RC"
    cat "$tmp_config" >"$ODOO_RC"
    rm -f "$tmp_config"
  else
    printf '\n%s = %s\n' "$param" "$value" >>"$ODOO_RC"
  fi
}

normalize_bool() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1 | true | yes | on) printf 'True' ;;
    0 | false | no | off) printf 'False' ;;
    *) printf '%s' "$1" ;;
  esac
}

if [[ -n "${ODOO_MASTER_PASSWORD:-}" ]]; then
  upsert_odoo_config "admin_passwd" "$ODOO_MASTER_PASSWORD"
fi

if [[ -n "${ODOO_PROXY_MODE:-${PROXY_MODE:-}}" ]]; then
  upsert_odoo_config "proxy_mode" "$(normalize_bool "${ODOO_PROXY_MODE:-${PROXY_MODE:-}}")"
fi

prepare_wpmoo_addons() {
  mkdir -p "$WPMOO_ADDONS_DIR"
  find "$WPMOO_ADDONS_DIR" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +

  if [[ ! -d "$WPMOO_SRC_DIR" ]]; then
    return
  fi

  find "$WPMOO_SRC_DIR" -mindepth 1 -maxdepth 4 -type f -name '__manifest__.py' -print0 |
    while IFS= read -r -d '' manifest; do
      addon_dir="$(dirname "$manifest")"
      addon_name="$(basename "$addon_dir")"
      ln -sfn "$addon_dir" "$WPMOO_ADDONS_DIR/$addon_name"
    done
}

prepare_wpmoo_addons

DB_ARGS=()
check_config() {
  local param="$1"
  local value="$2"
  if grep -q -E "^[[:space:]]*${param}[[:space:]]*=" "$ODOO_RC"; then
    value="$(grep -E "^[[:space:]]*${param}[[:space:]]*=" "$ODOO_RC" | head -n 1 | cut -d '=' -f2- | xargs)"
  fi
  DB_ARGS+=("--${param}" "${value}")
}

check_config "db_host" "$HOST"
check_config "db_port" "$PORT"
check_config "db_user" "$USER"
check_config "db_password" "$PASSWORD"

case "${1:-}" in
  -- | odoo)
    shift || true
    if [[ "${1:-}" == "scaffold" ]]; then
      exec odoo "$@"
    fi
    wait-for-psql.py "${DB_ARGS[@]}" --timeout=30
    exec odoo "$@" "${DB_ARGS[@]}"
    ;;
  -*)
    wait-for-psql.py "${DB_ARGS[@]}" --timeout=30
    exec odoo "$@" "${DB_ARGS[@]}"
    ;;
  *)
    exec "$@"
    ;;
esac
