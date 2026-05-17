#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules=""
db=""
mode="auto"
tags=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      [[ $# -ge 2 ]] || die "Missing value for --db"
      db="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "Missing value for --mode"
      mode="$2"
      shift 2
      ;;
    --tags)
      [[ $# -ge 2 ]] || die "Missing value for --tags"
      tags="$2"
      shift 2
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "$modules" ]] || die "Only one module list argument is supported."
      modules="$1"
      shift
      ;;
  esac
done

modules="${modules:-${ODOO_TEST_MODULE:-}}"

if [[ -z "$modules" ]]; then
  die "Usage: $0 <module[,module]> [--db <db>] [--mode auto|init|update] [--tags <tags>]"$'\n'"Or set ODOO_TEST_MODULE in .env."
fi

validate_module_list "$modules"
db="${db:-$(default_test_db "$modules")}"
validate_db_name "$db"
tags="${tags:-$(default_test_tags "$modules")}"

database_exists() {
  local target_db="$1"
  local exists
  exists="$(compose exec -T db psql -U "${POSTGRES_USER:-odoo}" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$target_db'" 2>/dev/null || true)"
  [[ "$exists" == "1" ]]
}

installed_module_count() {
  local target_db="$1"
  local module_list="$2"
  local quoted_modules=()
  local module

  IFS=',' read -r -a module_array <<<"$module_list"
  for module in "${module_array[@]}"; do
    quoted_modules+=("'$module'")
  done

  local IFS=,
  compose exec -T db psql -U "${POSTGRES_USER:-odoo}" -d "$target_db" -Atc \
    "SELECT COUNT(*) FROM ir_module_module WHERE state = 'installed' AND name IN (${quoted_modules[*]})" 2>/dev/null || true
}

resolve_test_mode() {
  local requested_mode="$1"
  local module_list="$2"
  local target_db="$3"

  if [[ "$requested_mode" != "auto" ]]; then
    printf '%s' "$requested_mode"
    return
  fi

  if ! database_exists "$target_db"; then
    printf 'init'
    return
  fi

  local expected_count=0
  local module
  IFS=',' read -r -a module_array <<<"$module_list"
  for module in "${module_array[@]}"; do
    expected_count=$((expected_count + 1))
  done

  if [[ "$(installed_module_count "$target_db" "$module_list")" == "$expected_count" ]]; then
    printf 'update'
  else
    printf 'init'
  fi
}

mode="$(resolve_test_mode "$mode" "$modules" "$db")"

odoo_args=(-d "$db")
case "$mode" in
  init) odoo_args+=(-i "$modules") ;;
  update) odoo_args+=(-u "$modules") ;;
  *) die "Invalid test mode: $mode. Use one of: auto, init, update." ;;
esac

odoo_args+=(--test-enable --stop-after-init)
if [[ -n "$tags" ]]; then
  odoo_args+=(--test-tags "$tags")
fi

compose run --rm odoo odoo "${odoo_args[@]}"
