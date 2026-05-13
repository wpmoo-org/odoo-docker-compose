#!/usr/bin/env bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

cd "$project_dir"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

odoo_version="${ODOO_VERSION:-19.0}"
compose_file="docker-compose_${odoo_version}.yml"

die() {
  echo "$*" >&2
  exit 1
}

if [[ ! -f "$compose_file" ]]; then
  die "Missing compose file: $compose_file"$'\n'"Set ODOO_VERSION to one of: 17.0, 18.0, 19.0"
fi

compose() {
  docker compose -f "$compose_file" "$@"
}

default_http_port() {
  case "$odoo_version" in
    17.0) printf '10017' ;;
    18.0) printf '10018' ;;
    19.0) printf '10019' ;;
    *) printf '10019' ;;
  esac
}

validate_db_name() {
  local db="$1"
  [[ "$db" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid database name: $db"
  [[ "$db" != -* ]] || die "Invalid database name: $db"
}

validate_snapshot_name() {
  local snapshot="$1"
  [[ "$snapshot" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid snapshot name: $snapshot"
  [[ "$snapshot" != -* ]] || die "Invalid snapshot name: $snapshot"
}

validate_module_name() {
  local module="$1"
  [[ "$module" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid module name: $module"
}

validate_module_list() {
  local modules="$1"
  [[ -n "$modules" ]] || die "Module list is required."

  local module
  IFS=',' read -r -a module_array <<<"$modules"
  for module in "${module_array[@]}"; do
    validate_module_name "$module"
  done
}

first_module() {
  local modules="$1"
  printf '%s' "${modules%%,*}"
}

default_test_db() {
  local modules="$1"
  printf '%s' "${ODOO_TEST_DB:-$(first_module "$modules")_test}"
}

default_test_tags() {
  local modules="$1"
  printf '/%s' "${modules//,/,/}"
}
