#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules="${1:-${ODOO_TEST_MODULE:-}}"
db="${2:-devel}"

[[ -n "$modules" ]] || die "Usage: $0 <module[,module]> [db]"
validate_module_list "$modules"
validate_db_name "$db"

python_modules="["
IFS=',' read -r -a module_array <<<"$modules"
for module in "${module_array[@]}"; do
  python_modules+="'$module',"
done
python_modules+="]"

printf "modules = %s\nenv['ir.module.module'].search([('name', 'in', modules)]).button_immediate_uninstall()\n" \
  "$python_modules" |
  compose run --rm -T odoo odoo shell -d "$db"
