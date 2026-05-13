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

if [[ -n "${ODOO_MASTER_PASSWORD:-}" ]]; then
  if grep -q -E '^[[:space:]]*admin_passwd[[:space:]]*=' "$ODOO_RC"; then
    escaped_master_password="$(printf '%s' "$ODOO_MASTER_PASSWORD" | sed -e 's/[\/&]/\\&/g')"
    sed -i -E "s/^[[:space:]]*admin_passwd[[:space:]]*=.*/admin_passwd = ${escaped_master_password}/" "$ODOO_RC"
  else
    printf '\nadmin_passwd = %s\n' "$ODOO_MASTER_PASSWORD" >> "$ODOO_RC"
  fi
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
