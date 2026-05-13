#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules="${1:-${ODOO_TEST_MODULE:-}}"
db="${2:-devel}"
output="${3:-i18n/$(first_module "${modules:-module}").pot}"

[[ -n "$modules" ]] || die "Usage: $0 <module[,module]> [db] [output]"
validate_module_list "$modules"
validate_db_name "$db"

mkdir -p "$(dirname "$project_dir/$output")"

compose run --rm -v "$project_dir:/mnt/project" odoo odoo \
  -d "$db" \
  --i18n-export="/mnt/project/$output" \
  --modules="$modules" \
  --stop-after-init

if [[ -f "$project_dir/$output" ]]; then
  cat "$project_dir/$output"
else
  echo "POT export requested at $output"
fi
