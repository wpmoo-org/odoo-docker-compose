#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules=""
db=""
mode="init"
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
  die "Usage: $0 <module[,module]> [--db <db>] [--mode init|update] [--tags <tags>]"$'\n'"Or set ODOO_TEST_MODULE in .env."
fi

validate_module_list "$modules"
db="${db:-$(default_test_db "$modules")}"
validate_db_name "$db"
tags="${tags:-$(default_test_tags "$modules")}"

odoo_args=(-d "$db")
case "$mode" in
  init) odoo_args+=(-i "$modules") ;;
  update) odoo_args+=(-u "$modules") ;;
  *) die "Invalid test mode: $mode" ;;
esac

odoo_args+=(--test-enable --stop-after-init)
if [[ -n "$tags" ]]; then
  odoo_args+=(--test-tags "$tags")
fi

compose run --rm odoo odoo "${odoo_args[@]}"
